import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/gulp_hole/gulp_hole.dart';
import 'package:yantrasobi/cartridges/gulp_hole/gulp_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

void main() {
  /// An empty city with rivals out of play, so each test controls the scene.
  GulpWorld emptyWorld({int seed = 42}) {
    final w = GulpWorld(seed: seed, populate: false)..debugDisableRivals();
    return w;
  }

  void run(GulpWorld w, double seconds) {
    for (var t = 0.0; t < seconds; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  test('manifest is valid', () {
    expect(GulpHoleCartridge.kManifest.validate(), isEmpty);
    expect(GulpHoleCartridge.kManifest.id, 'gulp-hole');
  });

  test('a populated city scatters 150-250 objects inside the arena', () {
    final w = GulpWorld(seed: 7);
    expect(w.objects.length, inInclusiveRange(150, 250));
    for (final o in w.objects) {
      expect(o.pos.x, inInclusiveRange(o.radius, w.width - o.radius));
      expect(o.pos.y, inInclusiveRange(o.radius, w.height - o.radius));
    }
    expect(w.holes, hasLength(4));
    expect(w.entityCount, w.objects.length + 4);
  });

  test('swallowing a smaller object scores, grows and removes it', () {
    final w = emptyWorld();
    final p = w.player;
    // Enough pebbles to reach the first size level (8 XP).
    final pebbles = [for (var i = 0; i < 8; i++) w.debugAddObject(ObjTier.pebble, p.pos.x + 2, p.pos.y + 2)];
    // A far-away house keeps the city-share win from ending the round early.
    w.debugAddObject(ObjTier.house, 200, 200);
    final r0 = p.radius;
    run(w, 0.1);
    expect(w.isOver, isFalse);
    expect(pebbles.every((o) => !o.alive), isTrue);
    expect(p.swallowed, 8);
    expect(p.level, 1);
    expect(w.score, greaterThanOrEqualTo(8 * ObjTier.pebble.points));
    run(w, 1);
    expect(p.radius, greaterThan(r0));
    expect(p.radius, closeTo(GulpWorld.radiusForLevel(1), 0.5));
    // Level 1 is big enough for a car.
    final car = w.debugAddObject(ObjTier.car, p.pos.x, p.pos.y + 5);
    run(w, 0.05);
    expect(car.alive, isFalse);
  });

  test('objects bigger than 90% of the hole cannot be swallowed and block the hole', () {
    final w = emptyWorld();
    final p = w.player;
    final house = w.debugAddObject(ObjTier.house, p.pos.x + 30, p.pos.y);
    final car = w.debugAddObject(ObjTier.car, p.pos.x - 6, p.pos.y);
    expect(p.canSwallowObject(car), isFalse); // 25 > 22 * 0.9
    w.input.setValues(1, 0); // drive straight into the house
    run(w, 1.5);
    expect(house.alive, isTrue);
    expect(car.alive, isTrue);
    expect(w.score, 0);
    // The hole's centre is held off the house footprint.
    expect(p.pos.distanceTo(house.pos), greaterThanOrEqualTo(house.radius * 0.7 - 0.01));
  });

  test('a hole eats a rival at least 20% smaller; similar sizes only jostle', () {
    final w = GulpWorld(seed: 3, populate: false);
    final p = w.player;
    final rival = w.holes[1];
    // Equal size: no eating, pushed apart.
    rival.pos.setValues(p.pos.x + 10, p.pos.y);
    w.update(1 / 60);
    expect(rival.alive, isTrue);
    expect(p.canEatHole(rival), isFalse);
    expect(p.pos.distanceTo(rival.pos), greaterThan(10));
    // Player grows: now rival is > 20% smaller and gets gulped.
    w.debugSetLevel(p, 3); // radius 40 vs 22 (<= 32)
    for (final h in w.rivals) {
      h.pos.setValues(100, 100);
    }
    rival.pos.setValues(p.pos.x + 5, p.pos.y);
    w.update(1 / 60);
    expect(rival.alive, isFalse);
    expect(p.holesEaten, 1);
    expect(w.score, greaterThanOrEqualTo(300));
    expect(w.isOver, isFalse);
    // The rival respawns small after the delay.
    run(w, GulpWorld.rivalRespawnDelay + 0.2);
    expect(rival.alive, isTrue);
    expect(rival.level, 0);
    expect(rival.radius, GulpWorld.baseRadius);
    expect(rival.pos.x, inInclusiveRange(0, w.width));
    expect(rival.pos.distanceTo(p.pos), greaterThanOrEqualTo(GulpWorld.rivalMinSpawnDistance));
  });

  test('rival holes eat objects on their own', () {
    final w = GulpWorld(seed: 5, populate: false);
    final rival = w.holes[1];
    final pebble = w.debugAddObject(ObjTier.pebble, rival.pos.x + 120, rival.pos.y);
    run(w, 2);
    expect(pebble.alive, isFalse);
    expect(rival.swallowed, 1);
    expect(w.score, 0); // rivals do not score for the player
  });

  test('rivals start far from the player and grow at 70% of the player rate', () {
    final w = GulpWorld(seed: 5);
    for (final h in w.rivals) {
      expect(h.pos.distanceTo(w.player.pos), greaterThanOrEqualTo(GulpWorld.rivalMinSpawnDistance));
    }
    final e = GulpWorld(seed: 5, populate: false);
    final rival = e.holes[1];
    for (var i = 0; i < 10; i++) {
      e.debugAddObject(ObjTier.pebble, rival.pos.x + 1, rival.pos.y + 1);
    }
    for (var i = 0; i < 10; i++) {
      e.debugAddObject(ObjTier.pebble, e.player.pos.x + 1, e.player.pos.y + 1);
    }
    e.update(1 / 60);
    expect(rival.swallowed, 10);
    expect(e.player.swallowed, 10);
    expect(e.player.xp, 10);
    expect(rival.xp, 7); // 10 XP * 0.7
  });

  test('the player cannot be eaten during the 20 s start grace', () {
    final w = GulpWorld(seed: 11, populate: false);
    final rival = w.holes[1];
    w.debugSetLevel(rival, 6); // radius 58: easily big enough
    rival.pos.setValues(w.player.pos.x + 2, w.player.pos.y);
    run(w, 3);
    expect(w.player.alive, isTrue);
    expect(w.isOver, isFalse);
    expect(w.player.shield, closeTo(GulpWorld.playerGraceTime - 3, 0.05));
    expect(rival.canEatHole(w.player), isFalse);
    expect(w.huntTargetFor(rival), isNull); // nobody hunts a shielded player
    // Once grace runs out, the same overlap is fatal.
    w.debugEndGrace();
    rival.pos.setValues(w.player.pos.x + 2, w.player.pos.y);
    run(w, 0.1);
    expect(w.phase, GulpPhase.lost);
  });

  test('rivals only hunt a player that is 35% smaller and nearby; otherwise they feed', () {
    final w = GulpWorld(seed: 4, populate: false)..debugEndGrace();
    final p = w.player;
    final rival = w.holes[1];
    // Radius 28 vs 22: big enough to eat on contact (20%) but not to hunt (35%).
    w.debugSetLevel(rival, 1);
    rival.pos.setValues(p.pos.x + 150, p.pos.y);
    expect(rival.radius / p.radius, lessThan(GulpWorld.huntSizeRatio));
    expect(w.huntTargetFor(rival), isNull);
    final pebble = w.debugAddObject(ObjTier.pebble, p.pos.x + 330, p.pos.y);
    run(w, 1.5);
    expect(pebble.alive, isFalse);
    expect(rival.pos.distanceTo(p.pos), greaterThan(150));
    expect(w.isOver, isFalse);
    // Radius 34 (>= 35% bigger) and close: now the player is fair game...
    w.debugSetLevel(rival, 2);
    rival.pos.setValues(p.pos.x + 150, p.pos.y);
    expect(w.huntTargetFor(rival), same(p));
    // ...but not from across the map.
    rival.pos.setValues(p.pos.x + GulpWorld.huntRange + 50, p.pos.y);
    expect(w.huntTargetFor(rival), isNull);
  });

  test('a passive circling player survives past the grace and mostly past 30 s', () {
    var past30 = 0;
    for (var seed = 1; seed <= 10; seed++) {
      final w = GulpWorld(seed: seed);
      while (!w.isOver && w.time < 30) {
        final a = w.time * 0.3; // slow circle, eats whatever it rolls over
        w.input.setValues(math.cos(a) * 0.8, math.sin(a) * 0.8);
        w.update(1 / 30);
      }
      expect(w.time, greaterThanOrEqualTo(GulpWorld.playerGraceTime), reason: 'seed $seed');
      if (w.player.alive) past30++;
    }
    expect(past30, greaterThanOrEqualTo(8));
  });

  test('being swallowed by a bigger rival loses the round', () {
    final w = GulpWorld(seed: 11, populate: false);
    final rival = w.holes[1];
    w
      ..debugSetLevel(rival, 4) // radius 46 vs player 22
      ..debugEndGrace();
    rival.pos.setValues(w.player.pos.x + 4, w.player.pos.y);
    run(w, 0.2);
    expect(w.phase, GulpPhase.lost);
    expect(w.isOver, isTrue);
    expect(w.eatenBy, same(rival));
    expect(w.player.alive, isFalse);
  });

  test('timer end: biggest hole wins, otherwise lose', () {
    final winner = GulpWorld(seed: 1, populate: false, roundTime: 2);
    winner.debugSetLevel(winner.player, 2);
    for (final h in winner.rivals) {
      h.pos.setValues(100, 100 + h.id * 300.0);
    }
    run(winner, 2.5);
    expect(winner.phase, GulpPhase.won);
    expect(winner.timeLeft, 0);

    final loser = GulpWorld(seed: 1, populate: false, roundTime: 2);
    loser.debugSetLevel(loser.holes[2], 2);
    run(loser, 2.5);
    expect(loser.isOver, isTrue);
    expect(loser.phase, GulpPhase.lost);
    expect(loser.playerRank, greaterThan(1));
    expect(loser.eatenBy, isNull);
  });

  test('swallowing most of the city (60%) wins early', () {
    final w = emptyWorld();
    final p = w.player;
    w.debugAddObject(ObjTier.pebble, p.pos.x, p.pos.y);
    w.debugAddObject(ObjTier.pebble, 50, 50);
    run(w, 0.1);
    expect(w.cityShare, 0.5); // not enough yet
    expect(w.isOver, isFalse);
    w.debugAddObject(ObjTier.cone, p.pos.x + 3, p.pos.y); // 3 of 4 XP eaten
    run(w, 0.1);
    expect(w.cityShare, greaterThanOrEqualTo(GulpWorld.cityWinShare));
    expect(w.phase, GulpPhase.won);
    expect(w.endedByCity, isTrue);
  });

  test('joystick moves the hole and the arena clamps it', () {
    final w = emptyWorld();
    final p = w.player;
    final start = p.pos.clone();
    w.input.setValues(3, 0); // over-long input is normalised
    run(w, 0.5);
    expect(p.pos.x - start.x, closeTo(p.speed * 0.5, 8));
    w.input.setValues(1, -1);
    run(w, 30);
    expect(p.pos.x, lessThanOrEqualTo(w.width - p.radius + 1e-6));
    expect(p.pos.y, greaterThanOrEqualTo(p.radius - 1e-6));
    w.input.setValues(-1, 1);
    run(w, 30);
    expect(p.pos.x, greaterThanOrEqualTo(p.radius - 1e-6));
    expect(p.pos.y, lessThanOrEqualTo(w.height - p.radius + 1e-6));
  });

  test('same seed gives identical simulations', () {
    GulpWorld make() => GulpWorld(seed: 9);
    final a = make();
    final b = make();
    a.input.setValues(0.6, -0.8);
    b.input.setValues(0.6, -0.8);
    run(a, 20);
    run(b, 20);
    expect(a.objects.length, b.objects.length);
    expect(a.score, b.score);
    expect(a.aliveObjects, b.aliveObjects);
    for (var i = 0; i < a.holes.length; i++) {
      expect(a.holes[i].pos, b.holes[i].pos);
      expect(a.holes[i].xp, b.holes[i].xp);
    }
    // Rivals actually fed during the run.
    expect(a.rivals.any((h) => h.swallowed > 0), isTrue);
  });

  testWidgets('renderer runs a round with drag input and reports one result', (tester) async {
    final audio = SilentAudio();
    final ctx = CartridgeContext(
      manifest: GulpHoleCartridge.kManifest,
      save: CartridgeSave(),
      audio: audio,
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    final session = const GulpHoleCartridge().createSession(ctx) as FlameCartridgeSession<GulpHoleGame>;
    session.start();
    await tester.pumpWidget(MaterialApp(home: Builder(builder: session.buildView)));
    await tester.pump();
    final gesture = await tester.startGesture(const Offset(200, 500));
    for (var i = 0; i < 90; i++) {
      await gesture.moveBy(const Offset(1, -1));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    final w = session.game.world0;
    expect(w.time, greaterThan(0.5));
    expect(session.game.entityCount, greaterThan(100));
    // Fast-forward to the final moments and let the round end.
    w.time = w.roundTime - 0.2;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(w.isOver, isTrue);
    expect(session.state, SessionState.ended);
    expect(session.result!.score, w.score);
    expect(session.result!.won, w.phase == GulpPhase.won);
    expect(audio.played, isNotEmpty);
    session.dispose();
  });
}
