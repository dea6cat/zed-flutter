# Flutter for Zed

Flutter and Dart support for [Zed](https://zed.dev), modelled on the VS Code Dart + Flutter extensions.

Based on [zed-extensions/dart](https://github.com/zed-extensions/dart) (Apache-2.0).

## Features

- Dart grammar and language server, FVM-aware (`.fvmrc` / `.fvm/fvm_config.json` runs `fvm dart language-server`).
- Flutter / Dart debug adapter. For Flutter, `args` go to `flutter run` (like VS Code), so `--dart-define` works.
- Flutter snippets.
- Tasks and `tool/flutter_zed.dart`, which:
  - imports `.vscode/launch.json` and JetBrains `.run/*.run.xml` into `.zed/debug.json` (`Flutter: …` scenarios; other entries are kept),
  - picks the target device,
  - runs `flutter run`, hot reload and hot restart through a pid file,
  - opens Flutter DevTools,
  - watches the run configs and re-syncs on change.

## Tasks

| Task | Purpose |
| --- | --- |
| `Flutter: select device` | Pick a device from `flutter devices` |
| `Flutter: sync run configs` | Rebuild `.zed/debug.json` from `.vscode` / `.run` |
| `Flutter: run` | `flutter run` with a chosen config |
| `Flutter: hot reload` / `hot restart` | Signal the running `flutter run` |
| `Flutter: open DevTools` | `dart devtools` |
| `Flutter: watch run configs` | Re-sync when configs change |
| `Flutter: current device` | Show the selected device |

Suggested keybindings (Workspace context): `f5` hot reload, `f6` hot restart, `ctrl-f u` run, `ctrl-f d` select device, `ctrl-f t` DevTools, `ctrl-f w` watch, `ctrl-f s` sync.

The tasks call the script at `~/Library/Application Support/Zed/extensions/installed/flutter/tool/flutter_zed.dart` (macOS).

## Install (dev extension)

Zed needs `rustup` on its `PATH` (not Homebrew's `cargo`). Launch Zed from a terminal that has it, then **Extensions → Install Dev Extension** and pick this folder. Uninstall the Dart and Flutter Snippets extensions first: they define the same language.

## Debug toolbar buttons

Hot Reload, Hot Restart and DevTools buttons in Zed's debug toolbar need a patched Zed: see the `feat/flutter-bundle` branch of [dea6cat/flutterZed](https://github.com/dea6cat/flutterZed).
