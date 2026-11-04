import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/dodge_lane/dodge_lane.dart';
import 'package:yantrasobi/cartridges/dodge_lane/dodge_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double dt = 1 / 60;

void runFor(DodgeWorld w, double seconds, {void Function(DodgeWorld w)? each}) {
  final steps = (seconds / dt).round();
  for (var i = 0; i < steps && !w.isOver; i++) {
    each?.call(w);
    w.update(dt);
  }
}

/// Plays like the validator: hold the advised lane, and jump / duck just
/// before the craft's nose reaches a row that needs it.
void bot(DodgeWorld w) {
  final a = w.advise();
  if (a.lane < w.targetLane) {
    w.laneLeft();
  } else if (a.lane > w.targetLane) {
    w.laneRight();
  }
  final z = a.rowZ;
  if (z == null) return;
  final toContact = (z - DodgeWorld.halfLength - w.distance) / w.speed;
  if (toContact > 0.12) return;
  if (a.action == DodgeAction.jump && (!w.airborne || w.airTime < DodgeWorld.reboostWindow)) w.jump();
  if (a.action == DodgeAction.duck && w.duckTimer < 0.3) w.duck();
}

CartridgeContext makeContext({CartridgeSave? save}) => CartridgeContext(
  manifest: DodgeLaneCartridge.kManifest,
  save: save ?? CartridgeSave(),
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
);

