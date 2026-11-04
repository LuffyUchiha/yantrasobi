# Yantrasobi

**Yantrasobi** is an Android-first, portrait, touch-first Flutter arcade console. It hosts a
library of bundled game *cartridges*, each an original game built around a well-known
mobile arcade mechanic (the hyper-casual and "Habby-style" roguelite genres).

* **Console** – library with search and filter, cartridge detail page, launch,
  pause/resume/restart/exit, Android back handling, auto-pause when the app is backgrounded,
  settings (sound, haptics, perf overlay, reduced effects), per-cartridge saves.
* **Cartridge API v1** – versioned manifest, lifecycle state machine, registry with
  validation, adapters for **Flame** (2D) and **flutter_scene** (3D).
* **Cartridges** – see [CARTRIDGES.md](CARTRIDGES.md).

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
    adapters/scene_adapter.dart flutter_scene 3D adapter
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
