import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/arrow_survivor/arrow_survivor.dart';
import 'package:yantrasobi/cartridges/arrow_survivor/survivor_world.dart';

void main() {
  SurvivorWorld world({int finalWave = 10}) {
    final w = SurvivorWorld(width: 400, height: 800, seed: 42, finalWave: finalWave);
    w.debugClearSpawnQueue();
    return w;
  }

  void run(SurvivorWorld w, double seconds) {
    for (var t = 0.0; t < seconds; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  test('manifest is valid', () {
    expect(ArrowSurvivorCartridge.kManifest.validate(), isEmpty);
  });

  test('auto-attack fires at the nearest enemy and kills it for score', () {
    final w = world();
    final near = w.debugSpawn(EnemyKind.chaser, 200, 300);
    w.debugSpawn(EnemyKind.chaser, 20, 790);
    expect(w.nearestEnemy(), same(near));
    run(w, 3);
    expect(near.alive, isFalse);
    expect(w.kills, greaterThanOrEqualTo(1));
    expect(w.score, greaterThanOrEqualTo(10));
  });

  test('arrows are pooled and recycled', () {
    final w = world();
    w.debugSpawn(EnemyKind.tank, 200, 100).hp = 1e9;
    run(w, 10);
    // ~18 volleys fired in 10s but the pool stays small because arrows recycle.
    expect(w.arrowPoolSize, lessThan(8));
  });

  test('clearing a wave offers three upgrade cards; choosing starts next wave', () {
    final w = world();
    w.debugSpawn(EnemyKind.chaser, 200, 300);
    run(w, 6);
    expect(w.phase, SurvivorPhase.choosing);
    expect(w.choices, hasLength(3));
    expect(w.choices.toSet(), hasLength(3));
    expect(w.score, greaterThanOrEqualTo(110)); // kill + wave bonus
    final arrowsBefore = w.player.arrows;
    final idx = w.choices.indexOf(Upgrade.multishot);
    if (idx >= 0) {
      w.choose(idx);
      expect(w.player.arrows, arrowsBefore + 1);
    } else {
      w.choose(0);
    }
    expect(w.wave, 2);
    expect(w.phase, SurvivorPhase.fighting);
    expect(w.remainingInWave, SurvivorWorld.waveSize(2));
  });

  test('upgrades apply their effects', () {
    final w = world();
    final p = w.player;
    final interval = p.fireInterval;
    w
      ..applyUpgrade(Upgrade.rapid)
      ..applyUpgrade(Upgrade.pierce)
      ..applyUpgrade(Upgrade.blades)
      ..applyUpgrade(Upgrade.vitality);
    expect(p.fireInterval, lessThan(interval));
    expect(p.pierce, 1);
    expect(p.blades, 1);
    expect(p.maxHp, 125);
    expect(p.hp, 125);
  });

  test('joystick moves the player and stays inside the arena', () {
    final w = world();
    final start = w.player.pos.clone();
    w.input.setValues(1, 0);
    run(w, 0.5);
    expect(w.player.pos.x, greaterThan(start.x + 50));
    w.input.setValues(1, 0);
    run(w, 10);
    expect(w.player.pos.x, lessThanOrEqualTo(400 - w.player.radius));
  });

  test('player dies when HP reaches zero → lost', () {
    final w = world();
    w.player.hp = 5;
    w.player.fireInterval = 999; // no defence
    w.player.fireTimer = 999;
    w.debugSpawn(EnemyKind.tank, w.player.pos.x, w.player.pos.y - 10);
    run(w, 2);
    expect(w.phase, SurvivorPhase.lost);
    expect(w.isOver, isTrue);
  });

  test('clearing the final wave wins', () {
    final w = world(finalWave: 1);
    w.debugSpawn(EnemyKind.chaser, 200, 300);
    run(w, 6);
    expect(w.phase, SurvivorPhase.won);
  });

  test('same seed gives identical simulations', () {
    SurvivorWorld make() => SurvivorWorld(width: 400, height: 800, seed: 9);
    final a = make();
    final b = make();
    run(a, 8);
    run(b, 8);
    expect(a.score, b.score);
    expect(a.enemies.length, b.enemies.length);
    expect(a.player.pos, b.player.pos);
  });
}
