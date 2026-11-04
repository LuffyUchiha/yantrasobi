import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/roll_ridge/ridge_world.dart';
import 'package:yantrasobi/cartridges/roll_ridge/roll_ridge.dart';

void main() {
  void run(RidgeWorld w, double seconds) {
    for (var t = 0.0; t < seconds && !w.isOver; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  /// Steers toward the track centre a little ahead; avoids pushers/bumpers.
  void autopilot(RidgeWorld w) {
    final ahead = w.z + 2.5;
    final seg = w.segmentAt(ahead) ?? w.segmentAt(w.z);
    var target = seg?.centerAt(ahead) ?? w.x;
    for (final h in w.hazards) {
      if (h.z < w.z || h.z - w.z > 6) continue;
      if (h.kind == HazardKind.bumper) target += (w.x >= h.x ? 1 : -1) * 1.4;
    }
    w.steer = ((target - w.x) * 1.5).clamp(-1.0, 1.0);
  }

  test('manifest is valid', () => expect(RollRidgeCartridge.kManifest.validate(), isEmpty));

  test('track is continuous, starts flat and ends with a finish segment', () {
    final w = RidgeWorld(level: 3, seed: 2);
    for (var i = 1; i < w.segments.length; i++) {
      expect(w.segments[i].z0, closeTo(w.segments[i - 1].z1, 1e-9));
      expect(w.segments[i].cx0, closeTo(w.segments[i - 1].cx1, 1e-9));
    }
    expect(w.segments.first.kind, SegmentKind.flat);
    expect(w.segments.last.kind, SegmentKind.finish);
    // Every gap is preceded by a ramp.
    for (var i = 0; i < w.segments.length; i++) {
      if (w.segments[i].kind == SegmentKind.gap) expect(w.segments[i - 1].kind, SegmentKind.ramp);
    }
  });

  test('ball accelerates forward and steering moves it sideways', () {
    final w = RidgeWorld(seed: 1)..debugClearHazards();
    run(w, 1);
    expect(w.z, greaterThan(5));
    final x0 = w.x;
    w.steer = 1;
    run(w, 0.2);
    expect(w.x, greaterThan(x0 + 0.5));
  });

  test('rolling off the edge falls, costs a life and respawns at the checkpoint', () {
    final w = RidgeWorld(seed: 1)..debugClearHazards();
    run(w, 0.5);
    w.steer = 1;
    run(w, 3);
    expect(w.lives, lessThan(RidgeWorld.startLives));
    w.steer = 0;
    run(w, 1.2);
    expect(w.floorAt(w.x, w.z), isNotNull);
  });

  test('losing every life loses the run', () {
    final w = RidgeWorld(seed: 1)..debugClearHazards();
    w.steer = -1;
    run(w, 20);
    expect(w.phase, RidgePhase.lost);
    expect(w.lives, 0);
  });

  test('ramps launch the ball over gaps', () {
    for (var seed = 1; seed < 30; seed++) {
      final w = RidgeWorld(level: 2, seed: seed)..debugClearHazards();
      final ramp = w.segments.where((s) => s.kind == SegmentKind.ramp).firstOrNull;
      if (ramp == null) continue;
      w.debugPlace(ramp.centerAt(ramp.z0 + 0.5), ramp.z0 + 0.5);
      w.speed = w.cruiseSpeed;
      var jumped = false;
      for (var t = 0.0; t < 2 && !w.isOver; t += 1 / 60) {
        autopilot(w);
        w.update(1 / 60);
        if (w.events.any((e) => e.kind == RidgeEventKind.jump)) jumped = true;
      }
      expect(jumped, isTrue);
      expect(w.lives, RidgeWorld.startLives, reason: 'seed $seed: gap should be cleared');
      return;
    }
    fail('no ramp generated');
  });

  test('gems are collected and score', () {
    final w = RidgeWorld(seed: 3)..debugClearHazards();
    final g = w.gems.first;
    w.debugPlace(g.x, g.z - 0.5);
    run(w, 0.2);
    expect(g.taken, isTrue);
    expect(w.gemsTaken, 1);
  });

  test('a bumper knocks the ball sideways', () {
    final w = RidgeWorld(seed: 4);
    w.hazards
      ..clear()
      ..add(Hazard(kind: HazardKind.bumper, x: w.x, z: 8, size: 0.8));
    final x0 = w.x;
    var bumped = false;
    for (var t = 0.0; t < 3 && !w.isOver; t += 1 / 60) {
      w.update(1 / 60);
      if (w.events.any((e) => e.kind == RidgeEventKind.bump)) bumped = true;
    }
    expect(bumped, isTrue);
    expect((w.x - x0).abs() > 0.3 || w.lives < RidgeWorld.startLives, isTrue);
    expect(w.z > 9 || w.lives < RidgeWorld.startLives, isTrue); // never stuck behind it
  });

  test('an autopilot clears level 1 on most seeds and wins', () {
    var wins = 0;
    for (var seed = 1; seed <= 10; seed++) {
      final w = RidgeWorld(level: 1, seed: seed);
      for (var t = 0.0; t < 120 && !w.isOver; t += 1 / 60) {
        autopilot(w);
        w.update(1 / 60);
      }
      if (w.phase == RidgePhase.won) wins++;
    }
    expect(wins, greaterThanOrEqualTo(7));
  });

  test('higher levels are longer and faster; generation is deterministic', () {
    final a = RidgeWorld(level: 1, seed: 9), b = RidgeWorld(level: 6, seed: 9);
    expect(b.trackLength, greaterThan(a.trackLength));
    expect(b.cruiseSpeed, greaterThan(a.cruiseSpeed));
    final c = RidgeWorld(level: 4, seed: 5), d = RidgeWorld(level: 4, seed: 5);
    expect([for (final s in c.segments) s.kind], [for (final s in d.segments) s.kind]);
  });
}
