import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/cloud_tower/cloud_tower.dart';
import 'package:yantrasobi/cartridges/cloud_tower/tower_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double step = TowerWorld.step;

/// Waits for the slab to line up exactly and drops it.
DropOutcome? dropCentred(TowerWorld w) {
  w.debugWaitFor(0);
  return w.drop();
}

void main() {
  test('manifest is valid', () {
    const m = CloudTowerCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'cloud-tower');
    expect(m.version, '1.0.0');
  });

  test('a fresh tower has a foundation and a slab entering from one side along X', () {
    final w = TowerWorld(seed: 3);
    expect(w.floors, 0);
    expect(w.score, 0);
    expect(w.isOver, isFalse);
    expect(w.top.w, TowerWorld.baseSize);
    expect(w.top.d, TowerWorld.baseSize);
    final m = w.moving!;
    expect(w.axis, SlideAxis.x);
    expect(m.level, 1);
    expect(m.z, w.top.z);
    expect(w.targetOffset.abs(), closeTo(TowerWorld.slideRange, 1e-9));
    // It starts on the side opposite to its travel direction.
    expect(w.targetOffset.sign, -w.direction);
  });

  test('the slab slides at the current speed and bounces inside the slide range', () {
    final w = TowerWorld(seed: 5);
    final start = w.targetOffset;
    for (var i = 0; i < 60; i++) {
      w.update(step);
    }
    expect((w.targetOffset - start).abs(), closeTo(TowerWorld.speedFor(1) * 0.5, 1e-6));
    expect(w.moving!.z, w.top.z, reason: 'only the slide axis moves');
    var maxSeen = 0.0;
    var flips = 0;
    var dir = w.direction;
    for (var i = 0; i < 1200; i++) {
      w.update(step);
      maxSeen = math.max(maxSeen, w.targetOffset.abs());
      if (w.direction != dir) {
        flips++;
        dir = w.direction;
      }
    }
    expect(maxSeen, lessThanOrEqualTo(TowerWorld.slideRange + 1e-9));
    expect(flips, greaterThanOrEqualTo(2));
  });

  test('slide axis alternates X, Z, X, Z and the other coordinate is aligned with the top', () {
    final w = TowerWorld(seed: 9);
    final axes = <SlideAxis>[];
    for (var i = 0; i < 6; i++) {
      axes.add(w.axis);
      final m = w.moving!;
      if (w.axis == SlideAxis.x) {
        expect(m.z, w.top.z);
      } else {
        expect(m.x, w.top.x);
      }
      w.debugSetOffset(i.isEven ? 1.5 : -1.0);
      w.drop();
    }
    expect(axes, [SlideAxis.x, SlideAxis.z, SlideAxis.x, SlideAxis.z, SlideAxis.x, SlideAxis.z]);
  });

  test('an overhang on X is sliced: overlap stays, the cut piece falls away', () {
    final w = TowerWorld(seed: 1);
    expect(w.axis, SlideAxis.x);
    w.debugSetOffset(3);
    expect(w.drop(), DropOutcome.slice);
    final s = w.top;
    expect(s.level, 1);
    expect(s.w, closeTo(7, 1e-9));
    expect(s.x, closeTo(1.5, 1e-9));
    expect(s.d, TowerWorld.baseSize);
    expect(w.debris, hasLength(1));
    final b = w.debris.single;
    expect(b.w, closeTo(3, 1e-9));
    expect(b.x, closeTo(6.5, 1e-9), reason: 'cut spans x = 5..8');
    expect(b.d, TowerWorld.baseSize);
    expect(w.streak, 0);
    expect(w.score, 1);
    // The debris falls under gravity and is cleaned up.
    final y0 = b.y;
    for (var i = 0; i < 5; i++) {
      w.update(0.1);
    }
    expect(b.y, lessThan(y0 - 2));
    expect(b.vx, greaterThan(0));
    expect(b.rot, isNot(0));
    for (var i = 0; i < 40; i++) {
      w.update(0.1);
    }
    expect(w.debris, isEmpty);
  });

  test('an overhang on Z (negative side) is sliced symmetrically', () {
    final w = TowerWorld(seed: 1);
    w.debugSetOffset(2); // floor 1 on X: x in -3..7 => w 8, x 1.
    w.drop();
    expect(w.axis, SlideAxis.z);
    w.debugSetOffset(-4);
    expect(w.drop(), DropOutcome.slice);
    final s = w.top;
    expect(s.level, 2);
    expect(s.d, closeTo(6, 1e-9));
    expect(s.z, closeTo(-2, 1e-9));
    expect(s.w, closeTo(8, 1e-9));
    expect(s.x, closeTo(1, 1e-9));
    final b = w.debris.last;
    expect(b.d, closeTo(4, 1e-9));
    expect(b.z, closeTo(-7, 1e-9), reason: 'cut spans z = -9..-5');
    expect(b.w, closeTo(8, 1e-9));
    expect(b.vz, lessThan(0));
  });

  test('drops within the tolerance snap exactly and build a perfect streak with bonuses', () {
    final w = TowerWorld(seed: 2);
    w.debugSetOffset(TowerWorld.perfectTolerance * 0.9);
    expect(w.drop(), DropOutcome.perfect);
    expect(w.top.x, 0);
    expect(w.top.w, TowerWorld.baseSize);
    expect(w.debris, isEmpty);
    expect(w.streak, 1);
    w.debugSetOffset(-TowerWorld.perfectTolerance * 0.5);
    expect(w.drop(), DropOutcome.perfect);
    expect(w.top.z, 0);
    expect(w.streak, 2);
    expect(w.perfects, 2);
    expect(w.score, 2 + TowerWorld.perfectBonus(1) + TowerWorld.perfectBonus(2));
    // Just outside the tolerance is a slice and resets the streak.
    w.debugSetOffset(TowerWorld.perfectTolerance + 0.05);
    expect(w.drop(), DropOutcome.slice);
    expect(w.streak, 0);
    expect(w.bestStreak, 2);
    expect(w.top.w, closeTo(TowerWorld.baseSize - TowerWorld.perfectTolerance - 0.05, 1e-9));
  });

  test('every 4 perfects in a row regrows the slab, capped at the original size', () {
    final w = TowerWorld(seed: 4);
    w.debugSetOffset(2);
    w.drop();
    w.debugSetOffset(-1.5);
    w.drop();
    expect(w.top.w, closeTo(8, 1e-9));
    expect(w.top.d, closeTo(8.5, 1e-9));
    for (var i = 0; i < 3; i++) {
      w.debugSetOffset(0);
      w.drop();
    }
    expect(w.top.w, closeTo(8, 1e-9), reason: 'no regrow before the 4th perfect');
    w.debugSetOffset(0);
    w.drop();
    expect(w.streak, 4);
    expect(w.regrows, 1);
    expect(w.top.w, closeTo(8 + TowerWorld.regrowStep, 1e-9));
    expect(w.top.d, closeTo(8.5 + TowerWorld.regrowStep, 1e-9));
    // Keep going: it never exceeds the original size.
    for (var i = 0; i < 40; i++) {
      w.debugSetOffset(0);
      w.drop();
      expect(w.top.w, lessThanOrEqualTo(TowerWorld.baseSize));
      expect(w.top.d, lessThanOrEqualTo(TowerWorld.baseSize));
    }
    expect(w.top.w, TowerWorld.baseSize);
    expect(w.top.d, TowerWorld.baseSize);
    expect(w.streak, 44);
  });

  test('a drop with no overlap ends the run and the whole slab falls', () {
    final w = TowerWorld(seed: 6);
    w.debugSetOffset(TowerWorld.baseSize + 0.5);
    expect(w.drop(), DropOutcome.miss);
    expect(w.isOver, isTrue);
    expect(w.floors, 0);
    expect(w.moving, isNull);
    expect(w.debris.single.w, TowerWorld.baseSize);
    expect(w.drop(), isNull, reason: 'no more drops after game over');
    // Exactly touching edges is also a miss.
    final w2 = TowerWorld(seed: 6);
    w2.debugSetOffset(-TowerWorld.baseSize);
    expect(w2.drop(), DropOutcome.miss);
  });

  test('speed rises with height and is capped', () {
    expect(TowerWorld.speedFor(1), TowerWorld.baseSpeed);
    expect(TowerWorld.speedFor(30), greaterThan(TowerWorld.speedFor(10)));
    expect(TowerWorld.speedFor(1000), TowerWorld.maxSpeed);
    final w = TowerWorld(seed: 7);
    final s0 = w.speed;
    for (var i = 0; i < 20; i++) {
      dropCentred(w);
    }
    expect(w.speed, greaterThan(s0));
    expect(w.speed, TowerWorld.speedFor(21));
  });

  test('same seed and same inputs give identical towers; different seeds differ', () {
    String play(int seed) {
      final w = TowerWorld(seed: seed);
      final rng = math.Random(99);
      for (var i = 0; i < 40 && !w.isOver; i++) {
        w.update(0.3 + rng.nextDouble() * 1.2);
        w.drop();
      }
      return '${w.snapshot()} hue=${w.hueBase}';
    }

    expect(play(11), play(11));
    expect(play(11), isNot(play(12)));
  });

  test('a bot tapping at the exact centre reaches 100 floors with milestones', () {
    final w = TowerWorld(seed: 21);
    final milestones = <int>[];
    for (var i = 0; i < 100; i++) {
      expect(dropCentred(w), DropOutcome.perfect, reason: 'floor ${i + 1}');
      milestones.addAll(w.events.where((e) => e.kind == TowerEventKind.milestone).map((e) => e.level));
      w.events.clear();
    }
    expect(w.isOver, isFalse);
    expect(w.floors, 100);
    expect(w.top.w, TowerWorld.baseSize);
    expect(w.score, greaterThan(100));
    expect(milestones, [25, 50, 75, 100]);
    expect(w.speed, greaterThan(TowerWorld.baseSpeed * 2));
  });

  test('a bot with random timing error eventually topples the tower', () {
    for (var seed = 0; seed < 5; seed++) {
      final w = TowerWorld(seed: seed);
      final rng = math.Random(seed + 100);
      var n = 0;
      while (!w.isOver && n < 1000) {
        final err = (rng.nextDouble() * 2 - 1) * 2.5;
        w.debugWaitFor(err);
        w.drop();
        n++;
      }
      expect(w.isOver, isTrue, reason: 'seed $seed');
      expect(w.floors, lessThan(200));
    }
  });

  test('renderer smoke: taps drop slabs, renders, ends once with won == null', () {
    final save = CartridgeSave()..bestScore = 12;
    final context = CartridgeContext(
      manifest: CloudTowerCartridge.kManifest,
      save: save,
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    late CloudTowerGame game;
    final session = FlameCartridgeSession<CloudTowerGame>(context, (s) => game = CloudTowerGame(s, seed: 8));
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    expect(game.best, 12);
    final w = game.tower;
    // Perfect drops via the pointer, across the day -> night -> space sky.
    for (var i = 0; i < 160; i++) {
      w.debugWaitFor(0);
      game.onPointerDown(Vector2(200, 600));
      game.onPointerUp(Vector2(200, 600));
      game.update(1 / 60);
      if (i % 20 == 0) paint();
    }
    expect(w.floors, 160);
    // A sloppy drop leaves debris.
    w.debugSetOffset(3);
    game.onPointerDown(Vector2(200, 600));
    for (var i = 0; i < 20; i++) {
      game.update(1 / 60);
    }
    paint();
    expect(w.debris, isNotEmpty);
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);

    // Miss completely.
    w.debugSetOffset(TowerWorld.baseSize * 2);
    game.onPointerDown(Vector2(200, 600));
    expect(w.isOver, isTrue);
    for (var i = 0; i < 200 && session.state == SessionState.running; i++) {
      game.update(1 / 60);
      if (i % 20 == 0) paint();
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isNull);
    expect(session.result!.score, w.score);
    paint();

    session.restart();
    game.onGameResize(Vector2(400, 800));
    expect(identical(game.tower, w), isFalse);
    expect(game.tower.floors, 0);
    paint();
  });
}
