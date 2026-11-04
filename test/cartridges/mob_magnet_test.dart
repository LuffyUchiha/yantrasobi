import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/mob_magnet/mob_magnet.dart';
import 'package:yantrasobi/cartridges/mob_magnet/mob_world.dart';

void main() {
  void run(MobWorld w, double seconds) {
    for (var t = 0.0; t < seconds && !w.isOver; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  MobWorld quiet() => MobWorld(seed: 3)
    ..debugClearNeutrals()
    ..debugFreezeRivals();

  test('manifest is valid', () => expect(MobMagnetCartridge.kManifest.validate(), isEmpty));

  test('city has buildings, citizens and four leaders in open space', () {
    final w = MobWorld(seed: 1);
    expect(w.buildings, isNotEmpty);
    expect(w.teams.skip(1).length, 4);
    for (final t in w.teams.skip(1)) {
      expect(w.blocked(t.leader.x, t.leader.z), isFalse);
      expect(t.size, 1);
    }
    expect(w.teams[0].size, w.citizens);
  });

  test('joystick moves the leader and buildings block movement', () {
    final w = quiet();
    final l = w.player.leader;
    final x0 = l.x;
    w.inputX = 1;
    run(w, 0.5);
    expect(l.x, greaterThan(x0 + 2));
    w.inputX = 1;
    run(w, 20);
    expect(w.blocked(l.x, l.z), isFalse);
    expect(l.x, lessThanOrEqualTo(MobWorld.size));
  });

  test('touching a citizen recruits it and followers trail the leader', () {
    final w = quiet();
    final l = w.player.leader;
    final c = w.debugSpawn(0, l.x + 0.5, l.z);
    run(w, 0.1);
    expect(c.team, 1);
    expect(w.player.size, 2);
    w.inputZ = 1;
    run(w, 1.5);
    final d = math.sqrt(math.pow(c.x - l.x, 2) + math.pow(c.z - l.z, 2));
    expect(d, lessThan(3));
  });

  test('a bigger mob absorbs members of a smaller one on contact', () {
    final w = quiet();
    final l = w.player.leader;
    for (var i = 0; i < 5; i++) {
      w.debugSpawn(1, l.x + 0.1 * i, l.z + 0.3);
    }
    final rival = w.teams[2];
    final victim = w.debugSpawn(rival.id, l.x + 0.6, l.z);
    run(w, 0.1);
    expect(victim.team, 1);
    expect(w.player.absorbed, greaterThanOrEqualTo(1));
  });

  test('touching a smaller rival leader eliminates that rival', () {
    final w = quiet();
    final l = w.player.leader;
    w.debugSpawn(1, l.x, l.z + 0.4);
    final rival = w.teams[2];
    rival.leader
      ..x = l.x + 0.5
      ..z = l.z;
    run(w, 0.1);
    expect(rival.alive, isFalse);
  });

  test('the player leader touched by a bigger mob loses the run', () {
    final w = quiet();
    final l = w.player.leader;
    final rival = w.teams[3];
    for (var i = 0; i < 6; i++) {
      w.debugSpawn(rival.id, l.x + 0.4, l.z + 0.05 * i);
    }
    run(w, 0.2);
    expect(w.phase, MobPhase.lost);
  });

  test('absorbing every rival wins early', () {
    final w = quiet();
    final l = w.player.leader;
    for (var i = 0; i < 3; i++) {
      w.debugSpawn(1, l.x, l.z + 0.2 * i);
    }
    for (final t in w.teams.skip(2)) {
      t.leader
        ..x = l.x + 0.5
        ..z = l.z;
    }
    run(w, 0.3);
    expect(w.phase, MobPhase.won);
    expect(w.score, greaterThan(500));
  });

  test('when time runs out the largest mob wins', () {
    final w = MobWorld(seed: 5, roundTime: 1)
      ..debugClearNeutrals()
      ..debugFreezeRivals();
    final l = w.player.leader;
    w.debugSpawn(1, l.x, l.z + 0.3);
    run(w, 2);
    expect(w.phase, MobPhase.won);
    final w2 = MobWorld(seed: 5, roundTime: 1)
      ..debugClearNeutrals()
      ..debugFreezeRivals();
    final r = w2.teams[2].leader;
    w2.debugSpawn(2, r.x, r.z + 0.3);
    run(w2, 2);
    expect(w2.phase, MobPhase.lost);
  });

  test('bots recruit on their own; the sim is deterministic', () {
    MobWorld sim() {
      final w = MobWorld(seed: 8);
      run(w, 12);
      return w;
    }

    final a = sim(), b = sim();
    expect(a.teams.skip(2).fold<int>(0, (s, t) => s + t.size), greaterThan(6));
    expect([for (final t in a.teams) t.size], [for (final t in b.teams) t.size]);
  });

  test('a recruiting player bot usually ends the round alive and growing', () {
    var alive = 0;
    for (var seed = 1; seed <= 8; seed++) {
      final w = MobWorld(seed: seed);
      var t = 0.0;
      while (!w.isOver && t < 75) {
        // Head toward the nearest neutral, away from bigger rival leaders.
        final l = w.player.leader;
        Person? best;
        var bestD = double.infinity;
        for (final p in w.people) {
          if (p.team != 0) continue;
          final d = (p.x - l.x).abs() + (p.z - l.z).abs();
          if (d < bestD) {
            bestD = d;
            best = p;
          }
        }
        var ix = 0.0, iz = 0.0;
        if (best != null) {
          ix = best.x - l.x;
          iz = best.z - l.z;
        }
        for (final r in w.teams.skip(2)) {
          if (!r.alive || r.size <= w.player.size) continue;
          final dx = l.x - r.leader.x, dz = l.z - r.leader.z;
          final d2 = dx * dx + dz * dz;
          if (d2 < 64) {
            ix += dx * 4;
            iz += dz * 4;
          }
        }
        final len = math.sqrt(ix * ix + iz * iz);
        w.inputX = len > 0 ? ix / len : 0;
        w.inputZ = len > 0 ? iz / len : 0;
        w.update(1 / 30);
        t += 1 / 30;
      }
      if (w.player.alive && w.player.size > 20) alive++;
    }
    expect(alive, greaterThanOrEqualTo(5));
  });
}
