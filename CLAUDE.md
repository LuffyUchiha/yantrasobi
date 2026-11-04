# CLAUDE.md – working notes for agents

## Environment
* Flutter SDK: `/opt/sdk/flutter` (3.47.9). Prefix commands with `export PATH=/opt/sdk/flutter/bin:$PATH`.
* Android SDK can't be installed in the cloud sandbox because dl.google.com is blocked by network
  policy, so **APKs are built only in GitHub Actions**. Never claim a local APK build.
* Web builds and headless Chromium (Playwright) work locally and are used for screenshots.

## Conventions
* Framework classes use the `Asobi` prefix (`AsobiFlameGame`, `AsobiSettings`, `AsobiServices`,
  `AsobiScope`, `AsobiAudio`). The product/console name is **Yantrasobi**. Don't use "ArcadeOS" or "Yantra*".
* Formatter page width is 110 (set in analysis_options.yaml). Run `dart format lib test`.
* Each cartridge lives in `lib/cartridges/<id>/`:
  * `<x>_world.dart`: pure Dart rules (only `dart:math` and `vector_math`), deterministic with a seed.
  * `<id>.dart`: manifest + Flame/Scene renderer + input mapping.
  * `test/cartridges/<id>_test.dart`: rules tests.
  * Register it in `lib/cartridges/catalog.dart`. The console flow test then covers launch,
    pause, resume, back, restart, and exit automatically.
* Flame games extend `AsobiFlameGame`. Input comes from `onPointerDown/Move/Up` in widget-local
  coordinates. Call `finish(RunResult(...))` exactly once per run.
* Use only original names and procedural art. No trademarks, characters, or copied levels.

## Gate for a COMPLETE cartridge
Library entry, launch, touch controls, a clear goal, score or win/lose, replay, cleanup,
manifest, rules tests. Format, analyze, and test must all pass. Update CARTRIDGES.md and CURRENT_STATUS.md.

## Data packs
* Cartridges can accept JSON content by implementing `DataPackConsumer` (see `docs/DATA_PACKS.md`).
  They read validated payloads from `CartridgeContext.dataPacks`. Packs must never be able to run code.

## Multiplayer-ready cartridges
* Networking is out of scope here; another session owns it. Multiplayer-ready cartridges set
  `maxPlayers` (and `localMultiplayer` for same-device play).
* Their rules take player actions only through `setInput(player, input)`, advance in fixed steps, and
  expose `tick` and `stateHash()` for lockstep desync checks. CPU players feed the same `setInput` API.

## Working with agents
* Agents get `/tmp/.../scratchpad/agent_brief.md`-style briefs and may only touch their own cartridge
  folder and test file. The integrator registers the cartridge in `catalog.dart`, captures web
  screenshots, updates the docs, and commits.
