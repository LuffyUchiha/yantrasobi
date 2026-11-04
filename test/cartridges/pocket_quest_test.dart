import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/pocket_quest/pocket_quest.dart';
import 'package:yantrasobi/cartridges/pocket_quest/quest_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/widget_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/cartridge/manifest.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// Greedy player: first damage skill (or Hearth when hurt), tonic when below
/// 70% in shops plus every other affordable ware, camps before battles when
/// below half HP.
bool greedy(QuestWorld w) {
  var guard = 0;
  while (!w.isOver && guard++ < 500) {
    switch (w.phase) {
      case QuestPhase.choosing:
        var idx = w.hero.hpFraction < 0.5 ? w.offers.indexWhere((o) => o.blessing == Blessing.hearth) : -1;
        if (idx < 0) idx = w.offers.indexWhere((o) => o.isDamage);
        if (idx < 0) idx = 0;
        w.choose(idx);
      case QuestPhase.shopping:
        if (w.hero.hpFraction < 0.7) w.buy(0);
        for (var i = 1; i < w.shop.length; i++) {
          w.buy(i);
        }
        w.leaveShop();
      case QuestPhase.travelling:
        if (w.hero.hpFraction < 0.5 && w.canCamp && w.nextKind == DayKind.battle) {
          w.camp();
        } else {
          w.advanceDay();
        }
      case QuestPhase.won:
      case QuestPhase.lost:
        break;
    }
  }
  return w.won;
}

/// Weak player: always the lowest-power offer, never shops or camps.
bool weakest(QuestWorld w) {
  var guard = 0;
  while (!w.isOver && guard++ < 500) {
    switch (w.phase) {
      case QuestPhase.choosing:
        var pick = 0;
        for (var i = 1; i < w.offers.length; i++) {
          if (w.offers[i].power < w.offers[pick].power) pick = i;
        }
        w.choose(pick);
      case QuestPhase.shopping:
        w.leaveShop();
      case QuestPhase.travelling:
        w.advanceDay();
      case QuestPhase.won:
      case QuestPhase.lost:
        break;
    }
  }
  return w.won;
}

/// Advances (choosing the first offer / leaving shops) until [stop] is true.
void walkUntil(QuestWorld w, bool Function() stop) {
  var guard = 0;
  while (!stop() && !w.isOver && guard++ < 200) {
    if (w.phase == QuestPhase.choosing) {
      w.choose(0);
    } else if (w.phase == QuestPhase.shopping) {
      w.leaveShop();
    } else {
      w.advanceDay();
    }
  }
}

QuestEnemy dummy({int hp = 500, int atk = 8, int def = 0, int speed = 1}) =>
    QuestEnemy(name: 'Dummy', species: 0, maxHp: hp, atk: atk, def: def, speed: speed, crit: 0);

QuestHero hero({double crit = 0}) => QuestHero()..baseCrit = crit;

List<CombatEntry> kind(CombatReport r, CombatKind k) => r.entries.where((e) => e.kind == k).toList();

