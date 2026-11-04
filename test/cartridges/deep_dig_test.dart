import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/deep_dig/deep_dig.dart';
import 'package:yantrasobi/cartridges/deep_dig/dig_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/cartridge/manifest.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const int lift = DigWorld.elevatorId;
const int hauler = DigWorld.haulerId;

void runFor(DigWorld w, double seconds, {double dt = 0.05}) {
  for (var t = 0.0; t < seconds - 1e-9; t += dt) {
    w.update(dt);
  }
}

/// A world with every station automated (money is granted, then removed).
DigWorld automated() {
  final w = DigWorld()..cash = 1e6;
  for (final id in [0, lift, hauler]) {
    expect(w.hireManager(id), isTrue);
  }
  w.cash = 0;
  return w;
}

/// Simple greedy player: taps idle stations, hires foremen, upgrades the bottleneck.
void botStep(DigWorld w) {
  for (var i = 0; i < w.shaftCount; i++) {
    w.tapStation(i);
  }
  w.tapStation(lift);
  w.tapStation(hauler);
  for (final id in [lift, hauler, for (var i = 0; i < w.shaftCount; i++) i]) {
    if (!w.managerOf(id) && w.managerCost(id) <= w.cash * 0.8) w.hireManager(id);
  }
  final s = w.totalShaftRate, e = w.elevatorThroughput, h = w.haulerThroughput;
  final m = math.min(s, math.min(e, h));
  if (m == e) {
    w.upgrade(lift);
    return;
  }
  if (m == h) {
    w.upgrade(hauler);
    return;
  }
  var best = -1;
  var bestV = 0.0;
  for (var i = 0; i < w.shaftCount; i++) {
    final v = (DigWorld.shaftRateAt(i, w.levelOf(i) + 1) - w.shaftRate(i)) / w.upgradeCost(i);
    if (v > bestV) {
      bestV = v;
      best = i;
    }
  }
  final unlockV = w.canDigDeeper
      ? DigWorld.shaftRateAt(w.shaftCount, 1) / (w.unlockCost + w.managerCost(w.shaftCount))
      : 0;
  if (unlockV > bestV) {
    w.unlockShaft();
  } else if (best >= 0) {
    w.upgrade(best);
  }
}