void main() {
  test('manifest is valid', () {
    const m = DodgeLaneCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'dodge-lane');
    expect(m.version, '1.0.0');
  });

  test('lane switching is bounded to three lanes and slides smoothly', () {
    final w = DodgeWorld(generate: false);
    expect(w.targetLane, 1);
    w.laneLeft();
    w.laneLeft();
    w.laneLeft();
    expect(w.targetLane, 0);
    w.update(DodgeWorld.laneSwitchTime / 3);
    expect(w.x, greaterThan(0));
    expect(w.x, lessThan(1));
    runFor(w, 0.5);
    expect(w.x, 0);
    for (var i = 0; i < 5; i++) {
      w.laneRight();
    }
    expect(w.targetLane, 2);
    runFor(w, 0.5);
    expect(w.x, 2);
  });

  test('driving into a block ends the run; dodging it does not', () {
    final w = DodgeWorld(generate: false)..injectRow('.B.', ahead: 10);
    runFor(w, 3);
    expect(w.isOver, isTrue);
    expect(w.crashedInto!.kind, Cell.block);
    final before = w.score;
    w.update(dt);
    expect(w.score, before, reason: 'a finished run stops');

    final ok = DodgeWorld(generate: false)..injectRow('.B.', ahead: 10);
    ok.laneRight();
    runFor(ok, 3);
    expect(ok.isOver, isFalse);
  });

  test('jumping clears a low barrier but not a block', () {
    final w = DodgeWorld(generate: false)..injectRow('.L.', ahead: 10);
    runFor(w, 3, each: bot);
    expect(w.isOver, isFalse);

    final noJump = DodgeWorld(generate: false)..injectRow('.L.', ahead: 10);
    runFor(noJump, 3);
    expect(noJump.isOver, isTrue);

    // Jumping into a block still crashes.
    final block = DodgeWorld(generate: false)..injectRow('.B.', ahead: 10);
    runFor(
      block,
      3,
      each: (w) {
        final toContact = (block.rows.first.z - DodgeWorld.halfLength - w.distance) / w.speed;
        if (toContact < 0.1) w.jump();
      },
    );
    expect(block.isOver, isTrue);
  });

  test('ducking passes a high bar; standing or jumping does not', () {
    final w = DodgeWorld(generate: false)..injectRow('HHH', ahead: 10);
    runFor(w, 3, each: bot);
    expect(w.isOver, isFalse);

    final stand = DodgeWorld(generate: false)..injectRow('HHH', ahead: 10);
    runFor(stand, 3);
    expect(stand.isOver, isTrue);

    final hop = DodgeWorld(generate: false)..injectRow('HHH', ahead: 10);
    runFor(
      hop,
      3,
      each: (w) {
        final toContact = (10 - w.distance) / w.speed;
        if (toContact < 0.1) w.jump();
      },
    );
    expect(hop.isOver, isTrue);
  });

  test('a shield absorbs exactly one hit', () {
    final w = DodgeWorld(generate: false)
      ..injectPickup(PickupKind.shield, 1, ahead: 4)
      ..injectRow('BBB', ahead: 15)
      ..injectRow('BBB', ahead: 40);
    runFor(w, 1);
    expect(w.shield, isTrue);
    runFor(w, 1.5);
    expect(w.isOver, isFalse);
    expect(w.shield, isFalse);
    runFor(w, 3);
    expect(w.isOver, isTrue);
  });

  test('magnet pulls in coins from adjacent lanes; without it they are missed', () {
    final w = DodgeWorld(generate: false)
      ..injectPickup(PickupKind.magnet, 1, ahead: 3)
      ..injectCoin(0, ahead: 15)
      ..injectCoin(2, ahead: 18)
      ..injectCoin(1, ahead: 20);
    runFor(w, 3);
    expect(w.magnetTimer, greaterThan(0));
    expect(w.coins, 3);
    expect(w.score, w.distance.floor() + 30);

    final plain = DodgeWorld(generate: false)
      ..injectCoin(0, ahead: 15)
      ..injectCoin(2, ahead: 18)
      ..injectCoin(1, ahead: 20);
    runFor(plain, 3);
    expect(plain.coins, 1);
  });

  test('slow-mo briefly cuts speed', () {
    final w = DodgeWorld(generate: false)..injectPickup(PickupKind.slowmo, 1, ahead: 3);
    runFor(w, 0.5);
    expect(w.slowTimer, greaterThan(0));
    expect(w.speed, closeTo(DodgeWorld.speedAt(w.distance) * DodgeWorld.slowFactor, 0.05));
    runFor(w, DodgeWorld.slowDuration);
    expect(w.slowTimer, 0);
    expect(w.speed, closeTo(DodgeWorld.speedAt(w.distance), 0.05));
  });

  test('speed ramps up over time and is capped', () {
    final w = DodgeWorld(generate: false);
    final s0 = w.speed;
    runFor(w, 30);
    final s30 = w.speed;
    runFor(w, 30);
    expect(s30, greaterThan(s0 + 2));
    expect(w.speed, greaterThan(s30));
    expect(DodgeWorld.speedAt(1e6), DodgeWorld.maxSpeed);
  });

  test('validator: reach model, movers and unreachable rows', () {
    final open = RowSpec.parse('...');
    expect(Passability.safeMask(RowSpec.parse('BLH')), 0x6);
    expect(Passability.safeMask(RowSpec.parse('>.B')), 0x1, reason: 'the mover ends up in lane 1');
    expect(RowSpec.parse('>.B').mirrored().code, 'B.<');
    expect(Passability.actionFor(Cell.low), DodgeAction.jump);
    expect(Passability.actionFor(Cell.high), DodgeAction.duck);
    expect(Passability.actionFor(Cell.block), isNull);
    // From the left lane with time for one shift only, the right lane is out of reach.
    expect(Passability.reach(0x1, RowSpec.parse('BB.'), DodgeWorld.laneSwitchTime * 1.2), 0);
    expect(Passability.reach(0x1, RowSpec.parse('BB.'), DodgeWorld.laneSwitchTime * 2.1), 0x4);
    expect(Passability.reach(0x2, open, 0), 0x2);
    expect(() => RowSpec.parse('B>B'), throwsArgumentError);
    // A tight late-game pair needing two shifts fails validation.
    const z = 3000.0;
    final tightZ = z + DodgeWorld.speedAt(z) * 0.32;
    final bad = [DodgeRow(RowSpec.parse('BB.'), z), DodgeRow(RowSpec.parse('.BB'), tightZ)];
    expect(Passability.firstFailure(bad, startDistance: z - 40, startLane: 2), 1);
  });

  test('every generated row is passable over a long run (several seeds)', () {
    for (final seed in [1, 7, 42, 99, 2024]) {
      final w = DodgeWorld(seed: seed, recordRows: true);
      w.debugGenerateTo(12000);
      expect(w.rowLog.length, greaterThan(300));
      expect(Passability.firstFailure(w.rowLog), -1, reason: 'seed $seed');
      final codes = w.rowLog.map((r) => r.spec.code).toSet();
      expect(codes.any((c) => c.contains('>') || c.contains('<')), isTrue, reason: 'movers appear');
      expect(codes.any((c) => c.contains('L')), isTrue);
      expect(codes.any((c) => c.contains('H')), isTrue);
      expect(w.pickups, isNotEmpty);
      expect(w.coinItems, isNotEmpty);
      // Rows are ordered and never overlap.
      for (var i = 1; i < w.rowLog.length; i++) {
        expect(w.rowLog[i].z - w.rowLog[i - 1].z, greaterThan(DodgeWorld.obstacleDepth * 3));
      }
    }
  });

  test('a bot following the validator survives two minutes', () {
    for (final seed in [3, 11, 58]) {
      final w = DodgeWorld(seed: seed);
      var jumps = 0, ducks = 0, shifts = 0;
      runFor(
        w,
        120,
        each: (w) {
          bot(w);
          for (final e in w.events) {
            if (e.kind == DodgeEventKind.jump) jumps++;
            if (e.kind == DodgeEventKind.duck) ducks++;
            if (e.kind == DodgeEventKind.lane) shifts++;
          }
        },
      );
      expect(w.isOver, isFalse, reason: 'seed $seed crashed at ${w.distance.toStringAsFixed(1)} m');
      expect(w.time, closeTo(120, 0.1));
      expect(w.distance, greaterThan(2000));
      expect(w.speed, greaterThan(20));
      expect(w.coins, greaterThan(0));
      expect(jumps + ducks, greaterThan(5));
      expect(shifts, greaterThan(20));
    }
  });

  test('near misses at speed earn a bonus', () {
    final w = DodgeWorld(generate: false);
    w.distance = 600; // fast enough
    w.injectRow('.B.', ahead: 12);
    w.laneRight();
    runFor(w, 1.5);
    expect(w.isOver, isFalse);
    expect(w.nearMisses, 1);
    expect(w.bonus, DodgeWorld.nearMissBonus);
  });

  test('runs are deterministic per seed', () {
    String play(int seed) {
      final w = DodgeWorld(seed: seed, recordRows: true);
      runFor(w, 40, each: bot);
      return '${w.rowLog.join(',')}|${w.score}|${w.coins}|${w.distance.toStringAsFixed(6)}|${w.isOver}';
    }

    expect(play(5), play(5));
    expect(play(5), isNot(play(6)));
  });

  test('renderer smoke: swipes and taps steer, renders, ends once with won == null', () {
    final save = CartridgeSave()..bestScore = 321;
    late DodgeLaneGame game;
    final session = FlameCartridgeSession<DodgeLaneGame>(
      makeContext(save: save),
      (s) => game = DodgeLaneGame(s, seed: 4),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    expect(game.best, 321);
    final w = game.run;
    // Tap right half, then swipe left twice.
    game.onPointerDown(Vector2(300, 600));
    game.onPointerUp(Vector2(302, 601));
    expect(w.targetLane, 2);
    for (var i = 0; i < 2; i++) {
      game.onPointerDown(Vector2(200, 600));
      game.onPointerMove(Vector2(170, 602), Vector2(-30, 2));
      game.onPointerUp(Vector2(160, 602));
    }
    expect(w.targetLane, 0);
    // Swipe up = jump, swipe down = duck.
    game.onPointerDown(Vector2(200, 600));
    game.onPointerMove(Vector2(201, 560), Vector2(1, -40));
    game.onPointerUp(Vector2(201, 560));
    expect(w.airborne, isTrue);
    game.onPointerDown(Vector2(200, 600));
    game.onPointerMove(Vector2(201, 640), Vector2(1, 40));
    game.onPointerUp(Vector2(201, 640));
    expect(w.ducking, isTrue);
    expect(w.airborne, isFalse);

    w.injectPickup(PickupKind.shield, 0, ahead: 2);
    w.injectCoin(0, ahead: 3);
    for (var i = 0; i < 30; i++) {
      game.update(dt);
    }
    paint();
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);

    // Park in the middle lane in front of an unavoidable wall.
    w.debugClear();
    w.shield = false;
    w.laneRight();
    w.injectRow('BBB', ahead: 8);
    for (var i = 0; i < 180 && session.state == SessionState.running; i++) {
      game.update(dt);
      if (i % 20 == 0) paint();
    }
    expect(w.isOver, isTrue);
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isNull);
    expect(session.result!.score, w.score);
    paint();

    // Restart builds a fresh run.
    session.restart();
    expect(identical(game.run, w), isFalse);
    expect(game.run.distance, 0);
  });
}
