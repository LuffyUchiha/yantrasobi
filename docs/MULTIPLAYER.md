# Multiplayer: play together

Multiplayer is an **optional layer** on top of the single-player console. If a cartridge declares nothing,
nothing about it changes.

## What the player sees

1. The library's top bar has a **Play together** button. Tapping it opens a sheet with three choices:
   * **Start a party.** Shows a 6-character code like `K7QF3M` to read out or share.
   * **Join a party.** Type a friend's code.
   * **Same phone.** Enter 2–4 names to play on one device.
2. While a party is active, a banner shows who's in it, for example "Playing with Ravi · 2 players · 17 games".
   **The library shrinks to the games this party can play together.** That means games that:
   * declare a `MultiplayerSpec`,
   * support this many players and this connection type (online or same device),
   * and, online, are installed **at the same version on every phone**. Cartridges are compiled into the
     app, so a friend on an older build may have a different version.
3. The host (whoever started the party) picks a game. Everyone else sees it highlighted with a
   **Ready** toggle. When everyone is ready, the host presses **Start**.
4. Every phone launches the cartridge with the **same seed** and a seat number. The game plays.
5. A standings card shows the results, then everyone goes back to the party library to pick again or
   rematch.
6. **Leave party** returns everyone to the full single-player library. If the host leaves, the next
   member becomes host. If a player drops mid-match, they forfeit and the match still finishes for
   everyone else.

## Architecture

```
┌──────────── phone A ─────────────┐        ┌──── relay (dumb) ────┐        ┌──────────── phone B ───────────┐
│ Library ── PartyController ──────┼─ WS ──▶│ rooms by code         │◀─ WS ──┼── PartyController ── Library  │
│   │          │ eligible games     │        │ assigns ids, keeps    │        │        │                      │
│   ▼          ▼ matches            │        │ join order, forwards  │        │        ▼                      │
│ CartridgeHost ─ Match ─ sync helper│        │ JSON. No game logic.  │        │ Match ─ sync helper ─ Host    │
└──────────────────────────────────┘        └───────────────────────┘        └───────────────────────────────┘
```

All code lives in **`packages/asobi_party`**. It's pure Dart, has no Flutter dependency, and is tested
on its own (`dart test`, 28 tests).

| Piece | File | Role |
|---|---|---|
| `MultiplayerSpec`, `eligibleGames` | `lib/src/spec.dart` | What a cartridge supports. Builds the shrunk library |
| `RoomLink`, `RoomRegistry`, `LoopbackRelay` | `lib/src/room.dart` | Transport seam. The in-memory relay is used for tests and offline demos |
| `PartyController`, `Match` | `lib/src/party.dart` | Lobby, host, ready-up, start, shared seed, seats, results, host migration, forfeits |
| `ParallelRace`, `TurnSync`, `Lockstep` | `lib/src/sync.dart` | In-match sync, plus desync detection |
| `RelayServer`, `WebSocketRoomLink` | `lib/io.dart`, `bin/relay.dart`, `Dockerfile` | Network relay and client (dart:io) |

### Why the relay is "dumb"

The relay only forwards messages. Lobby state, host choice, eligibility and game rules all run on the
phones, and every phone computes them the same way from the same messages. This has three benefits:

* The relay is about 200 lines, stores nothing and costs close to nothing to host. It's a single binary
  (`dart compile exe`) and runs on any small VM or container service behind TLS (`wss://`).
* Another realtime backend can replace it later by implementing `RoomLink`: Firebase RTDB, Supabase
  Realtime, Nakama, or LAN via Nearby Connections.
* Same-device parties use the exact same `Match` and sync-helper API, with no network involved.

Trust model: **friends only.** Clients trust each other's inputs. The relay limits frame size (16 KB) and
message rate (120/s per connection), and caps rooms at 8. Ranked play against strangers would need
server-side game logic and is out of scope.

### Sync models

