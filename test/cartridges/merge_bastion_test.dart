import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/merge_bastion/bastion_world.dart';
import 'package:yantrasobi/cartridges/merge_bastion/merge_bastion.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double tick = 1 / 30;

/// Merges every identical pair (lowest tier first), then summons while affordable.
void botStep(BastionWorld w) {
  var merged = true;
  while (merged) {
    merged = false;
    for (var t = 1; t < BastionWorld.maxTier && !merged; t++) {
      final cells = [
        for (var i = 0; i < BastionWorld.cellCount; i++)
          if (w.grid[i]?.tier == t) i,
      ];
      if (cells.length >= 2) {
        expect(w.dragUnit(cells[1], cells[0]), DragOutcome.merged);
        merged = true;
      }
    }
  }
  while (w.summon() != null) {}
}

BastionWorld play(int seed, {int level = 1, bool idle = false, List<String>? trace}) {
  final w = BastionWorld(seed: seed, level: level);
  var steps = 0;
  while (!w.isOver && steps < 60 * 60 * 30) {
    if (!idle) botStep(w);
    w.update(tick);
    steps++;
    if (trace != null && steps % 300 == 0) trace.add(w.debugSnapshot());
  }
  return w;
}

void runFor(BastionWorld w, double seconds) {
  for (var t = 0.0; t < seconds; t += tick) {
    w.update(tick);
  }
}

