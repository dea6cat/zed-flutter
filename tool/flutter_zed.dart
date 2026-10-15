// Bridges VS Code / JetBrains run configs and device selection into Zed.
//   dart flutter_zed.dart sync    -> .zed/debug.json from .vscode/launch.json + .run/*.run.xml
//   dart flutter_zed.dart device  -> pick a device, then re-sync
import 'dart:convert';
import 'dart:io';

const _prefix = 'Flutter: ';
const _pidFile = '.zed/flutter.pid';
const _deviceFile = '.zed/flutter_device';
const _fvmFiles = ['.fvmrc', '.fvm/fvm_config.json'];

Future<void> main(List<String> args) async {
  final command = args.isEmpty ? 'sync' : args.first;
  switch (command) {
    case 'sync':
      _sync();
    case 'device':
      await _pickDevice();
      _sync();
    case 'status':
      stdout.writeln('Device: ${_device ?? 'auto (none selected)'}');
    case 'run':
      await _run(args.skip(1).join(' '));
    case 'reload':
      _signal(ProcessSignal.sigusr1, 'Hot reload');
    case 'restart':
      _signal(ProcessSignal.sigusr2, 'Hot restart');
    case 'devtools':
      await _devtools(args.skip(1).join(' '));
    case 'watch':
      await _watch();
    default:
      stderr.writeln('usage: flutter_zed.dart [sync|device|status|run [label]|reload|restart|devtools [vm-service-uri]|watch]');
      exit(64);
  }
}

bool get _useFvm => _fvmFiles.any((f) => File(f).existsSync());

String? get _device {
  final file = File(_deviceFile);
  return file.existsSync() ? file.readAsStringSync().trim() : null;
}

Future<void> _pickDevice() async {
  final cmd = _useFvm ? ['fvm', 'flutter'] : ['flutter'];
  final result = await Process.run(cmd.first, [...cmd.skip(1), 'devices', '--machine']);
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    exit(1);
  }
  final devices = (jsonDecode(result.stdout as String) as List).cast<Map<String, dynamic>>();
  if (devices.isEmpty) {
    stderr.writeln('No devices found.');
    exit(1);
  }
  for (var i = 0; i < devices.length; i++) {
    final d = devices[i];
    stdout.writeln('${i + 1}) ${d['name']} (${d['targetPlatform']}) [${d['id']}]');
  }
  stdout.write('Select device: ');
  final index = (int.tryParse(stdin.readLineSync() ?? '') ?? 0) - 1;
  if (index < 0 || index >= devices.length) {
    stderr.writeln('Invalid choice.');
    exit(1);
  }
  Directory('.zed').createSync();
  File(_deviceFile).writeAsStringSync('${devices[index]['id']}\n');
  stdout.writeln('Selected ${devices[index]['name']}');
}

void _sync() {
  final scenarios = [..._fromVsCode(), ..._fromJetBrains()];
  if (scenarios.isEmpty) {
    stderr.writeln('No .vscode/launch.json or .run/*.run.xml configs found.');
    exit(1);
  }
  final device = _device;
  final out = [
    for (final s in scenarios)
      {
        'adapter': 'Dart',
        'type': 'flutter',
        'request': 'launch',
        'program': 'lib/main.dart',
        'useFvm': _useFvm,
        ...s,
        'label': '$_prefix${s['label']}',
        // Lets the hot reload/restart tasks signal `flutter run` under the debugger too.
        'toolArgs': [...(s['toolArgs'] as List), '--pid-file', _pidFile],
        if (device != null) 'deviceId': device,
      },
  ];
  Directory('.zed').createSync();
  final file = File('.zed/debug.json');
  final kept = !file.existsSync()
      ? <dynamic>[]
      : (jsonDecode(_stripJsonc(file.readAsStringSync())) as List).where((e) => !'${e['label']}'.startsWith(_prefix)).toList();
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert([...kept, ...out])}\n');
  stdout.writeln('Wrote ${out.length} "$_prefix" scenarios to .zed/debug.json (kept ${kept.length} existing)${device == null ? '' : ', device $device'}');
}

List<Map<String, dynamic>> _fromVsCode() {
  final file = File('.vscode/launch.json');
  if (!file.existsSync()) return [];
  final cleaned = _stripJsonc(file.readAsStringSync());
  final configs = (jsonDecode(cleaned)['configurations'] as List? ?? []).cast<Map<String, dynamic>>();
  return [
    for (final c in configs)
      if (c['type'] == 'dart' || c['type'] == 'flutter')
        {
          'label': '${c['name']}',
          if (c['program'] != null) 'program': c['program'],
          if (c['cwd'] != null) 'cwd': c['cwd'],
          'request': c['request'] ?? 'launch',
          'flutterMode': c['flutterMode'] ?? 'debug',
          'toolArgs': [...?(c['toolArgs'] as List?)?.cast<String>(), ...?(c['args'] as List?)?.cast<String>()],
          if (c['env'] != null) 'env': c['env'],
        },
  ];
}

