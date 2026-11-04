import 'dart:convert';
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/digit_barrage/barrage_world.dart';
import 'package:yantrasobi/cartridges/digit_barrage/digit_barrage.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// Scripted player: keeps firing, steers under the biggest rock, and picks the
/// closest spot whose drive there is predicted to stay clear of falling rocks.
bool bot(BarrageWorld w, {double maxTime = 240}) {
  w.start();
  w.setFiring(true);
  while (!w.isOver && w.time < maxTime) {
    BarrageRock? best;
    for (final r in w.rocks) {
      if (best == null || r.size > best.size || (r.size == best.size && r.hp > best.hp)) best = r;
    }
    final target = best == null ? BarrageWorld.width / 2 : best.x;
    double? pick;
    var bestCost = double.infinity;
    for (var x = BarrageWorld.cartMin; x <= BarrageWorld.cartMax; x += 8) {
      if (w.dangerAt(x)) continue;
      final cost = (x - target).abs() + 0.3 * (x - w.cartX).abs();
      if (cost < bestCost) {
        bestCost = cost;
        pick = x;
      }
    }
    w.setCartTarget(pick ?? target);
    w.update(1 / 30);
  }
  return w.won;
}

void run(BarrageWorld w, double seconds) {
  for (var t = 0.0; t < seconds && !w.isOver; t += 1 / 60) {
    w.update(1 / 60);
  }
}