CartridgeContext makeContext(CartridgeSave save, {void Function()? onSave}) => CartridgeContext(
  manifest: MergeBastionCartridge.kManifest,
  save: save,
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    expect(MergeBastionCartridge.kManifest.validate(), isEmpty);
    expect(MergeBastionCartridge.kManifest.id, 'merge-bastion');
    expect(MergeBastionCartridge.kManifest.version, '1.0.0');
  });

  test('summon costs coins, places a tier-1 unit and raises the cost', () {
    final w = BastionWorld(seed: 1);
    final coins = w.coins;
    final cost = w.summonCost;
    final cell = w.summon();
    expect(cell, isNotNull);
    expect(w.unitAt(cell!)!.tier, 1);
    expect(w.coins, coins - cost);
    expect(w.summonCost, cost + BastionWorld.summonCostStep);
    expect(w.unitCount, 1);
  });

  test('summon fails without coins or with a full grid', () {
    final w = BastionWorld(seed: 2);
    w.coins = w.summonCost - 1;
    expect(w.canSummon, isFalse);
    expect(w.summon(), isNull);
    expect(w.unitCount, 0);

    final full = BastionWorld(seed: 2);
    for (var i = 0; i < BastionWorld.cellCount; i++) {
      full.debugSetUnit(i, 1 + i % 3);
    }
    full.coins = 9999;
    expect(full.hasEmptyCell, isFalse);
    expect(full.summon(), isNull);
    expect(full.coins, 9999);
  });

  test('dragging onto an identical tier merges into tier+1 (capped at max tier)', () {
    final w = BastionWorld(seed: 3);
    w.debugSetUnit(0, 2);
    w.debugSetUnit(7, 2);
    expect(w.dragUnit(7, 0), DragOutcome.merged);
    expect(w.unitAt(0)!.tier, 3);
    expect(w.unitAt(7), isNull);
    expect(w.merges, 1);
    expect(BastionWorld.damageForTier(3), 12);
    expect(BastionWorld.fireIntervalForTier(3), lessThan(BastionWorld.fireIntervalForTier(1)));

    w.debugSetUnit(1, BastionWorld.maxTier);
    w.debugSetUnit(2, BastionWorld.maxTier);
    expect(w.dragUnit(1, 2), DragOutcome.invalid);
    expect(w.unitAt(2)!.tier, BastionWorld.maxTier);
    expect(w.unitAt(1)!.tier, BastionWorld.maxTier);
  });

  test('different tiers swap; empty cells take a move; bad drags are invalid', () {
    final w = BastionWorld(seed: 4);
    w.debugSetUnit(0, 1);
    w.debugSetUnit(1, 3);
    final a = w.unitAt(0)!, b = w.unitAt(1)!;
    expect(w.dragUnit(0, 1), DragOutcome.swapped);
    expect(w.unitAt(0), same(b));
    expect(w.unitAt(1), same(a));

    expect(w.dragUnit(1, 14), DragOutcome.moved);
    expect(w.unitAt(14), same(a));
    expect(w.unitAt(1), isNull);

    expect(w.dragUnit(5, 6), DragOutcome.invalid, reason: 'nothing to drag');
    expect(w.dragUnit(0, 0), DragOutcome.invalid);
    expect(w.dragUnit(0, BastionWorld.cellCount), DragOutcome.invalid);
    expect(w.merges, 0);
  });

  test('units shoot enemies in range, kills pay coins and score', () {
    final w = BastionWorld(seed: 5);
    w.debugSetUnit(BastionWorld.cellIndex(2, 0), 2);
    final e = w.debugSpawnEnemy(x: 2.5, y: 3, hp: 12, speed: 0, coins: 7);
    final coins = w.coins;
    runFor(w, 3);
    expect(e.alive, isFalse);
    expect(w.kills, 1);
    expect(w.coins, greaterThanOrEqualTo(coins + 7));
    expect(w.score, greaterThan(0));

    // An enemy beyond range is ignored.
    final far = BastionWorld(seed: 5);
    far.debugSetUnit(BastionWorld.cellIndex(2, 2), 8);
    final out = far.debugSpawnEnemy(x: 2.5, y: 0.2, hp: 1, speed: 0);
    runFor(far, 1);
    expect(out.alive, isTrue);
  });

  test('enemies reaching the wall damage it; wall at 0 loses and freezes the run', () {
    final w = BastionWorld(seed: 6);
    w.debugSpawnEnemy(y: BastionWorld.wallY - 0.5, speed: 2, wallDamage: 30);
    runFor(w, 1);
    expect(w.wallHp, BastionWorld.maxWallHp - 30);
    expect(w.isOver, isFalse);
    w.debugSpawnEnemy(y: BastionWorld.wallY - 0.5, speed: 2, wallDamage: 999);
    runFor(w, 1);
    expect(w.wallHp, 0);
    expect(w.phase, BastionPhase.lost);
    expect(w.isOver, isTrue);
    expect(w.summon(), isNull);
    final t = w.time;
    runFor(w, 1);
    expect(w.time, t);
  });

  test('waves scale, boss every fifth wave, 3 s break between waves', () {
    expect(BastionWorld.isBossWave(5), isTrue);
    expect(BastionWorld.isBossWave(15), isTrue);
    expect(BastionWorld.isBossWave(4), isFalse);
    final w = BastionWorld(seed: 7);
    expect(w.hpForWave(10), greaterThan(w.hpForWave(1) * 4));
    expect(BastionWorld.waveSize(4), greaterThan(BastionWorld.waveSize(1)));
    expect(BastionWorld.waveSize(4, 5), greaterThan(BastionWorld.waveSize(4, 1)));
    expect(BastionWorld(seed: 7, level: 3).hpForWave(5), greaterThan(w.hpForWave(5)));

    w.debugSkipToWave(5);
    w.debugSetUnit(0, 8);
    w.debugSetUnit(1, 8);
    w.debugSetUnit(2, 8);
    var sawBoss = false;
    while (w.phase != BastionPhase.breakTime || w.wave < 5) {
      w.update(tick);
      sawBoss |= w.enemies.any((e) => e.kind == EnemyKind.boss);
    }
    expect(sawBoss, isTrue);
    expect(w.bossKills, 1);
    expect(w.breakTimer, closeTo(BastionWorld.breakDuration, 0.05));
    runFor(w, BastionWorld.breakDuration + 0.1);
    expect(w.wave, 6);
    expect(w.phase, BastionPhase.fighting);
  });

  test('clearing the final wave wins with a wave bonus in the score', () {
    final w = BastionWorld(seed: 8);
    w.debugSkipToWave(w.finalWave);
    for (var i = 0; i < 5; i++) {
      w.debugSetUnit(i, 8);
    }
    for (var i = 0; i < 60 * 30 && !w.isOver; i++) {
      w.update(tick);
    }
    expect(w.won, isTrue);
    expect(w.phase, BastionPhase.won);
    expect(w.wavesCleared, w.finalWave);
    expect(w.score, greaterThanOrEqualTo(w.finalWave * 100 + w.wallHp * 5));
  });

  test('same seed and inputs replay identically; different seeds differ', () {
    final a = <String>[], b = <String>[], c = <String>[];
    final wa = play(42, trace: a);
    final wb = play(42, trace: b);
    play(43, trace: c);
    expect(a, b);
    expect(wa.score, wb.score);
    expect(wa.time, wb.time);
    expect(c, isNot(a));
  });

  test('a summon-and-merge bot wins level 1; an idle player loses early', () {
    for (var seed = 0; seed < 6; seed++) {
      final w = play(seed);
      expect(w.won, isTrue, reason: 'seed $seed (wave ${w.wave}, wall ${w.wallHp})');
      expect(w.merges, greaterThan(10));
    }
    for (var seed = 0; seed < 3; seed++) {
      final idle = play(seed, idle: true);
      expect(idle.won, isFalse);
      expect(idle.wave, lessThanOrEqualTo(3));
    }
    // Higher levels are genuinely harder for the same bot.
    var wins = 0;
    for (var seed = 0; seed < 6; seed++) {
      if (play(seed, level: 6).won) wins++;
    }
    expect(wins, lessThan(6));
  });

  test('game reads the saved level, finishes once and unlocks the next level on a win', () {
    final save = CartridgeSave()..data['level'] = 2;
    var commits = 0;
    late MergeBastionGame game;
    final session = FlameCartridgeSession<MergeBastionGame>(
      makeContext(save, onSave: () => commits++),
      (s) => game = MergeBastionGame(s, seed: 3),
    );
    session.start();
    expect(game.level, 2);
    expect(game.bastion.level, 2);
    game.bastion.debugSkipToWave(game.bastion.finalWave);
    for (var i = 0; i < 5; i++) {
      game.bastion.debugSetUnit(i, 8);
    }
    for (var i = 0; i < 60 * 70 && session.state != SessionState.ended; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, game.bastion.score);
    expect(save.data['level'], 3);
    expect(commits, 1);
    for (var i = 0; i < 60; i++) {
      game.update(1 / 60);
    }
    expect(commits, 1);
  });

  test('renderer smoke: on-screen summon + drag-to-merge, render without errors', () {
    late MergeBastionGame game;
    final session = FlameCartridgeSession<MergeBastionGame>(
      makeContext(CartridgeSave()),
      (s) => game = MergeBastionGame(s, seed: 9),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    final btn = game.summonButtonRect.center;
    game.onPointerDown(Vector2(btn.dx, btn.dy));
    game.onPointerUp(Vector2(btn.dx, btn.dy));
    game.onPointerDown(Vector2(btn.dx, btn.dy));
    game.onPointerUp(Vector2(btn.dx, btn.dy));
    expect(game.bastion.unitCount, 2);
    final cells = [
      for (var i = 0; i < BastionWorld.cellCount; i++)
        if (game.bastion.unitAt(i) != null) i,
    ];
    final from = game.cellCenterOnScreen(cells[0]);
    final to = game.cellCenterOnScreen(cells[1]);
    game.onPointerDown(Vector2(from.dx, from.dy));
    expect(game.dragFrom, cells[0]);
    game.onPointerMove(Vector2((from.dx + to.dx) / 2, (from.dy + to.dy) / 2), Vector2.zero());
    paint();
    game.onPointerMove(Vector2(to.dx, to.dy), Vector2.zero());
    game.onPointerUp(Vector2(to.dx, to.dy));
    expect(game.bastion.unitAt(cells[1])!.tier, 2);
    expect(game.bastion.unitCount, 1);
    expect((session.context.audio as SilentAudio).played, contains(Sfx.merge));
    // Let a wave arrive and get shot at.
    for (var i = 0; i < 60 * 8; i++) {
      game.update(1 / 60);
      if (i % 30 == 0) paint();
    }
    paint();
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
  });
}