List<Map<String, dynamic>> _fromJetBrains() {
  final dir = Directory('.run');
  if (!dir.existsSync()) return [];
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.run.xml')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final out = <Map<String, dynamic>>[];
  for (final f in files) {
    final xml = f.readAsStringSync();
    final name = RegExp(r'<configuration[^>]*\sname="([^"]*)"[^>]*FlutterRunConfigurationType').firstMatch(xml)?.group(1);
    if (name == null) continue;
    String? option(String key) {
      final v = RegExp('<option name="$key" value="([^"]*)"').firstMatch(xml)?.group(1);
      return v == null ? null : _unescape(v);
    }

    final flavor = option('buildFlavor');
    out.add({
      'label': _unescape(name),
      'program': (option('filePath') ?? r'$PROJECT_DIR$/lib/main.dart').replaceFirst(RegExp(r'^\$PROJECT_DIR\$/'), ''),
      'toolArgs': [if (flavor != null && flavor.isNotEmpty) ...['--flavor', flavor], ..._splitArgs(option('additionalArgs') ?? '')],
    });
  }
  return out;
}

String _unescape(String s) =>
    s.replaceAll('&quot;', '"').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&apos;', "'");

/// Splits a shell-like string, honouring double quotes.
List<String> _splitArgs(String s) =>
    RegExp(r'"([^"]*)"|(\S+)').allMatches(s).map((m) => m.group(1) ?? m.group(2)!).toList();

/// Removes // and /* */ comments and trailing commas outside of strings.
String _stripJsonc(String src) {
  final buf = StringBuffer();
  var inString = false;
  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    if (inString) {
      buf.write(c);
      if (c == r'\') {
        buf.write(src[++i]);
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
      buf.write(c);
    } else if (src.startsWith('//', i)) {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      buf.write('\n');
    } else if (src.startsWith('/*', i)) {
      i = src.indexOf('*/', i + 2) + 1;
    } else {
      buf.write(c);
    }
  }
  return buf.toString().replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m[1]!);
}

/// Runs `flutter run` in this terminal for a `Flutter: ` scenario; reload/restart signal it.
Future<void> _run(String label) async {
  if (!File('.zed/debug.json').existsSync()) _sync();
  final all = (jsonDecode(_stripJsonc(File('.zed/debug.json').readAsStringSync())) as List)
      .cast<Map<String, dynamic>>()
      .where((e) => '${e['label']}'.startsWith(_prefix))
      .toList();
  if (all.isEmpty) {
    stderr.writeln('No "$_prefix" scenarios. Run sync first.');
    exit(1);
  }
  var scenario = all.where((e) => '${e['label']}' == '$_prefix$label' || '${e['label']}' == label).firstOrNull;
  if (scenario == null) {
    for (var i = 0; i < all.length; i++) {
      stdout.writeln('${i + 1}) ${'${all[i]['label']}'.substring(_prefix.length)}');
    }
    stdout.write('Select config: ');
    final index = (int.tryParse(stdin.readLineSync() ?? '') ?? 0) - 1;
    if (index < 0 || index >= all.length) {
      stderr.writeln('Invalid choice.');
      exit(1);
    }
    scenario = all[index];
  }
  final device = _device;
  final cmd = _useFvm ? ['fvm', 'flutter'] : ['flutter'];
  final flutterArgs = [
    ...cmd.skip(1),
    'run',
    '-t',
    '${scenario['program']}',
    if (device != null) ...['-d', device],
    ...((scenario['toolArgs'] as List?) ?? []).cast<String>(),
  ];
  Directory('.zed').createSync();
  final process = await Process.start(cmd.first, flutterArgs, mode: ProcessStartMode.inheritStdio);
  exit(await process.exitCode);
}

void _signal(ProcessSignal signal, String what) {
  final file = File(_pidFile);
  final pid = file.existsSync() ? int.tryParse(file.readAsStringSync().trim()) : null;
  if (pid == null || !Process.killPid(pid, signal)) {
    stderr.writeln('$what failed: no running "flutter run" (start one with the "Flutter: run" task).');
    exit(1);
  }
  stdout.writeln('$what sent.');
}

/// Re-syncs whenever .vscode/launch.json or a .run/*.run.xml changes.
Future<void> _watch() async {
  String fingerprint() {
    final files = <File>[
      File('.vscode/launch.json'),
      ...(Directory('.run').existsSync() ? Directory('.run').listSync().whereType<File>() : const <File>[]),
    ].where((f) => f.existsSync());
    return files.map((f) => '${f.path}:${f.lastModifiedSync().millisecondsSinceEpoch}').join('|');
  }

  var last = '';
  stdout.writeln('Watching .vscode/launch.json and .run/ (Ctrl+C to stop)');
  while (true) {
    final now = fingerprint();
    if (now != last) {
      last = now;
      try {
        _sync();
      } on Object catch (e) {
        stderr.writeln('sync failed: $e');
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

/// Starts the DevTools server and opens it in the browser, optionally attached to a VM Service URI.
Future<void> _devtools(String vmServiceUri) async {
  final cmd = _useFvm ? ['fvm', 'dart'] : ['dart'];
  final process = await Process.start(
    cmd.first,
    [...cmd.skip(1), 'devtools', if (vmServiceUri.isNotEmpty) vmServiceUri],
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await process.exitCode);
}
