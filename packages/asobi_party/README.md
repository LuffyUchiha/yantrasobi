# asobi_party

The multiplayer layer for the Yantrasobi console. It provides:

* Parties: online by room code, or several people on the same phone.
* The filtered "play together" library.
* Match sync helpers: `ParallelRace`, `TurnSync` and `Lockstep`.
* A small WebSocket relay.

It's pure Dart. Design, console integration plan and game list:

* [`docs/MULTIPLAYER.md`](../../docs/MULTIPLAYER.md)
* [`research/MULTIPLAYER_CATALOG.md`](../../research/MULTIPLAYER_CATALOG.md)

```bash
dart pub get && dart analyze && dart test     # 28 tests, including real WebSocket play
```

```bash
dart run bin/relay.dart                       # relay on :8787 (PORT env)
```

`example/gravity_four.dart` is a complete turn-based rules file wired to `TurnSync`.