CartridgeContext ctx({void Function()? onSave}) => CartridgeContext(
  manifest: PocketQuestCartridge.kManifest,
  save: CartridgeSave(),
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid and uses the widgets engine', () {
    const m = PocketQuestCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'pocket-quest');
    expect(m.engine, CartridgeEngine.widgets);
    expect(m.version, '1.0.0');
    expect(m.mechanics, isNotEmpty);
    expect(const PocketQuestCartridge().manifest, same(m));
  });

  test('day schedule: shrine first, elite on day 15, boss on day 30, shops before both', () {
    for (var seed = 0; seed < 30; seed++) {
      final s = QuestWorld.scheduleFor(seed);
      expect(s.length, kChapterDays);
      expect(s[0], DayKind.choice);
      expect(s[1], DayKind.battle);
      expect(s[kEliteDay - 1], DayKind.elite);
      expect(s[kBossDay - 1], DayKind.boss);
      expect(s[kEliteDay - 2], DayKind.shop);
      expect(s[kBossDay - 2], DayKind.shop);
      expect(s.where((k) => k == DayKind.elite).length, 1);
      expect(s.where((k) => k == DayKind.boss).length, 1);
      expect(s.where((k) => k == DayKind.battle).length, greaterThan(6));
      expect(QuestWorld.scheduleFor(seed), s, reason: 'schedule is a pure function of the seed');
    }
    expect(QuestWorld.scheduleFor(1), isNot(QuestWorld.scheduleFor(2)));
  });

  test('strike damage respects ATK, DEF and crits; at least 1', () {
    expect(strikeDamage(12, 2), 10);
    expect(strikeDamage(20, 2), 18);
    expect(strikeDamage(12, 6), 6);
    expect(strikeDamage(3, 50), 1);
    expect(strikeDamage(12, 2, crit: true), 16);
    expect(strikeDamage(12, 2, crit: true, critMult: 2.4), 27);
    final h = QuestHero();
    expect(h.atk, 12);
    h.learn(SkillId.sharpBlade);
    h.learn(SkillId.sharpBlade);
    expect(h.atk, (12 * 1.3).round());
    h.learn(SkillId.stoneSkin);
    expect(h.def, 4);
  });

  test('combat is deterministic and follows ATK / DEF / crit', () {
    final a = simulateCombat(hero(crit: 0.3), dummy(hp: 200), math.Random(5));
    final b = simulateCombat(hero(crit: 0.3), dummy(hp: 200), math.Random(5));
    expect(a.entries.map((e) => e.text).toList(), b.entries.map((e) => e.text).toList());
    expect(a.heroWon, b.heroWon);
    expect(a.heroHpAfter, b.heroHpAfter);

    // No crits: every hero blow is exactly atk - def; every foe blow atk - hero def.
    final plain = simulateCombat(hero(), dummy(hp: 100, atk: 9, def: 3), math.Random(1));
    final hits = kind(plain, CombatKind.heroHit).where((e) => e.round <= 12);
    expect(hits, isNotEmpty);
    expect(hits.every((e) => e.value == 12 - 3), isTrue);
    expect(
      kind(plain, CombatKind.enemyHit).where((e) => e.round <= 12).every((e) => e.value == 9 - 2),
      isTrue,
    );
    expect(plain.heroWon, isTrue);
    expect(plain.rounds, (100 / 9).ceil());
    expect(plain.entries.last.kind, CombatKind.victory);

    // Always-crit hero.
    final crits = simulateCombat(hero(crit: 1), dummy(hp: 100, def: 3), math.Random(1));
    expect(kind(crits, CombatKind.heroHit), isEmpty);
    expect(kind(crits, CombatKind.heroCrit).first.value, (12 * 1.5 - 3).round());
    expect(crits.rounds, lessThan(plain.rounds));

    // Stronger hero wins faster; a hopeless hero loses with 0 HP.
    final strong = hero()..baseAtk = 30;
    expect(simulateCombat(strong, dummy(hp: 100), math.Random(1)).rounds, lessThan(plain.rounds));
    final weak = hero()
      ..baseAtk = 1
      ..hp = 10;
    final lost = simulateCombat(weak, dummy(hp: 500, atk: 20), math.Random(1));
    expect(lost.heroWon, isFalse);
    expect(lost.heroHpAfter, 0);
    expect(lost.entries.last.kind, CombatKind.defeat);
    // The faster side opens the fight.
    final fast = simulateCombat(hero(), dummy(speed: 9), math.Random(1));
    expect(fast.entries.firstWhere((e) => e.round == 1).kind, CombatKind.enemyHit);
  });

  test('lifesteal, thorns, venom, shield and twin strike take effect', () {
    // Lifesteal: 10% per level of the damage dealt, never above max HP.
    final leech = hero()
      ..hp = 50
      ..learn(SkillId.leechFang);
    final l = simulateCombat(leech, dummy(hp: 60, atk: 1), math.Random(2));
    final heals = kind(l, CombatKind.heal);
    expect(heals, isNotEmpty);
    expect(heals.first.value, 1); // 10% of 12 rounds to 1
    final plainHp = simulateCombat(hero()..hp = 50, dummy(hp: 60, atk: 1), math.Random(2)).heroHpAfter;
    expect(l.heroHpAfter, greaterThan(plainHp));

    // Thorns: 20% per level of the blow, before shields.
    final thorny = hero()
      ..learn(SkillId.brambleShell)
      ..learn(SkillId.brambleShell);
    final t = simulateCombat(thorny, dummy(hp: 300, atk: 12), math.Random(3));
    final reflects = kind(t, CombatKind.thorns).where((e) => e.round <= 12).toList();
    expect(reflects, isNotEmpty);
    expect(reflects.every((e) => e.value == (10 * 0.4).round()), isTrue);
    // Living Fortress synergy adds hero DEF to each reflection.
    thorny.learn(SkillId.stoneSkin);
    expect(thorny.has(Synergy.livingFortress), isTrue);
    final t2 = simulateCombat(thorny, dummy(hp: 300, atk: 12), math.Random(3));
    expect(kind(t2, CombatKind.thorns).first.value, math.max(1, ((12 - 4) * 0.4).round()) + 4);

    // Venom: stacks per hit and ticks every round, growing.
    final venom = hero()..learn(SkillId.venomEdge);
    final v = simulateCombat(venom, dummy(hp: 400, atk: 1), math.Random(4));
    final ticks = kind(v, CombatKind.poison).map((e) => e.value).toList();
    expect(ticks.take(4).toList(), [1, 2, 3, 4]);
    expect(v.rounds, lessThan(simulateCombat(hero(), dummy(hp: 400, atk: 1), math.Random(4)).rounds));

    // Shield on battle start absorbs the first blows.
    final ward = hero()..learn(SkillId.barkWard);
    expect(ward.shieldOnStart, 10);
    final s = simulateCombat(ward, dummy(hp: 300, atk: 8), math.Random(5));
    expect(kind(s, CombatKind.shield).single.value, 10);
    final firstHit = kind(s, CombatKind.enemyHit).first;
    expect(firstHit.value, 0);
    expect(firstHit.text, contains('6 blocked'));
    expect(firstHit.heroHp, 100);

    // Twin strike adds bonus blows.
    final twin = hero();
    for (var i = 0; i < 5; i++) {
      twin.learn(SkillId.twinStrike);
    }
    final tw = simulateCombat(twin, dummy(hp: 400, atk: 1), math.Random(6));
    expect(kind(tw, CombatKind.heroHit).where((e) => e.text.startsWith('Twin')), isNotEmpty);
  });

  test('choices apply skills, stack levels up to the cap and unlock synergies', () {
    final w = QuestWorld(seed: 11);
    expect(w.advanceDay()!.kind, DayKind.choice);
    expect(w.phase, QuestPhase.choosing);
    expect(w.offers.length, 3);
    expect(w.offers.toSet().length, 3);
    expect(w.offers.every((o) => o.isSkill), isTrue, reason: 'day 1 offers skills only');
    expect(w.canAdvance, isFalse);
    expect(w.advanceDay(), isNull);
    final picked = w.offers[1].skill!;
    expect(w.choose(1), isTrue);
    expect(w.hero.level(picked), 1);
    expect(w.phase, QuestPhase.travelling);
    expect(w.choose(0), isFalse);

    final h = QuestHero();
    for (var i = 0; i < 7; i++) {
      h.learn(SkillId.keenEye);
    }
    expect(h.level(SkillId.keenEye), kMaxSkillLevel);
    expect(h.learn(SkillId.keenEye), isFalse);
    expect(h.critChance, closeTo(0.05 + 0.4, 1e-9));
    expect(h.has(Synergy.deadeye), isFalse);
    h.learn(SkillId.executioner);
    expect(h.synergies, [Synergy.deadeye]);
    expect(h.critChance, closeTo(0.55, 1e-9));
    expect(h.critMult, closeTo(1.8, 1e-9));
    h.learn(SkillId.vigor);
    expect(h.maxHp, 120);
    expect(h.hp, 120);
    expect(h.buildSummary, startsWith('Keen Eye 5'));

    final b = QuestWorld(seed: 1);
    b.applyBlessing(Blessing.whetstone);
    b.applyBlessing(Blessing.goldCache);
    expect(b.hero.baseAtk, 15);
    expect(b.gold, 40);
  });

  test('shop purchases spend gold, fail when poor or sold out', () {
    final w = QuestWorld(seed: 4);
    walkUntil(w, () => w.phase == QuestPhase.shopping);
    expect(w.phase, QuestPhase.shopping);
    expect(w.shop.first.kind, ShopKind.potion);
    expect(w.shop.length, 4);
    expect(w.canAdvance, isFalse);
    w.gold = 0;
    expect(w.buy(0), isFalse);
    expect(w.shop[0].sold, isFalse);

    w.gold = 1000;
    w.hero.hp = 10;
    final price = w.shop[0].price;
    expect(w.buy(0), isTrue);
    expect(w.gold, 1000 - price);
    expect(w.hero.hp, 10 + (w.hero.maxHp * 0.5).round());
    expect(w.buy(0), isFalse, reason: 'sold out');
    expect(w.gold, 1000 - price);
    final atk = w.hero.baseAtk;
    final i = w.shop.indexWhere((s) => s.kind == ShopKind.whetstone);
    if (i >= 0) {
      expect(w.buy(i), isTrue);
      expect(w.hero.baseAtk, atk + 2);
    }
    expect(w.leaveShop(), isTrue);
    expect(w.buy(1), isFalse, reason: 'not in a shop');
    expect(w.phase, QuestPhase.travelling);
  });

  test('rest and camp heal; camps are limited and never skip elite or boss days', () {
    final w = QuestWorld(seed: 2);
    w.hero.hp = 10;
    expect(w.rest(), 40);
    expect(w.hero.hp, 50);
    w.hero.hp = 95;
    expect(w.rest(), 5, reason: 'capped at max HP');

    w.hero.hp = 20;
    final ev = w.camp()!;
    expect(w.day, 1);
    expect(w.camps, kStartCamps - 1);
    expect(ev.healed, greaterThanOrEqualTo(40));
    expect(w.hero.hp, greaterThan(60));
    w.camp();
    w.camp();
    expect(w.camps, 0);
    expect(w.camp(), isNull);

    final e = QuestWorld(seed: 2);
    e.day = kEliteDay - 1;
    expect(e.canCamp, isFalse);
    e.day = kBossDay - 1;
    expect(e.canCamp, isFalse);
  });

  test('death ends the run as lost with days-based score', () {
    final w = QuestWorld(seed: 9);
    w.advanceDay();
    w.choose(0);
    w.hero.baseAtk = 1;
    w.hero.hp = 1;
    final ev = w.advanceDay()!;
    expect(ev.kind, DayKind.battle);
    expect(ev.report!.heroWon, isFalse);
    expect(w.phase, QuestPhase.lost);
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    expect(w.hero.hp, 0);
    expect(w.deathCause, ev.enemy!.name);
    expect(w.daysSurvived, 1);
    expect(w.score, 10 + w.gold);
    expect(w.advanceDay(), isNull);
  });

  test('beating the day-30 boss wins with the boss bonus', () {
    final w = QuestWorld(seed: 6, chapter: 2);
    w.hero
      ..baseAtk = 5000
      ..baseMaxHp = 99999
      ..hp = 99999;
    walkUntil(w, () => false);
    expect(w.won, isTrue);
    expect(w.day, kBossDay);
    expect(w.lastEvent!.kind, DayKind.boss);
    expect(w.lastEvent!.enemy!.name, kBosses[1]);
    expect(w.daysSurvived, 30);
    expect(w.score, 30 * 10 + w.gold + kBossBonus * 2);
    // Later chapters field tougher foes.
    expect(w.enemyFor(10).atk, greaterThan(QuestWorld(seed: 6).enemyFor(10).atk));
  });

  test('greedy builds clear chapter 1 for most seeds; weakest picks usually lose', () {
    var greedyWins = 0;
    var weakWins = 0;
    for (var seed = 0; seed < 20; seed++) {
      if (greedy(QuestWorld(seed: seed))) greedyWins++;
      if (weakest(QuestWorld(seed: seed))) weakWins++;
    }
    expect(greedyWins, greaterThanOrEqualTo(12), reason: 'greedy won $greedyWins/20');
    expect(weakWins, lessThanOrEqualTo(4), reason: 'weakest won $weakWins/20');
  });

  test('runs are deterministic per seed', () {
    String run(int seed) {
      final w = QuestWorld(seed: seed);
      greedy(w);
      return '${w.score}|${w.day}|${w.hero.buildSummary}|${w.journal.join('/')}';
    }

    for (final seed in [0, 7, 123]) {
      expect(run(seed), run(seed));
    }
    expect(run(1), isNot(run(2)));
  });

  testWidgets('plays inside a minimal host; pause freezes the fight; timers cleaned up', (tester) async {
    // Small portrait phone (360 x 690 logical).
    tester.view.physicalSize = const Size(1080, 2070);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final context = ctx();
    final session = const PocketQuestCartridge(seed: 3).createSession(context) as WidgetCartridgeSession;
    session.start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Builder(builder: session.buildView)),
      ),
    );
    expect(find.text('NEXT DAY'), findsOneWidget);
    expect(find.text('Day 0 / 30'), findsOneWidget);

    // Day 1: shrine choice.
    await tester.tap(find.byKey(const Key('pq-next')));
    await tester.pump();
    expect(find.byKey(const Key('pq-choice-2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pq-choice-0')));
    await tester.pump();

    // Day 2: a battle animates round by round.
    await tester.tap(find.byKey(const Key('pq-next')));
    await tester.pump();
    final state = tester.state<PocketQuestGameState>(find.byType(PocketQuestGame));
    expect(state.animating, isTrue);
    expect(state.timerActive, isTrue);
    expect(find.text('SKIP FIGHT'), findsOneWidget);
    final before = state.revealed;

    session.pause();
    await tester.pump(const Duration(seconds: 3));
    expect(state.revealed, before, reason: 'no progress while paused');
    expect(state.timerActive, isFalse);

    session.resume();
    await tester.pump(PocketQuestGameState.roundTick + const Duration(milliseconds: 20));
    expect(state.revealed, greaterThan(before));
    for (var i = 0; i < 100 && state.animating; i++) {
      await tester.pump(PocketQuestGameState.roundTick);
    }
    expect(state.animating, isFalse);
    expect(state.timerActive, isFalse);
    expect(session.entityCount, greaterThan(2));

    // A few more days, handling shrines and shops.
    for (var i = 0; i < 4 && !state.world.isOver; i++) {
      if (state.world.phase == QuestPhase.choosing) {
        await tester.tap(find.byKey(const Key('pq-choice-0')));
      } else {
        await tester.tap(find.byKey(const Key('pq-next')));
      }
      await tester.pump();
      for (var j = 0; j < 100 && state.animating; j++) {
        await tester.pump(PocketQuestGameState.roundTick);
      }
    }
    expect(state.world.day, greaterThan(2));
    expect((context.audio as SilentAudio).played, isNotEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(state.timerActive, isFalse);
    session.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('winning a run ends the session once and unlocks the next chapter', (tester) async {
    tester.view.physicalSize = const Size(1080, 2070);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var saves = 0;
    final context = ctx(onSave: () => saves++);
    final session = const PocketQuestCartridge(seed: 5).createSession(context) as WidgetCartridgeSession;
    session.start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Builder(builder: session.buildView)),
      ),
    );
    final state = tester.state<PocketQuestGameState>(find.byType(PocketQuestGame));
    state.world.hero
      ..baseAtk = 5000
      ..baseMaxHp = 99999
      ..hp = 99999;

    for (var i = 0; i < 200 && session.state != SessionState.ended; i++) {
      final w = state.world;
      if (w.phase == QuestPhase.choosing) {
        await tester.tap(find.byKey(const Key('pq-choice-0')));
      } else if (!w.isOver) {
        await tester.tap(find.byKey(const Key('pq-next'))); // next day, skip fight, or leave shop
      }
      await tester.pump(PocketQuestGameState.roundTick);
    }
    expect(session.state, SessionState.ended);
    final result = session.result!;
    expect(result.won, isTrue);
    expect(result.score, state.world.score);
    expect(result.details['Chapter'], '1');
    expect(result.details['Days'], '30/30');
    expect(context.save.data['chapter'], 2);
    expect(saves, 1);
    expect(find.text('VICTORY'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}
