# Current status

_Updated: 2026-11-04 (session start 20:08 UTC)_

## Environment facts (verified)
* Flutter 3.47.9 / Dart 3.13.7 present at `/opt/sdk/flutter`.
* Android SDK **not installable** in the sandbox: dl.google.com returns 403 from the egress proxy.
  APK builds run only in GitHub Actions (`.github/workflows/ci.yml`).
* No Android emulator or physical device. **No real-device FPS figures exist.** The perf
  overlay measures FPS on whatever device runs the app.

## Milestones
| Milestone | Status | Evidence |
|---|---|---|
| Bootstrap (project, docs, CI) | DONE | `flutter analyze` clean, `flutter test` 24/24 local |
| Console: library/search/detail/settings/host | DONE | `test/yantrasobi/console_flow_test.dart` |
| Cartridge API v1 + registry + saves | DONE | `test/yantrasobi/core_test.dart` |
| Flame adapter | DONE | Arrow Survivor |
| flutter_scene adapter + Crowd Forge 3D | IN PROGRESS | – |
| Research catalog | TODO | – |

## Verification log
| Check | Result |
|---|---|
| `dart format` | clean |
| `flutter analyze` | No issues |
| `flutter test` | 24 passed |
| `flutter build web` | (see below) |
| `flutter build apk` | not runnable locally; CI only |

## Blockers
* Android SDK download is blocked locally; CI is the APK build path.