CartridgeContext makeContext(CartridgeSave save, {void Function()? onSave}) => CartridgeContext(
  manifest: DeepDigCartridge.kManifest,
  save: save,
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    const m = DeepDigCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'deep-dig');
    expect(m.version, '1.0.0');
    expect(m.engine, CartridgeEngine.flame2d);
    expect(m.matchesQuery('idle mining'), isTrue);
    expect(const DeepDigCartridge().manifest, same(m));
  });

  test('shaft production accumulates in its crate up to storage', () {
    final w = DigWorld()..cash = 1e6;
    w.hireManager(0);
    expect(w.shaftRate(0), 1);
    expect(w.shaftStorage(0), 20);
    runFor(w, 5);
    expect(w.shafts[0].crate, closeTo(5, 1e-6));
    runFor(w, 60);
    expect(w.shafts[0].crate, closeTo(w.shaftStorage(0), 1e-9));
    // Nothing moves the ore without the lift working.
    expect(w.surfaceStock, 0);
  });

  test('tap to work runs exactly one cycle per tap without a manager', () {
    final w = DigWorld();
    expect(w.tapStation(0), isTrue);
    expect(w.tapStation(0), isFalse, reason: 'already busy');
    runFor(w, 10);
    expect(w.isWorking(0), isFalse);
    expect(w.shafts[0].crate, closeTo(DigWorld.shaftCycleTime * w.shaftRate(0), 1e-6));
    runFor(w, 10);
    expect(w.shafts[0].crate, closeTo(3, 1e-6), reason: 'idle without a tap');
    expect(w.tapStation(0), isTrue);
    runFor(w, 10);
    expect(w.shafts[0].crate, closeTo(6, 1e-6));
    // Nothing to lift or haul -> taps are refused.
    final empty = DigWorld();
    expect(empty.tapStation(lift), isFalse);
    expect(empty.tapStation(hauler), isFalse);
    expect(empty.tapStation(7), isFalse);
  });

  test('the lift moves ore to the surface, limited by its capacity, top shaft first', () {
    final w = DigWorld();
    w.shafts[0].crate = 18;
    expect(w.elevatorCapacity, 10);
    expect(w.tapStation(lift), isTrue);
    expect(w.tapStation(lift), isFalse);
    runFor(w, 3);
    expect(w.isWorking(lift), isFalse);
    expect(w.surfaceStock, closeTo(10, 1e-9));
    expect(w.shafts[0].crate, closeTo(8, 1e-9));
    expect(w.elevatorTrips, 1);

    final deep = DigWorld()..cash = 1e4;
    expect(deep.unlockShaft(), isTrue);
    deep.shafts[0].crate = 6;
    deep.shafts[1].crate = 9;
    deep.tapStation(lift);
    runFor(deep, 4);
    expect(deep.surfaceStock, closeTo(10, 1e-9));
    expect(deep.shafts[0].crate, closeTo(0, 1e-9));
    expect(deep.shafts[1].crate, closeTo(5, 1e-9));
  });

  test('the hauler sells surface ore for cash at the warehouse', () {
    final w = DigWorld()..surfaceStock = 25;
    final cash = w.cash;
    expect(w.tapStation(hauler), isTrue);
    expect(w.surfaceStock, closeTo(15, 1e-9));
    runFor(w, 2.1);
    expect(w.cash, closeTo(cash + 10, 1e-9));
    expect(w.contractEarned, closeTo(10, 1e-9));
    expect(w.sales, 1);
    expect(w.tapStation(hauler), isFalse, reason: 'still walking back');
    runFor(w, 2.1);
    expect(w.isWorking(hauler), isFalse);
    expect(w.tapStation(hauler), isTrue);
  });

  test('foremen automate the whole chain without any taps', () {
    final w = automated();
    expect(w.idleIncomePerSecond, closeTo(1, 1e-9));
    runFor(w, 120);
    expect(w.cash, greaterThan(90));
    expect(w.cash, lessThanOrEqualTo(120));
    expect(w.incomePerSecond, greaterThan(0.5));
    expect(w.sales, greaterThan(10));
    // A second hire is refused and costs nothing.
    final before = w.cash;
    expect(w.hireManager(0), isFalse);
    expect(w.cash, before);
    // Hiring needs cash.
    final broke = DigWorld();
    expect(broke.hireManager(lift), isFalse);
    expect(broke.managerOf(lift), isFalse);
  });

  test('upgrade costs grow by 1.15x per level and raise output', () {
    final w = DigWorld()..cash = 1e6;
    final c1 = w.upgradeCost(0);
    expect(c1, closeTo(10, 1e-9));
    final rate = w.shaftRate(0);
    expect(w.upgrade(0), 1);
    expect(w.cash, closeTo(1e6 - c1, 1e-6));
    expect(w.levelOf(0), 2);
    expect(w.upgradeCost(0), closeTo(c1 * 1.15, 1e-9));
    expect(w.shaftRate(0), greaterThan(rate));
    // x10 costs the geometric series.
    final ten = w.upgradeCost(0, 10);
    var sum = 0.0;
    for (var k = 0; k < 10; k++) {
      sum += w.upgradeCost(0) * math.pow(1.15, k);
    }
    expect(ten, closeTo(sum, 1e-6));
    // Max buys exactly what cash allows.
    final n = w.affordableLevels(lift);
    expect(w.upgradeCost(lift, n), lessThanOrEqualTo(w.cash));
    expect(w.upgradeCost(lift, n + 1), greaterThan(w.cash));
    final cap = w.elevatorCapacity;
    final speed = w.elevatorSpeed;
    expect(w.upgrade(lift, n), n);
    expect(w.elevatorCapacity, greaterThan(cap));
    expect(w.elevatorSpeed, greaterThan(speed));
    // Unaffordable upgrades do nothing.
    final cash = w.cash;
    expect(w.upgrade(hauler, 500), 0);
    expect(w.cash, cash);
    expect(w.upgrade(42), 0);
    // Milestone doubling every 25 levels.
    expect(DigWorld.shaftRateAt(0, 25), 50);
  });

  test('new shafts cost more each time and raise the mine output', () {
    final w = DigWorld();
    expect(w.unlockShaft(), isFalse);
    w.cash = 1e12;
    final costs = <double>[];
    final rate = w.totalShaftRate;
    while (w.canDigDeeper) {
      costs.add(w.unlockCost);
      final cash = w.cash;
      expect(w.unlockShaft(), isTrue);
      expect(w.cash, closeTo(cash - costs.last, 1e-3));
      if (w.cash < w.unlockCost) w.cash = w.unlockCost * 2;
    }
    expect(w.shaftCount, DigWorld.maxShafts);
    for (var i = 1; i < costs.length; i++) {
      expect(costs[i], greaterThan(costs[i - 1]));
    }
    expect(costs.first, 500);
    expect(w.totalShaftRate, greaterThan(rate * 1000));
    expect(DigWorld.shaftRateAt(1, 1), greaterThan(DigWorld.shaftRateAt(0, 1)));
    expect(w.unlockShaft(), isFalse);
    expect(w.unlockCost, double.infinity);
  });

  test('save round-trip keeps the full state and stays deterministic', () {
    final w = DigWorld()..cash = 5e4;
    w.unlockShaft();
    w.upgrade(0, 7);
    w.upgrade(hauler, 3);
    w.hireManager(lift);
    w.hireManager(1);
    w.tapStation(0);
    w.shafts[0].crate = 12.5;
    runFor(w, 2.3);
    w.surfaceStock = 33;
    w.tapStation(hauler);
    runFor(w, 0.7);
    final json = jsonDecode(jsonEncode(w.toJson())) as Map<String, dynamic>;
    final copy = DigWorld.fromJson(json);
    expect(jsonEncode(copy.toJson()), jsonEncode(w.toJson()));
    expect(copy.shaftCount, 2);
    expect(copy.levelOf(0), 8);
    expect(copy.managerOf(lift), isTrue);
    expect(copy.managerOf(1), isTrue);
    runFor(w, 30);
    runFor(copy, 30);
    expect(jsonEncode(copy.toJson()), jsonEncode(w.toJson()));
    // Corrupt payloads fall back to a fresh mine.
    expect(DigWorld.fromJson({'shafts': 'nope', 'cash': 'x'}).cash, DigWorld.startCash);
    expect(DigWorld.fromJson(null).shaftCount, 1);
    expect(DigWorld.fromJson({'contract': 3}).contractTarget, 1e8);
  });

  test('offline earnings come only from automated stations and are capped at 2 hours', () {
    final w = automated();
    // Bottleneck at level 1: the shaft (1 ore/s) vs lift 7.5/s and hauler 2.5/s.
    final r = w.applyOffline(const Duration(hours: 1));
    expect(r.seconds, 3600);
    expect(r.capped, isFalse);
    expect(r.cash, closeTo(3600, 1e-6));
    expect(w.cash, closeTo(3600, 1e-6));
    expect(w.contractEarned, closeTo(3600, 1e-6));

    final a = automated();
    final b = automated();
    final ra = a.applyOffline(const Duration(hours: 2));
    final rb = b.applyOffline(const Duration(hours: 9));
    expect(rb.capped, isTrue);
    expect(rb.seconds, 7200);
    expect(rb.cash, closeTo(ra.cash, 1e-6));

    final idle = DigWorld();
    idle.shafts[0].crate = 5;
    idle.surfaceStock = 3;
    final ri = idle.applyOffline(const Duration(hours: 1));
    expect(ri.cash, 0);
    expect(idle.cash, DigWorld.startCash);
    expect(idle.shafts[0].crate, 5);
    expect(idle.surfaceStock, 3);

    // Shaft + lift automated, hauler not: ore piles up at the surface, no cash.
    final half = DigWorld()..cash = 1e6;
    half
      ..hireManager(0)
      ..hireManager(lift)
      ..cash = 0;
    final rh = half.applyOffline(const Duration(minutes: 10));
    expect(rh.cash, 0);
    expect(half.surfaceStock, closeTo(600, 1e-6));
    expect(half.applyOffline(Duration.zero).seconds, 0);
  });

  test('reaching the contract milestone wins; score is the cash earned', () {
    final w = DigWorld();
    expect(w.contractTarget, 1e6);
    expect(w.isOver, isFalse);
    w.contractEarned = 1e6 - 5;
    w.surfaceStock = 10;
    w.tapStation(hauler);
    runFor(w, 2.1);
    expect(w.won, isTrue);
    expect(w.isOver, isTrue);
    expect(w.score, 1000005);
    expect(w.contractProgress, 1);
    w.advanceContract();
    expect(w.contract, 2);
    expect(w.contractTarget, 1e7);
    expect(w.won, isFalse);
    expect(w.score, 0);
    expect(w.totalEarned, closeTo(10, 1e-9));
  });

  test('a greedy player fulfils contract 1 in a sensible amount of time', () {
    final w = DigWorld();
    var t = 0.0;
    var next = 0.0;
    while (!w.won && t < 3600) {
      w.update(0.1);
      t += 0.1;
      if (t >= next) {
        next = t + 0.5;
        botStep(w);
      }
    }
    expect(w.won, isTrue);
    // Neither instant nor endless: between 8 and 40 minutes of perfect play.
    expect(t, greaterThan(8 * 60));
    expect(t, lessThan(40 * 60));
    expect(w.shaftCount, greaterThanOrEqualTo(2));
    expect(w.idleIncomePerSecond, greaterThan(0));
  });

  test('short-number formatting', () {
    expect(shortNumber(0), '0');
    expect(shortNumber(0.7), '0');
    expect(shortNumber(999), '999');
    expect(shortNumber(1000), '1K');
    expect(shortNumber(1500), '1.5K');
    expect(shortNumber(1234), '1.23K');
    expect(shortNumber(1150), '1.15K');
    expect(shortNumber(12345), '12.3K');
    expect(shortNumber(123456), '123K');
    expect(shortNumber(999999), '999K');
    expect(shortNumber(1e6), '1M');
    expect(shortNumber(2.5e9), '2.5B');
    expect(shortNumber(1e12), '1T');
    expect(shortNumber(-1500), '-1.5K');
    expect(shortNumber(1e40), contains('e'));
    expect(formatCash(1234567), r'$1.23M');
    expect(formatCash(-20), r'-$20');
  });

  test('game grants offline earnings from the save, autosaves and finishes on the contract', () {
    final now = DateTime(2026, 5, 1, 12);
    final saved = automated();
    final save = CartridgeSave()
      ..data['state'] = jsonDecode(
        jsonEncode({
          ...saved.toJson(),
          'savedAt': now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        }),
      );
    var commits = 0;
    late DeepDigGame game;
    final session = FlameCartridgeSession<DeepDigGame>(
      makeContext(save, onSave: () => commits++),
      (s) => game = DeepDigGame(s, clock: () => now),
    );
    session.start();
    expect(game.showingWelcome, isTrue);
    expect(game.welcome!.cash, closeTo(3600, 1e-6));
    expect(game.mine.cash, closeTo(3600, 1e-6));
    expect(commits, 1, reason: 'offline grant is saved right away');
    final state = save.data['state'] as Map;
    expect(state['savedAt'], now.millisecondsSinceEpoch);
    expect(jsonDecode(jsonEncode(save.data)), isA<Map<String, dynamic>>());

    game.onGameResize(Vector2(400, 800));
    game.onPointerDown(Vector2(200, 400));
    game.onPointerUp(Vector2(200, 400));
    expect(game.showingWelcome, isFalse);

    for (var i = 0; i < 60 * 11; i++) {
      game.update(1 / 60);
    }
    expect(commits, 2, reason: 'periodic autosave');
    expect(session.state, SessionState.running);

    game.mine.contractEarned = game.mine.contractTarget - 1;
    for (var i = 0; i < 60 * 10 && session.state != SessionState.ended; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, greaterThanOrEqualTo(1000000));
    final after = DigWorld.fromJson(Map<String, Object?>.from(save.data['state'] as Map));
    expect(after.contract, 2);
    expect(after.contractEarned, 0);
    expect(after.managerOf(lift), isTrue);
    final ended = commits;
    for (var i = 0; i < 60; i++) {
      game.update(1 / 60);
    }
    expect(commits, ended);

    // A fresh save shows no banner and starts a new mine.
    late DeepDigGame fresh;
    FlameCartridgeSession<DeepDigGame>(
      makeContext(CartridgeSave()),
      (s) => fresh = DeepDigGame(s, clock: () => now),
    ).start();
    expect(fresh.showingWelcome, isFalse);
    expect(fresh.mine.cash, DigWorld.startCash);
  });

  test('renderer smoke: on-screen taps, buttons, buy toggle, scrolling and pause-save', () {
    var commits = 0;
    final save = CartridgeSave();
    late DeepDigGame game;
    final session = FlameCartridgeSession<DeepDigGame>(
      makeContext(save, onSave: () => commits++),
      (s) => game = DeepDigGame(s, clock: () => DateTime(2026, 5, 1)),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    void tap(Offset p) {
      game.onPointerDown(Vector2(p.dx, p.dy));
      game.onPointerUp(Vector2(p.dx, p.dy));
    }

    paint();
    final m = game.mine;
    tap(game.stationRect(0).center);
    expect(m.isWorking(0), isTrue);
    for (var i = 0; i < 60 * 4; i++) {
      game.update(1 / 60);
    }
    expect(m.shafts[0].crate, greaterThan(2));
    tap(Offset(34, game.viewTop + 40));
    expect(m.isWorking(lift), isTrue);
    for (var i = 0; i < 60 * 3; i++) {
      game.update(1 / 60);
    }
    expect(m.surfaceStock, greaterThan(2));
    tap(game.stationRect(hauler).center);
    expect(m.isWorking(hauler), isTrue);
    for (var i = 0; i < 60 * 5; i++) {
      game.update(1 / 60);
      if (i % 20 == 0) paint();
    }
    expect(m.sales, 1);
    final audio = session.context.audio as SilentAudio;
    expect(audio.played, containsAll([Sfx.tap, Sfx.coin]));

    // Buy toggle + upgrade + hire.
    tap(game.buyToggleRect(BuyMode.x10).center);
    expect(game.buyMode, BuyMode.x10);
    m.cash = 1e9;
    tap(game.upgradeButtonRect(0).center);
    expect(m.levelOf(0), 11);
    tap(game.upgradeButtonRect(hauler).center);
    expect(m.levelOf(hauler), 11);
    tap(game.managerButtonRect(0).center);
    expect(m.managerOf(0), isTrue);
    tap(game.managerButtonRect(lift).center);
    expect(m.managerOf(lift), isTrue);
    tap(game.buyToggleRect(BuyMode.max).center);
    tap(game.upgradeButtonRect(lift).center);
    expect(m.levelOf(lift), greaterThan(50));
    expect(audio.played, containsAll([Sfx.powerup, Sfx.merge]));

    // Dig deeper until the mine no longer fits, then drag to scroll.
    for (var k = 0; k < 3; k++) {
      m.cash = 1e12;
      game.scroll = game.maxScroll;
      tap(game.unlockButtonRect.center);
    }
    expect(m.shaftCount, 4);
    expect(game.maxScroll, greaterThan(0));
    game.scroll = 0;
    final start = Vector2(200, game.viewTop + 200);
    game.onPointerDown(start);
    for (var k = 1; k <= 10; k++) {
      game.onPointerMove(start - Vector2(0, 15.0 * k), Vector2(0, -15));
    }
    game.onPointerUp(start - Vector2(0, 150));
    expect(game.scroll, greaterThan(100));
    expect(m.levelOf(0), 11, reason: 'a drag is not a tap');
    for (var i = 0; i < 60; i++) {
      game.update(1 / 60);
    }
    paint();
    // The deepest shaft's buttons are reachable after scrolling.
    game.scroll = game.maxScroll;
    m.cash = 1e12;
    tap(game.managerButtonRect(3).center);
    expect(m.managerOf(3), isTrue);
    paint();

    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
    final before = commits;
    session.pause();
    expect(commits, before + 1);
    expect(DigWorld.fromJson(Map<String, Object?>.from(save.data['state'] as Map)).shaftCount, 4);
    session.resume();
    expect(session.state, SessionState.running);
    session.dispose();
  });
}