* **parallel.** Every phone runs its own world from `match.seed`. `ParallelRace` sends throttled score,
  progress and ghost data, plus optional `attack()` events (for example "send 2 junk rows"). This tolerates
  any amount of lag, and **any deterministic single-player cartridge supports it almost for free.**
* **turnBased.** `TurnSync(apply: (seat, move) => nextSeat)`. The game's own rules decide who plays next,
  so "pot a ball, shoot again" needs no special case. Moves are numbered, and each one carries the
  sender's view of who plays next, so a disagreement is reported as `DesyncDetected`.
* **lockstep.** `Lockstep.step({localSeat: input})` returns all seats' inputs for the next tick, or
  `null` while waiting on the network. Local input is scheduled `inputDelayTicks` ahead to hide
  latency. Optional `checksum(tick, hash)` catches simulations that have drifted apart.

## Console integration (to do in the app, once the console code lands on `main`)

This branch adds only the package and documents. The console framework (`lib/yantrasobi/...`) is being
written in a parallel session and isn't on GitHub yet, so the edits below are the plan for wiring it in.
None of these edits are on this branch yet.

1. **Dependency.** In the app's `pubspec.yaml`, add `asobi_party: {path: packages/asobi_party}` and
   `web_socket_channel`.
2. **Manifest.** Add `final MultiplayerSpec? multiplayer;` (default `null`) to `CartridgeManifest`, plus
   `validate()` → `...?multiplayer?.validate()`, and `toJson()` → `'multiplayer': multiplayer?.toJson()`.
   The field is additive, so no change to `kCartridgeApiVersion` is needed. Example:
   ```dart
   multiplayer: MultiplayerSpec(sync: SyncModel.parallel, maxPlayers: 8, sameDevice: false,
       summary: 'Same tower, highest floor wins'),
   ```
3. **Context.** Add `final Match? match;` to `CartridgeContext`. Cartridges seed their world with
   `ctx.match?.seed ?? DateTime.now().microsecondsSinceEpoch`.
4. **Host glue (`CartridgeHost`).**
   * When the session ends and `match != null`, call `match.finish(score: r.score, won: r.won)`.
     For parallel cartridges this one hook is all the host needs.
   * Add `int get liveScore => 0;` to `AsobiFlameGame`. For `SyncModel.parallel`, the host owns a
     `ParallelRace`, calls `report(score: game.liveScore)` every frame (the race throttles it), and draws
     a small opponent strip (name, score, alive) under the pause row. This means a parallel cartridge
     needs **no networking code at all**.
   * Pause doesn't pause other phones. In a match, the pause button becomes "Forfeit".
5. **Library.** Add an `AsobiParty` service to `AsobiServices`, holding `PartyController?`. When it's
   non-null:
   * filter the catalog to `party.eligible`,
   * show the party banner,
   * on the detail screen, show **Pick for party** (host) or **Ready** (guest),
   * listen to `party.matches` and push `CartridgeHost` with the match.

   `GameEntry`s are built from the catalog as `GameEntry(m.id, m.version, m.multiplayer)`.
6. **Transport in the app.** Write a ~60-line `RoomLink` on top of `web_socket_channel` that speaks the
   same JSON as `io.dart`. That works on Android, iOS and web. `WebSocketRoomLink` in `io.dart` stays as
   the reference implementation and test client. The relay URL goes in settings, with a build-time default.
7. **Profile.** Store a display name in settings, asked for once the first time the player opens
   Play together, and keep a local list of recent party members. No accounts.
8. **Tests.** A console flow test that drives two `PartyController`s over a `LoopbackRelay` through
   the real library UI: party, filtered list, start, results.

## Running the relay

```bash
cd packages/asobi_party && dart run bin/relay.dart        # PORT=8787 by default; /healthz for probes
```

```bash
docker build -t yantrasobi-relay packages/asobi_party && docker run -p 8787:8787 yantrasobi-relay
```

Phones connect to `wss://<host>/v1/party`.
