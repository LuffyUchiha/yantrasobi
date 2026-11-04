import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/crowd_forge/crowd_forge.dart';
import 'package:yantrasobi/cartridges/crowd_forge/crowd_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/projector.dart';
import 'package:vector_math/vector_math.dart';

import 'dart:ui';

void main() {
  void run(CrowdWorld w, double seconds) {
    for (var t = 0.0; t < seconds; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  CrowdWorld quiet({int level = 1}) {
    final w = CrowdWorld(level: level, seed: 3)..debugStopFoes();
    w.gates.clear();
    w.blades.clear();
    return w;
  }

  test('manifest is valid', () => expect(CrowdForgeCartridge.kManifest.validate(), isEmpty));

  test('holding fires runners from the launcher at the fire rate', () {
    final w = quiet();
    w.firing = true;
    run(w, 1.0);
    expect(w.fired, inInclusiveRange(8, 10));
    expect(w.liveUnits, w.fired);
    w.firing = false;
    final fired = w.fired;
    run(w, 1.0);
    expect(w.fired, fired);
  });

  test('aim moves the launcher toward the target, clamped to the lane', () {
    final w = quiet();
    w.aim(5); // beyond range
    run(w, 1);
    expect(w.launcherX, closeTo(CrowdWorld.laneHalfWidth, 1e-6));
  });

  test('a ×3 gate turns one runner into three, once per gate', () {
    final w = quiet();
    w.gates.add(Gate(baseX: 0, z: 5, multiplier: 3));
    w.debugSpawnUnit(0, 4);
    run(w, 0.5);
    expect(w.liveUnits, 3);
    expect(w.clones, 2);
    run(w, 0.5); // clones carry the gate bit: no re-multiplying
    expect(w.liveUnits, 3);
  });

  test('runners outside a gate span are not multiplied', () {
    final w = quiet();
    w.gates.add(Gate(baseX: -2, z: 5, multiplier: 2, width: 1));
    w.debugSpawnUnit(2, 4);
    run(w, 0.5);
    expect(w.liveUnits, 1);
  });

  test('runners and foes trade HP one for one', () {
    final w = quiet();
    w.debugSpawnUnit(0, 10);
    w.debugSpawnUnit(0.1, 10);
    final brute = w.debugSpawnFoe(0, 11, hp: 3);
    run(w, 0.5);
    expect(w.liveUnits, 0);
    expect(brute.alive, isTrue);
    expect(brute.hp, 1);
  });

  test('runners reaching the forge damage it; zero forge HP wins', () {
    final w = quiet();
    w.forgeHp = 2;
    w.debugSpawnUnit(0, CrowdWorld.forgeZ - 2);
    w.debugSpawnUnit(0.5, CrowdWorld.forgeZ - 2);
    run(w, 1);
    expect(w.phase, CrowdPhase.won);
    expect(w.score, greaterThan(500));
  });

  test('foes reaching the base cost HP; zero base HP loses', () {
    final w = quiet();
    w.baseHp = 1;
    w.debugSpawnFoe(0, 2);
    run(w, 2);
    expect(w.phase, CrowdPhase.lost);
  });

  test('every 45 shots launches a champion that ignores gates', () {
    final w = quiet();
    w.charge = CrowdWorld.championCharge;
    w.gates.add(Gate(baseX: 0, z: 3, multiplier: 2, width: 7));
    w.firing = true;
    run(w, 0.05);
    w.firing = false;
    final champ = w.units.firstWhere((u) => u.alive);
    expect(champ.champion, isTrue);
    expect(champ.hp, 12);
    run(w, 1);
    expect(w.liveUnits, 1);
  });

  test('unit pool is capped (instanced rendering uses fixed slots)', () {
    final w = quiet();
    w.gates.add(Gate(baseX: 0, z: 2, multiplier: 4, width: 7));
    w.firing = true;
    run(w, 15);
    expect(w.liveUnits, lessThanOrEqualTo(CrowdWorld.maxUnits));
    expect(w.units.length, CrowdWorld.maxUnits);
  });

  test('levels add gate rows and blades', () {
    expect(CrowdWorld(level: 1, seed: 1).blades, isEmpty);
    expect(CrowdWorld(level: 5, seed: 1).blades, hasLength(2));
    expect(CrowdWorld(level: 5, seed: 1).gates.map((g) => g.z).toSet(), hasLength(3));
  });

  test('projector maps world +X to screen right and ground clicks round-trip', () {
    final pr = Projector(eye: Vector3(0, 13.5, -9), target: Vector3(0, 0, 13), size: const Size(400, 800));
    final left = pr.projectXYZ(-2, 0, 5)!;
    final right = pr.projectXYZ(2, 0, 5)!;
    expect(right.dx, greaterThan(left.dx));
    final near = pr.projectXYZ(0, 0, 0)!;
    final far = pr.projectXYZ(0, 0, 30)!;
    expect(far.dy, lessThan(near.dy));
    final hit = pr.unprojectToGround(right)!;
    expect(hit.x, closeTo(2, 1e-6));
    expect(hit.z, closeTo(5, 1e-6));
  });

  test('pacing: level 1 is not won in 8 seconds of firing, and idling loses', () {
    final bot = CrowdWorld(level: 1, seed: 11)..firing = true;
    run(bot, 8);
    expect(bot.phase, CrowdPhase.playing);
    final idle = CrowdWorld(level: 1, seed: 11);
    run(idle, 90);
    expect(idle.phase, CrowdPhase.lost);
  });

  test('pacing: a sweeping bot can clear level 1 within two minutes', () {
    final w = CrowdWorld(level: 1, seed: 5)..firing = true;
    var t = 0.0;
    while (!w.isOver && t < 120) {
      w.aim(math.sin(t * 0.8));
      w.update(1 / 30);
      t += 1 / 30;
    }
    expect(w.phase, CrowdPhase.won, reason: 'took ${t.toStringAsFixed(1)}s, forge ${w.forgeHp}');
    // ignore: avoid_print
    print('level 1 cleared by bot in ${t.toStringAsFixed(1)}s');
  });
}
