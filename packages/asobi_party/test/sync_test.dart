import 'dart:math' as math;

import 'package:asobi_party/asobi_party.dart';
import 'package:test/test.dart';

import '../example/gravity_four.dart';

Future<void> settle() => pumpEventQueue(times: 50);

const lockSpec = MultiplayerSpec(sync: SyncModel.lockstep, tickRate: 20, inputDelayTicks: 2, maxPlayers: 3);
const raceSpec = MultiplayerSpec(sync: SyncModel.parallel, maxPlayers: 3);

final games = [
  const GameEntry('race', '1.0.0', raceSpec),
  const GameEntry('four', '1.0.0', GravityFour.spec),
  const GameEntry('arena', '1.0.0', lockSpec),
];

/// Starts [gameId] for [n] online players over [relay]; returns one match per phone.
Future<List<PartyMatch>> startOnline(LoopbackRelay relay, String gameId, int n) async {
  Future<void> settle() async {
    await pumpEventQueue(times: 50);
    if (relay.latency > Duration.zero) await Future<void>.delayed(relay.latency * 3);
  }

  final host = PartyController.online(relay.create(), name: 'P0', catalog: games);
  await settle();
  final others = [
    for (var i = 1; i < n; i++) PartyController.online(relay.join(host.code!), name: 'P$i', catalog: games),
  ];
  await settle();
  host
    ..select(gameId)
    ..setReady(true);
  for (final o in others) {
    o.setReady(true);
  }
  await settle();
  final pending = [for (final o in others) o.matches.first];
  final first = host.start();
  return [first, ...await Future.wait(pending)];
}

/// Tiny deterministic real-time world: each seat moves a dot on a ring; when
/// two dots share a cell the lower seat scores. Stands in for a snake arena.
class DotArena {
  DotArena(int players, int seed) : pos = List.generate(players, (i) => (seed + i * 7) % 50);
  final List<int> pos;
  final List<int> dir = [1, 1, 1];
  int score = 0;

  void step(Map<int, Object?> inputs) {
    for (final e in inputs.entries) {
      if (e.value is int) dir[e.key] = e.value as int;
      pos[e.key] = (pos[e.key] + dir[e.key]) % 50;
    }
    for (var a = 0; a < pos.length; a++) {
      for (var b = a + 1; b < pos.length; b++) {
        if (pos[a] == pos[b]) score += a + 1;
      }
    }
  }

  int get hash => Object.hashAll([...pos, score]);
}

