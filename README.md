# Yantrasobi

**Yantrasobi** is an Android-first, portrait, touch-first Flutter arcade console. It hosts a
library of bundled game *cartridges*, each an original game built around a well-known
mobile arcade mechanic (the hyper-casual and "Habby-style" roguelite genres).

* **Console** – library with search and filter, cartridge detail page, launch,
  pause/resume/restart/exit, Android back handling, auto-pause when the app is backgrounded,
  settings (sound, haptics, perf overlay, reduced effects), per-cartridge saves.
* **Cartridge API v1**:
  * a versioned manifest, a lifecycle state machine, and a registry that validates cartridges;
  * adapters for **Flame** (2D), **flutter_scene** (3D, with an automatic 2.5D canvas fallback), and
    plain **Flutter widgets**.
* **Data packs**: downloadable-style, **declarative JSON content** (for example, extra Brickfall
  levels) validated by the console and the target cartridge. Packs never contain code. See
  [docs/DATA_PACKS.md](docs/DATA_PACKS.md).
* **Multiplayer-ready metadata**: manifests declare `maxPlayers` and `localMultiplayer`. Networking
  is out of scope for this branch and is being built separately.
* **Cartridges**: 20+ original games. See [CARTRIDGES.md](CARTRIDGES.md) for the list and status,
  [research/CATALOG.md](research/CATALOG.md) for the reference families and backlog, and
  `docs/screenshots/` for real captures from the web build.

All art and sound are procedural (drawn on canvas or synthesized at runtime). Nothing is
copied from commercial games: no code, assets, names, characters, or levels.

## Requirements

| Tool | Version |
| --- | --- |
| Flutter | 3.47.9 stable (Dart 3.13.7) |
| flame | 1.38.2 (pinned) |
| flutter_scene | 0.24.3 (pinned, needs Flutter ≥ 3.47) |
| Android | Flutter default min/target SDK; Java 17 for Gradle |

## Run

```bash
flutter pub get
flutter run            # Android device/emulator
flutter run -d chrome  # optional web preview
```

## Quality gates

```bash
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release   # needs Android SDK (CI does this)
flutter build web --release
```

GitHub Actions (`.github/workflows/ci.yml`) runs format, analyze, and test, then builds the
Android APK and the web bundle as downloadable artifacts.

## Architecture

```
lib/
  main.dart                     boot: prefs store, settings, audio, registry
  yantrasobi/                   the console ("Asobi" framework classes)
    cartridge/manifest.dart     CartridgeManifest + API version
    cartridge/cartridge.dart    Cartridge, CartridgeSession lifecycle, RunResult
    cartridge/registry.dart     validated registry + search
    adapters/flame_adapter.dart AsobiFlameGame + FlameCartridgeSession
    adapters/scene_adapter.dart flutter_scene 3D adapter (+ canvas fallback, gradient skies)
    adapters/widget_adapter.dart plain-widget cartridges
    datapacks/data_pack.dart    JSON data packs: envelope, validation, repository
    runtime/cartridge_host.dart the one-active-session host (pause, results, back)
    services/                   saves, settings, synthesized audio + haptics
    ui/                         library, detail, settings
  cartridges/<id>/              one folder per game: pure-Dart rules + renderer
```

Every cartridge keeps its rules in a pure-Dart "world" class (no Flutter imports), so gameplay
is deterministic for a seed and unit-tested headlessly. The renderer (Flame or
flutter_scene) only draws the world and forwards touch input.

### Code vs data

Cartridge **code is compiled into the app at build time**. Yantrasobi does not, and will not,
download or run Dart code. Manifests are pure data (`CartridgeManifest.toJson`), so future
updates can ship declarative *data packs* (levels, tuning, palettes) for cartridges already
installed. Untrusted code will never be loaded.

## Screenshots

Real captures come from headless Chromium, using the release web build driven by `tool/capture.js`. No
Android device or emulator was available. The captures, all in `docs/screenshots/`:
* `library.png`
* `crowd_forge_3d_web.png`
* `spiral_drop_3d_web.png`
* `mob_magnet_3d_web.png`
* `roll_ridge_3d_web.png`
* each 2D cartridge's `*_web.png`

```bash
flutter build web --release
node tool/capture.js build/web /tmp/shots script.json   # see the header of tool/capture.js
```
