# Current status

_Updated: 2026-11-04 ~21:00 UTC (session start 20:08 UTC)._

## Environment facts (verified)
* Flutter 3.47.9 / Dart 3.13.7 are at `/opt/sdk/flutter`. flame is pinned to 1.38.2 and flutter_scene to 0.24.3.
* **The Android SDK can't be installed in the sandbox.** dl.google.com returns 403 from the egress proxy.
  APK builds exist only in GitHub Actions (`.github/workflows/ci.yml`).
* **Pushing to GitHub fails** with HTTP 403 ("Claude doesn't have GitHub access to LuffyUchiha/yantrasobi").
  All work is committed locally on `claude/beautiful-wright-2ho13i`. CI has therefore **never run**.
  The fix is to reconnect GitHub and install the Claude GitHub App on the repo, then push.
* No Android emulator or device. **There are no real-device FPS numbers.** The in-app perf overlay
  measures FPS live on whatever device runs the app.
* The web build works locally. Screenshots in `docs/screenshots/` are real captures from headless Chromium
  (SwiftShader WebGL2) via `tool/capture.js`. flutter_scene renders there through its WebGL2 backend.
* Publisher and store sites (play.google.com, voodoo.io, habby.com) are blocked by network policy. Research
  uses web-search evidence instead; see `research/CATALOG.md`.

## Milestones
| Milestone | Status | Evidence |
|---|---|---|
| Bootstrap (project, docs, CI file) | DONE | analyze clean, tests green locally; CI not yet run (push blocked) |
| Console: library/search/filter/detail/settings/host | DONE | `test/yantrasobi/console_flow_test.dart`, `docs/screenshots/library*.png` |
| Cartridge API v1, registry, saves, settings, audio | DONE | `test/yantrasobi/core_test.dart` |
| Flame adapter | DONE | 11 Flame cartridges |
| Widget adapter | DONE | `lib/yantrasobi/adapters/widget_adapter.dart` |
| flutter_scene adapter + canvas fallback | DONE | Crowd Forge, Spiral Drop, Mob Magnet and Roll Ridge render in Chromium WebGL2 (gradient skies) |
| Crowd Forge (3D reference) | COMPLETE | 14 tests + web capture |
| Arrow Survivor (2D reference) | COMPLETE | 9 tests + web capture |
| Research catalog | DONE (secondary sources) | `research/CATALOG.md` |
| Cartridge factory | 25 COMPLETE | see CARTRIDGES.md |
| Declarative data packs (JSON only) | DONE | `docs/DATA_PACKS.md`, `test/yantrasobi/data_pack_test.dart`; Brickfall consumes level packs |
| Multiplayer-ready metadata | DONE | `CartridgeManifest.maxPlayers/localMultiplayer`; no networking in this branch (another session owns it) |

## Verification log (latest run)
| Check | Result |
|---|---|
| `dart format --set-exit-if-changed lib test` | clean |
| `flutter analyze` | No issues found |
| `flutter test` (committed cartridges) | all passed (the full run also includes the in-progress Pocket Quest) |
| `flutter build web --release` | succeeds (about 60–150 s) |
| `flutter build apk` | not runnable locally (no Android SDK); CI only, never run because pushes fail |

## In progress
* Backlog from the user's list (research/CATALOG.md): Cloud Tower is in progress; the next batch is queued.

## Known gaps
* Never run on a phone. Touch is exercised by widget tests and by mouse-driven Chromium captures only.
* Audio is synthesized WAV played through audioplayers. It hasn't been verified on a device in this
  environment, and headless Chromium has no audio output to check.
* Data packs install from pasted JSON or bundled assets; there is no network download transport yet (by design, it plugs into `DataPackRepository.install`).