void main() {
  group('ParallelRace', () {
    test('telemetry and attacks reach opponents; standings rank by score', () async {
      final relay = LoopbackRelay();
      final ms = await startOnline(relay, 'race', 3);
      final races = [for (final m in ms) ParallelRace(m, minInterval: Duration.zero)];
      final attacks = <AttackReceived>[];
      races[1].events.whereType<AttackReceived>().listen(attacks.add);

      races[0].report(score: 120, progress: 0.4);
      races[2].report(score: 300, progress: 0.9);
      races[0].attack({'rows': 2});
      await settle();
      expect(races[1].opponents[0]!.score, 120);
      expect(races[1].opponents[2]!.progress, 0.9);
      expect(races[1].liveRanking(200), [2, 1, 0]);
      expect(attacks.single.payload, {'rows': 2});
      expect(attacks.single.seat, 0);

      races[0].finish(score: 150);
      races[1].finish(score: 200);
      races[2].finish(score: 310);
      await settle();
      for (final m in ms) {
        expect([for (final r in m.standings!) r.seat], [2, 1, 0]);
      }
    });

    test('telemetry self-throttles but deaths always go out', () async {
      final ms = await startOnline(LoopbackRelay(), 'race', 2);
      var now = DateTime(2026);
      final race = ParallelRace(ms[0], clock: () => now);
      expect(race.report(score: 1), isTrue);
      expect(race.report(score: 2), isFalse);
      expect(race.report(score: 2, alive: false), isTrue);
      now = now.add(const Duration(seconds: 1));
      expect(race.report(score: 3, alive: false), isTrue);
    });
  });

  group('TurnSync', () {
    test('two phones play a full game and end with identical boards', () async {
      final ms = await startOnline(LoopbackRelay(), 'four', 2);
      final boards = [GravityFour(), GravityFour()];
      final syncs = [for (var i = 0; i < 2; i++) TurnSync(ms[i], firstSeat: 0, apply: boards[i].apply)];
      final rng = math.Random(4);
      var guard = 0;
      while (!boards[0].isOver && guard++ < 100) {
        final phone = syncs.indexWhere((s) => s.isMyTurn);
        expect(phone, syncs[0].currentSeat, reason: 'exactly the seat to play holds the turn');
        final legal = [
          for (var c = 0; c < GravityFour.cols; c++)
            if (boards[phone].canDrop(c)) c,
        ];
        syncs[phone].submit({'col': legal[rng.nextInt(legal.length)]});
        await settle();
        expect(boards[0].snapshot(), boards[1].snapshot());
      }
      expect(boards[0].isOver, isTrue);
      expect(boards[1].winner, boards[0].winner);
      expect(syncs.every((s) => !s.desynced), isTrue);
    });

    test('playing out of turn is refused locally', () async {
      final ms = await startOnline(LoopbackRelay(), 'four', 2);
      final sync = TurnSync(ms[1], firstSeat: 0, apply: GravityFour().apply);
      expect(sync.isMyTurn, isFalse);
      expect(() => sync.submit({'col': 3}), throwsStateError);
    });

    test('a forged out-of-turn move is flagged as a desync', () async {
      final ms = await startOnline(LoopbackRelay(), 'four', 2);
      final sync = TurnSync(ms[0], firstSeat: 0, apply: GravityFour().apply);
      final events = <SyncEvent>[];
      sync.events.listen(events.add);
      ms[1].send({
        'k': 'mv',
        'n': 0,
        'seat': 1,
        'next': 0,
        'mv': {'col': 0},
      });
      await settle();
      expect(events.whereType<DesyncDetected>(), hasLength(1));
    });

    test('same device: one phone passes the turn between seats', () {
      final party = PartyController.sameDevice(players: ['A', 'B'], catalog: games)..select('four');
      final m = party.start();
      final board = GravityFour();
      final sync = TurnSync(m, firstSeat: 0, apply: board.apply);
      for (final col in [0, 1, 0, 1, 0, 1, 0]) {
        expect(sync.isMyTurn, isTrue);
        sync.submit({'col': col});
      }
      expect(board.winner, 0);
    });
  });

  group('Lockstep', () {
    Future<void> runArena({required Duration latency, required int players}) async {
      final relay = LoopbackRelay(latency: latency);
      final ms = await startOnline(relay, 'arena', players);
      final locks = [for (final m in ms) Lockstep(m, checksumEvery: 10)];
      final worlds = [for (final m in ms) DotArena(players, m.seed)];
      final desyncs = <DesyncDetected>[];
      for (final l in locks) {
        l.events.whereType<DesyncDetected>().listen(desyncs.add);
      }
      var stalls = 0;
      const ticks = 60;
      final rng = math.Random(9);
      while (locks.any((l) => l.tick < ticks)) {
        for (var i = 0; i < players; i++) {
          if (locks[i].tick >= ticks) continue;
          final input = rng.nextInt(5) == 0 ? (rng.nextBool() ? 1 : -1) : null;
          final inputs = locks[i].step({ms[i].localSeat: input});
          if (inputs == null) {
            stalls++;
            continue;
          }
          worlds[i].step(inputs);
          locks[i].checksum(locks[i].tick - 1, worlds[i].hash);
        }
        await (latency == Duration.zero ? settle() : Future<void>.delayed(const Duration(milliseconds: 1)));
      }
      await settle();
      for (final w in worlds) {
        expect(w.hash, worlds[0].hash);
        expect(w.pos, worlds[0].pos);
      }
      expect(desyncs, isEmpty);
      if (latency > Duration.zero) expect(stalls, greaterThan(0), reason: 'slow links make the game wait');
    }

    test('two phones, instant link: identical worlds', () => runArena(latency: Duration.zero, players: 2));
    test(
      'three phones, 15 ms link: stalls but never diverges',
      () => runArena(latency: const Duration(milliseconds: 15), players: 3),
    );

    test('different worlds are caught by checksums', () async {
      final ms = await startOnline(LoopbackRelay(), 'arena', 2);
      final locks = [for (final m in ms) Lockstep(m, checksumEvery: 1)];
      final desync = locks[0].events.whereType<DesyncDetected>().first;
      locks[0].checksum(5, 111);
      locks[1].checksum(5, 222);
      await settle();
      expect((await desync).reason, contains('tick 5'));
    });

    test('a dropped player stops blocking the others', () async {
      final relay = LoopbackRelay();
      final host = PartyController.online(relay.create(), name: 'A', catalog: games);
      await settle();
      final guest = PartyController.online(relay.join(host.code!), name: 'B', catalog: games);
      await settle();
      host
        ..select('arena')
        ..setReady(true);
      guest.setReady(true);
      await settle();
      final lock = Lockstep(host.start(), inputDelay: 1);
      expect(lock.step({0: null}), isNotNull, reason: 'pre-filled delay tick');
      expect(lock.step({0: null}), isNull, reason: 'waiting on B');
      await guest.leave();
      await settle();
      expect(lock.step({0: null}), isNotNull);
    });
  });
}

extension<T> on Stream<T> {
  Stream<S> whereType<S>() => where((e) => e is S).cast<S>();
}