CartridgeContext ctxFor(CartridgeSave save, {VoidCallback? onSave}) => CartridgeContext(
  manifest: DigitBarrageCartridge.kManifest,
  save: save,
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    expect(DigitBarrageCartridge.kManifest.validate(), isEmpty);
    expect(DigitBarrageCartridge.kManifest.id, 'digit-barrage');
  });

  test('bullets fly up and each hit knocks the damage off the number', () {
    final w = BarrageWorld(seed: 1, rocks: []);
    final rock = w.addRock(x: w.cartX, y: 120, size: 3, value: 30);
    w.setFiring(true);
    run(w, 0.75);
    expect(w.isOver, isFalse);
    final dealt = 30 - rock.hp;
    expect(dealt, greaterThan(0));
    expect(w.damageDealt, dealt);
    expect(w.bullets, isNotEmpty);
    // Direct hit with an upgraded gun subtracts the damage value.
    final strong = BarrageWorld(seed: 1, rocks: [], upgrades: BarrageUpgrades(damage: 2));
    final r2 = strong.addRock(x: 300, y: 100, size: 2, value: 10);
    strong.hitRock(r2, strong.upgrades.damage);
    expect(r2.hp, 7);
    // Overkill only counts the damage actually dealt.
    final r3 = strong.addRock(x: 60, y: 100, size: 1, value: 2);
    strong.hitRock(r3, 3);
    expect(strong.damageDealt, 3 + 2);
  });

  test('a rock at zero splits into two smaller rocks worth half its value, rounded up', () {
    final w = BarrageWorld(seed: 2, rocks: []);
    final r = w.addRock(x: 180, y: 200, size: 2, value: 7, vx: 50);
    for (var i = 0; i < 7; i++) {
      w.hitRock(r, 1);
    }
    expect(w.rocks, hasLength(2));
    for (final c in w.rocks) {
      expect(c.size, 1);
      expect(c.value, 4);
      expect(c.hp, 4);
      expect(c.r, lessThan(r.r));
      expect(c.vy, lessThan(0), reason: 'children are kicked upward');
    }
    expect(w.rocks[0].vx.sign, isNot(w.rocks[1].vx.sign), reason: 'children fly apart');
    expect(w.splits, 1);
    expect(w.coins, hasLength(1));
    expect(BarrageWorld.childValue(8), 4);
    expect(BarrageWorld.childValue(1), 1);
    expect(BarrageWorld.treeHp(2, 7), 7 + 2 * (4 + 2 * 2));
  });

  test('the smallest rock just pops at zero and drops a coin', () {
    final w = BarrageWorld(seed: 3, rocks: []);
    final r = w.addRock(x: 100, y: 200, size: 0, value: 2);
    w.addRock(x: 300, y: 100, size: 1, value: 5);
    w.hitRock(r, 1);
    expect(w.rocks, hasLength(2));
    w.hitRock(r, 1);
    expect(w.rocks, hasLength(1));
    expect(w.pops, 1);
    expect(w.splits, 0);
    expect(w.coins, hasLength(1));
    expect(w.coins.first.value, w.upgrades.coinValue);
  });

  test('bouncing rocks stay inside the arena and keep a steady bounce height', () {
    for (var size = 0; size <= 3; size++) {
      final r = BarrageRock(id: 0, x: 40, y: 80, size: size, value: 5, vx: 333, vy: -900);
      var minTop = double.infinity;
      var bounces = 0;
      var lastVy = r.vy;
      for (var i = 0; i < 120 * 30; i++) {
        BarrageWorld.stepRock(r, BarrageWorld.step);
        expect(r.x - r.r, greaterThanOrEqualTo(-1e-9));
        expect(r.x + r.r, lessThanOrEqualTo(BarrageWorld.width + 1e-9));
        expect(r.y - r.r, greaterThanOrEqualTo(-1e-9));
        expect(r.y + r.r, lessThanOrEqualTo(BarrageWorld.floorY + 1e-9));
        if (lastVy > 0 && r.vy < 0) bounces++;
        lastVy = r.vy;
        if (i > 120 * 5) minTop = minTop < r.y ? minTop : r.y;
      }
      expect(bounces, greaterThan(8));
      // After settling, the apex matches the size's fixed bounce height.
      final apex = BarrageWorld.floorY - r.r - minTop;
      final expected = BarrageWorld.bounceSpeedFor(size) * BarrageWorld.bounceSpeedFor(size) / (2 * 520);
      expect((apex - expected).abs(), lessThan(12), reason: 'size $size');
    }
  });

  test('a rock touching the cart loses the level', () {
    final w = BarrageWorld(seed: 4, rocks: []);
    w.addRock(x: w.cartX, y: 400, size: 2, value: 99);
    run(w, 3);
    expect(w.phase, BarragePhase.lost);
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    expect(w.events.any((e) => e.kind == BarrageEventKind.lost), isTrue);
    expect(BarrageWorld.rockTouchesCart(BarrageRock(id: 0, x: 50, y: 590, size: 0, value: 1), 300), isFalse);
    // Nothing moves after the end.
    final t = w.time;
    w.update(1);
    expect(w.time, t);
  });

  test('clearing every rock (and its splits) wins and sweeps the coins', () {
    final w = BarrageWorld(seed: 5, rocks: []);
    w.addRock(x: w.cartX, y: 150, size: 1, value: 2);
    w.setFiring(true);
    run(w, 6);
    expect(w.phase, BarragePhase.won);
    expect(w.rocks, isEmpty);
    expect(w.coins, isEmpty);
    expect(w.splits, 1);
    expect(w.pops, 2);
    expect(w.damageDealt, BarrageWorld.treeHp(1, 2));
    expect(w.coinsRun, 3);
    expect(w.score, w.damageDealt + w.coinsRun);
    expect(w.firing, isFalse);
  });

  test('driving over a coin collects it', () {
    final w = BarrageWorld(seed: 6, rocks: [], upgrades: BarrageUpgrades(coinValue: 2));
    // A harmless rock bouncing in place on the far right keeps the level going.
    w.addRock(x: 340, y: 300, size: 0, value: 9);
    w.setCartTarget(60);
    w.coins.add(BarrageCoin(250, BarrageWorld.floorY - BarrageWorld.coinRadius, 3)..landed = true);
    run(w, 0.5);
    expect(w.coins, hasLength(1), reason: 'cart has not reached it yet');
    expect(w.coinsRun, 0);
    w.setCartTarget(250);
    run(w, 0.5);
    expect(w.coins, isEmpty);
    expect(w.coinsRun, 3);
    expect(w.isOver, isFalse);
    // Coins left lying around eventually fade.
    w.coins.add(BarrageCoin(120, BarrageWorld.floorY - BarrageWorld.coinRadius, 1)..landed = true);
    run(w, BarrageWorld.coinLife + 0.5);
    expect(w.coins, isEmpty);
    expect(w.coinsRun, 3);
  });

  test('shop: buying upgrades costs coins, changes stats and only works in the shop', () {
    final w = BarrageWorld(seed: 7, wallet: 25);
    expect(w.phase, BarragePhase.shop);
    expect(w.upgrades.damage, 1);
    expect(w.buy(UpgradeKind.damage), isTrue);
    expect(w.wallet, 25 - BarrageUpgrades.costForLevel(0));
    expect(w.upgrades.damage, 2);
    expect(w.buy(UpgradeKind.damage), isTrue);
    expect(w.upgrades.damage, 3);
    expect(w.wallet, 25 - 6 - 15);
    expect(w.canBuy(UpgradeKind.fireRate), isFalse);
    expect(w.buy(UpgradeKind.fireRate), isFalse, reason: 'too poor');
    w.start();
    w.wallet = 999;
    expect(w.buy(UpgradeKind.coinValue), isFalse, reason: 'shop closed during play');
    expect(BarrageUpgrades(coinValue: 3).coinValue, 4);
    final maxed = BarrageUpgrades(fireRate: BarrageUpgrades.maxLevel);
    expect(maxed.isMaxed(UpgradeKind.fireRate), isTrue);

    // Fire rate upgrades put more bullets in the air.
    int shotsIn(BarrageUpgrades u) {
      final s = BarrageWorld(seed: 1, rocks: [], upgrades: u);
      s.addRock(x: 20, y: 40, size: 0, value: 999, vx: 0);
      s.setCartTarget(300);
      s.setFiring(true);
      var shots = 0;
      for (var i = 0; i < 120; i++) {
        s.update(1 / 120);
        shots += s.events.where((e) => e.kind == BarrageEventKind.shot).length;
      }
      return shots;
    }

    expect(shotsIn(BarrageUpgrades(fireRate: 4)), greaterThan(shotsIn(BarrageUpgrades()) + 4));
  });

  test('upgrades, coins and level persist through the save and a JSON round trip', () {
    final save = CartridgeSave()
      ..data['coins'] = 40
      ..data['level'] = 3;
    var commits = 0;
    late DigitBarrageGame game;
    final session = FlameCartridgeSession<DigitBarrageGame>(
      ctxFor(save, onSave: () => commits++),
      (s) => game = DigitBarrageGame(s, seed: 9),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    expect(game.level, 3);
    expect(game.barrage.wallet, 40);
    final tapAt = game.upgradeRect(UpgradeKind.fireRate.index).center;
    game.onPointerDown(Vector2(tapAt.dx, tapAt.dy));
    game.onPointerUp(Vector2(tapAt.dx, tapAt.dy));
    final dmgAt = game.upgradeRect(UpgradeKind.damage.index).center;
    game.onPointerDown(Vector2(dmgAt.dx, dmgAt.dy));
    expect(commits, 2);
    expect(save.intData('coins'), 40 - 6 - 6);

    final restored = CartridgeSave.fromJsonString(jsonEncode(save.toJson()));
    final u = BarrageUpgrades.fromJson(restored.data['upgrades']);
    expect(u.level(UpgradeKind.fireRate), 1);
    expect(u.level(UpgradeKind.damage), 1);
    expect(u.level(UpgradeKind.coinValue), 0);
    expect(restored.intData('coins'), 28);
    expect(BarrageUpgrades.fromJson('garbage').damage, 1);

    late DigitBarrageGame again;
    FlameCartridgeSession<DigitBarrageGame>(
      ctxFor(restored),
      (s) => again = DigitBarrageGame(s, seed: 9),
    ).start();
    expect(again.barrage.upgrades.damage, 2);
    expect(again.barrage.upgrades.shotsPerSecond, game.barrage.upgrades.shotsPerSecond);
    expect(again.level, 3);
  });

  test('level HP budget, rock count and rock size grow with the level', () {
    for (var level = 1; level < 20; level++) {
      expect(BarrageWorld.hpBudget(level + 1), greaterThan(BarrageWorld.hpBudget(level)));
      expect(BarrageWorld.rockCountFor(level + 1), greaterThanOrEqualTo(BarrageWorld.rockCountFor(level)));
      expect(BarrageWorld.maxSizeFor(level + 1), greaterThanOrEqualTo(BarrageWorld.maxSizeFor(level)));
      for (var seed = 0; seed < 4; seed++) {
        final w = BarrageWorld(seed: seed, level: level);
        expect(w.pendingCount, BarrageWorld.rockCountFor(level));
        expect(w.levelHp, w.remainingHp);
        final budget = BarrageWorld.hpBudget(level);
        expect((w.levelHp - budget).abs(), lessThanOrEqualTo(budget * 0.3 + 6), reason: 'L$level s$seed');
      }
    }
    expect(
      BarrageWorld(seed: 0, level: 10).levelHp,
      greaterThan(BarrageWorld(seed: 0, level: 1).levelHp * 5),
    );
    expect(BarrageWorld.rockCountFor(8), greaterThan(BarrageWorld.rockCountFor(1)));
  });

  test('same seed and inputs give the same run; different seeds differ', () {
    final a = BarrageWorld(seed: 42, level: 3);
    final b = BarrageWorld(seed: 42, level: 3);
    bot(a, maxTime: 20);
    bot(b, maxTime: 20);
    expect(a.snapshot(), b.snapshot());
    expect(a.score, b.score);
    final c = BarrageWorld(seed: 43, level: 3);
    bot(c, maxTime: 20);
    expect(c.snapshot(), isNot(a.snapshot()));
  });

  test('a scripted bot clears level 1 on most seeds while an idle player is crushed', () {
    var wins = 0;
    var idleLosses = 0;
    for (var seed = 0; seed < 20; seed++) {
      final w = BarrageWorld(seed: seed, level: 1);
      if (bot(w)) wins++;
      final idle = BarrageWorld(seed: seed, level: 1);
      idle.start();
      run(idle, 90);
      if (idle.phase == BarragePhase.lost) idleLosses++;
    }
    expect(wins, greaterThanOrEqualTo(17));
    expect(idleLosses, 20);
  });

  test('game finishes once, banks coins and unlocks the next level on a win', () {
    final save = CartridgeSave()
      ..data['coins'] = 5
      ..data['level'] = 2;
    var commits = 0;
    late DigitBarrageGame game;
    final session = FlameCartridgeSession<DigitBarrageGame>(
      ctxFor(save, onSave: () => commits++),
      (s) => game = DigitBarrageGame(s, seed: 3),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    final start = game.startRect.center;
    game.onPointerDown(Vector2(start.dx, start.dy));
    expect(game.barrage.phase, BarragePhase.playing);
    expect(bot(game.barrage), isTrue);
    final coins = game.barrage.coinsRun;
    expect(coins, greaterThan(0));
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, game.barrage.score);
    expect(save.intData('level'), 3);
    expect(save.intData('coins'), 5 + coins);
    expect(commits, 1);
  });

  test('renderer smoke: shop, hold-to-fire and drag-to-steer render without errors', () {
    late DigitBarrageGame game;
    final session = FlameCartridgeSession<DigitBarrageGame>(
      ctxFor(CartridgeSave()..data['coins'] = 12),
      (s) => game = DigitBarrageGame(s, seed: 8),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    expect(game.barrage.phase, BarragePhase.shop);
    final start = game.startRect.center;
    game.onPointerDown(Vector2(start.dx, start.dy));
    game.onPointerUp(Vector2(start.dx, start.dy));
    expect(game.barrage.phase, BarragePhase.playing);
    paint();
    final x0 = game.barrage.cartX;
    game.onPointerDown(Vector2(200, 600));
    expect(game.barrage.firing, isTrue);
    game.onPointerMove(Vector2(260, 600), Vector2(60, 0));
    for (var i = 0; i < 90; i++) {
      game.update(1 / 60);
    }
    expect(game.barrage.cartX, greaterThan(x0 + 20));
    expect(game.barrage.bullets, isNotEmpty);
    paint();
    game.onPointerUp(Vector2(260, 600));
    expect(game.barrage.firing, isFalse);
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
  });
}
