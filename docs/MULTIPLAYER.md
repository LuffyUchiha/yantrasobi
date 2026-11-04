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
│ CartridgeHost ─ PartyMatch ─ sync helper│        │ JSON. No game logic.  │        │ PartyMatch ─ sync helper ─ Host    │
└──────────────────────────────────┘        └───────────────────────┘        └───────────────────────────────┘
```

All code lives in **`packages/asobi_party`**. It's pure Dart, has no Flutter dependency, and is tested
on its own (`dart test`, 28 tests).

| Piece | File | Role |
|---|---|---|
| `MultiplayerSpec`, `eligibleGames` | `lib/src/spec.dart` | What a cartridge supports. Builds the shrunk library |
| `RoomLink`, `RoomRegistry`, `LoopbackRelay` | `lib/src/room.dart` | Transport seam. The in-memory relay is used for tests and offline demos |
| `PartyController`, `PartyMatch` | `lib/src/party.dart` | Lobby, host, ready-up, start, shared seed, seats, results, host migration, forfeits |
| `ParallelRace`, `TurnSync`, `Lockstep` | `lib/src/sync.dart` | In-match sync, plus desync detection |
| `RelayServer`, `WebSocketRoomLink` | `lib/io.dart`, `bin/relay.dart`, `Dockerfile` | Network relay and client (dart:io) |

### Why the relay is "dumb"

The relay only forwards messages. Lobby state, host choice, eligibility and game rules all run on the
phones, and every phone computes them the same way from the same messages. This has three benefits:

* The relay is about 200 lines, stores nothing and costs close to nothing to host. It's a single binary
  (`dart compile exe`) and runs on any small VM or container service behind TLS (`wss://`).
* Another realtime backend can replace it later by implementing `RoomLink`: Firebase RTDB, Supabase
  Realtime, Nakama, or LAN via Nearby Connections.
* Same-device parties use the exact same `PartyMatch` and sync-helper API, with no network involved.

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

## Console integration (done)

| Piece | Where |
|---|---|
| `CartridgeManifest.multiplayer` (a `MultiplayerSpec`), plus `partySpec`, which falls back to a same-phone-only spec for `localMultiplayer` cartridges | `lib/yantrasobi/cartridge/manifest.dart` |
| `CartridgeContext.match` and `matchSeed`; `liveScore` on `CartridgeSession` and `AsobiFlameGame` | `cartridge.dart`, `flame_adapter.dart` |
| `AsobiParty` service (one party at a time, eligible ids, match stream) | `lib/yantrasobi/party/party_service.dart`, exposed as `AsobiServices.party` |
| `WsRoomLink`: the relay protocol over `web_socket_channel` (Android, iOS, web) | `lib/yantrasobi/party/ws_room_link.dart` |
| Play together sheet, party banner, lobby bar (pick, Ready, START) | `lib/yantrasobi/ui/party_sheet.dart`, `library_screen.dart` |
| Match in the host: race strip with opponents' live scores, result reporting, forfeit on exit, standings, no restart online | `lib/yantrasobi/runtime/cartridge_host.dart` |
| Player name and relay address | Settings → Play together (`AsobiSettings.playerName`, `relayUrl`; build default `--dart-define=YANTRASOBI_RELAY=wss://…`) |
| Tests | `test/yantrasobi/party_flow_test.dart` (UI flows over the in-memory relay), `test/yantrasobi/ws_room_link_test.dart` (app transport against the real relay) |

### What plays together today

* **Online races (parallel), 2–8 phones:** Arrow Survivor, Blade Toss, Cloud Tower, Dodge Lane, Edge Dash,
  Gulp Hole, Coil Clash. Everyone gets the same seed and races their own copy, with opponents' scores
  live at the top right.
* **Same phone:** Puck Duel (2 players) and Quad Pong (2–4 players). When launched from a party, they skip
  their mode menu.

### Making another cartridge party-ready

* **Race:** the world must depend only on the seed (not on a saved level). Then:
  * add `multiplayer: MultiplayerSpec(sync: SyncModel.parallel, maxPlayers: 8, summary: '…')` to the
    manifest,
  * pass `seed: session.context.matchSeed` in `createGame`,
  * override `int get liveScore`.

  The host does the networking.
* **Same phone:** set `maxPlayers` and `localMultiplayer: true`. If `session.context.match` is set,
  start straight in the multi-human mode, with `match.playerCount` humans.
* **Real-time shared arena (lockstep) or turn-based online:** drive the world's `setInput` through
  `Lockstep.step()` / `TurnSync.submit()` from `ctx.match`. No cartridge does this yet. Coil Clash,
  Ink Claim and Gulp Hole arenas are the natural first candidates (see `research/MULTIPLAYER_CATALOG.md`).

## Running the relay

```bash
cd packages/asobi_party && dart run bin/relay.dart        # PORT=8787 by default; /healthz for probes
```

```bash
docker build -t yantrasobi-relay packages/asobi_party && docker run -p 8787:8787 yantrasobi-relay
```

Phones connect to `wss://<host>/v1/party`. In the app, enter the address under Settings → Play together.
For a quick home test, run the relay on a laptop and enter `<laptop LAN IP>:8787` on each phone. That
uses plain `ws://`, so Android needs cleartext traffic allowed for that address. Use `wss://` for
anything public.
