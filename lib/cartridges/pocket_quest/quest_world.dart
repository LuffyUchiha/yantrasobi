import 'dart:math' as math;

/// Pure-Dart rules for Pocket Quest, a day-by-day auto-adventure.
///
/// Moss, a small wandering tortoise knight, walks a 30-day trail. Every day
/// brings one event: an auto-resolved battle, a treasure, a choice between
/// three skills or blessings, a shop, or a quiet rest. Day 15 is an elite
/// fight and day 30 the chapter boss. Skills have levels and some pairs form
/// synergies, so builds snowball.
///
/// Everything here is deterministic for a given seed (and chapter): the day
/// schedule is fixed up front and every day's contents (foes, offers, shop,
/// combat dice) come from a per-day random stream, so the same choices always
/// produce the same run.

const String kHeroName = 'Moss';
const int kChapterDays = 30;
const int kEliteDay = 15;
const int kBossDay = 30;
const int kMaxSkillLevel = 5;
const int kStartCamps = 3;
const int kBossBonus = 300;

/// Fraction of max HP recovered every morning.
const double kDawnHeal = 0.05;

enum DayKind { battle, treasure, choice, shop, rest, elite, boss }

enum QuestPhase { travelling, choosing, shopping, won, lost }

// ------------------------------------------------------------------ skills

enum SkillId {
  sharpBlade,
  keenEye,
  twinStrike,
  venomEdge,
  executioner,
  emberHeart,
  leechFang,
  barkWard,
  brambleShell,
  stoneSkin,
  vigor,
  quickstep,
  wayfarerTea,
  luckyCoin,
}

class SkillDef {
  const SkillDef(this.id, this.name, this.power, {this.damage = false});

  final SkillId id;
  final String name;

  /// Rough strength ranking (higher = stronger), used by AI test players.
  final int power;

  /// True for skills that directly raise damage output.
  final bool damage;
}

const Map<SkillId, SkillDef> kSkills = {
  SkillId.sharpBlade: SkillDef(SkillId.sharpBlade, 'Sharpened Blade', 9, damage: true),
  SkillId.keenEye: SkillDef(SkillId.keenEye, 'Keen Eye', 7, damage: true),
  SkillId.twinStrike: SkillDef(SkillId.twinStrike, 'Twin Strike', 8, damage: true),
  SkillId.venomEdge: SkillDef(SkillId.venomEdge, 'Venom Edge', 7, damage: true),
  SkillId.executioner: SkillDef(SkillId.executioner, 'Executioner', 6, damage: true),
  SkillId.emberHeart: SkillDef(SkillId.emberHeart, 'Ember Heart', 6, damage: true),
  SkillId.leechFang: SkillDef(SkillId.leechFang, 'Leech Fang', 6),
  SkillId.barkWard: SkillDef(SkillId.barkWard, 'Bark Ward', 5),
  SkillId.brambleShell: SkillDef(SkillId.brambleShell, 'Bramble Shell', 5),
  SkillId.stoneSkin: SkillDef(SkillId.stoneSkin, 'Stone Skin', 5),
  SkillId.vigor: SkillDef(SkillId.vigor, 'Vigor', 5),
  SkillId.quickstep: SkillDef(SkillId.quickstep, 'Quickstep', 3),
  SkillId.wayfarerTea: SkillDef(SkillId.wayfarerTea, "Wayfarer's Tea", 2),
  SkillId.luckyCoin: SkillDef(SkillId.luckyCoin, 'Lucky Coin', 1),
};

/// One-line effect text of [id] at [level] (cumulative).
String describeSkill(SkillId id, int level) {
  String pct(double v) => '${(v * 100).round()}%';
  switch (id) {
    case SkillId.sharpBlade:
      return '+${pct(0.15 * level)} attack';
    case SkillId.keenEye:
      return '+${pct(0.08 * level)} critical chance';
    case SkillId.twinStrike:
      return '${pct(0.15 * level)} chance to strike twice';
    case SkillId.venomEdge:
      return 'Each hit adds $level venom (ticks every round)';
    case SkillId.executioner:
      return 'Critical hits deal x${(1.5 + 0.3 * level).toStringAsFixed(1)}';
    case SkillId.emberHeart:
      return '+${pct(0.25 * level)} damage below half HP';
    case SkillId.leechFang:
      return 'Heal ${pct(0.1 * level)} of damage dealt';
    case SkillId.barkWard:
      return 'Start battles with a ${pct(0.1 * level)} max-HP shield';
    case SkillId.brambleShell:
      return 'Reflect ${pct(0.2 * level)} of damage taken';
    case SkillId.stoneSkin:
      return '+${2 * level} defense';
    case SkillId.vigor:
      return '+${20 * level} max HP';
    case SkillId.quickstep:
      return '+${2 * level} speed, ${pct(0.05 * level)} dodge';
    case SkillId.wayfarerTea:
      return 'Heal ${pct(0.05 * level)} max HP every dawn';
    case SkillId.luckyCoin:
      return '+${pct(0.25 * level)} gold found';
  }
}

enum Synergy { toxicFlurry, deadeye, livingFortress, bloodPact }

class SynergyDef {
  const SynergyDef(this.name, this.a, this.b, this.text);
  final String name;
  final SkillId a;
  final SkillId b;
  final String text;
}

const Map<Synergy, SynergyDef> kSynergies = {
  Synergy.toxicFlurry: SynergyDef(
    'Toxic Flurry',
    SkillId.venomEdge,
    SkillId.twinStrike,
    'Every hit adds +1 extra venom',
  ),
  Synergy.deadeye: SynergyDef('Deadeye', SkillId.keenEye, SkillId.executioner, '+10% critical chance'),
  Synergy.livingFortress: SynergyDef(
    'Living Fortress',
    SkillId.brambleShell,
    SkillId.stoneSkin,
    'Thorns also reflect your defense',
  ),
  Synergy.bloodPact: SynergyDef(
    'Blood Pact',
    SkillId.leechFang,
    SkillId.emberHeart,
    'Lifesteal doubles below half HP',
  ),
};

// --------------------------------------------------------------- blessings

enum Blessing { hearth, whetstone, ironOath, giantsBrew, goldCache }

class BlessingDef {
  const BlessingDef(this.name, this.text, this.power);
  final String name;
  final String text;
  final int power;
}

const Map<Blessing, BlessingDef> kBlessings = {
  Blessing.hearth: BlessingDef('Hearth Blessing', 'Heal 60% of max HP', 3),
  Blessing.whetstone: BlessingDef('Whetstone Spirit', '+3 base attack', 6),
  Blessing.ironOath: BlessingDef('Iron Oath', '+2 base defense', 4),
  Blessing.giantsBrew: BlessingDef("Giant's Brew", '+25 max HP', 4),
  Blessing.goldCache: BlessingDef('Buried Cache', '+40 gold', 1),
};

/// One card of a choice event: either a skill level or a blessing.
class QuestOffer {
  const QuestOffer.skill(SkillId this.skill) : blessing = null;
  const QuestOffer.blessing(Blessing this.blessing) : skill = null;

  final SkillId? skill;
  final Blessing? blessing;

  bool get isSkill => skill != null;
  String get name => isSkill ? kSkills[skill]!.name : kBlessings[blessing]!.name;
  int get power => isSkill ? kSkills[skill]!.power : kBlessings[blessing]!.power;
  bool get isDamage => isSkill && kSkills[skill]!.damage;

  @override
  bool operator ==(Object other) => other is QuestOffer && other.skill == skill && other.blessing == blessing;

  @override
  int get hashCode => Object.hash(skill, blessing);

  @override
  String toString() => name;
}

// -------------------------------------------------------------------- shop

enum ShopKind { potion, whetstone, plating, elixir, tome }

class ShopItem {
  ShopItem(this.kind, this.price, {this.skill});

  final ShopKind kind;
  final int price;

  /// Skill raised by a [ShopKind.tome].
  final SkillId? skill;
  bool sold = false;

  String get name => switch (kind) {
    ShopKind.potion => 'Moss Tonic',
    ShopKind.whetstone => 'Whetstone',
    ShopKind.plating => 'Shell Plating',
    ShopKind.elixir => 'Root Elixir',
    ShopKind.tome => 'Tome: ${kSkills[skill]!.name}',
  };

  String get text => switch (kind) {
    ShopKind.potion => 'Heal 50% of max HP',
    ShopKind.whetstone => '+2 base attack',
    ShopKind.plating => '+1 base defense',
    ShopKind.elixir => '+15 max HP',
    ShopKind.tome => 'Raise this skill by one level',
  };
}

// -------------------------------------------------------------------- hero

class QuestHero {
  QuestHero();

  int baseMaxHp = 100;
  int hp = 100;
  int baseAtk = 12;
  int baseDef = 2;
  double baseCrit = 0.05;
  int baseSpeed = 5;
  final Map<SkillId, int> skills = {};

  int level(SkillId id) => skills[id] ?? 0;
  bool has(Synergy s) => level(kSynergies[s]!.a) > 0 && level(kSynergies[s]!.b) > 0;
  List<Synergy> get synergies => [
    for (final s in Synergy.values)
      if (has(s)) s,
  ];

  int get maxHp => baseMaxHp + 20 * level(SkillId.vigor);
  int get atk => (baseAtk * (1 + 0.15 * level(SkillId.sharpBlade))).round();
  int get def => baseDef + 2 * level(SkillId.stoneSkin);
  int get speed => baseSpeed + 2 * level(SkillId.quickstep);
  double get critChance =>
      math.min(0.95, baseCrit + 0.08 * level(SkillId.keenEye) + (has(Synergy.deadeye) ? 0.1 : 0));
  double get critMult => 1.5 + 0.3 * level(SkillId.executioner);
  double get doubleChance => 0.15 * level(SkillId.twinStrike);
  int get venomPerHit =>
      level(SkillId.venomEdge) == 0 ? 0 : level(SkillId.venomEdge) + (has(Synergy.toxicFlurry) ? 1 : 0);
  double get emberBonus => 0.25 * level(SkillId.emberHeart);
  double get lifesteal => 0.1 * level(SkillId.leechFang);
  int get shieldOnStart => (maxHp * 0.1 * level(SkillId.barkWard)).round();
  double get thorns => 0.2 * level(SkillId.brambleShell);
  double get dodge => 0.05 * level(SkillId.quickstep);
  double get dawnHeal => 0.05 * level(SkillId.wayfarerTea);
  double get goldMult => 1 + 0.25 * level(SkillId.luckyCoin);

  bool get alive => hp > 0;
  double get hpFraction => maxHp == 0 ? 0 : hp / maxHp;

  /// Heals by [amount] up to max HP, returning the HP actually restored.
  int heal(int amount) {
    final before = hp;
    hp = math.min(maxHp, hp + math.max(0, amount));
    return hp - before;
  }

  /// Raises [id] by one level (up to [kMaxSkillLevel]). Returns false if maxed.
  bool learn(SkillId id) {
    final l = level(id);
    if (l >= kMaxSkillLevel) return false;
    skills[id] = l + 1;
    if (id == SkillId.vigor) hp += 20;
    return true;
  }

  /// "Sharpened Blade 2, Keen Eye 1" (strongest first) or "No skills".
  String get buildSummary {
    if (skills.isEmpty) return 'No skills';
    final entries = skills.entries.toList()
      ..sort((a, b) => b.value != a.value ? b.value - a.value : a.key.index - b.key.index);
    return entries.map((e) => '${kSkills[e.key]!.name} ${e.value}').join(', ');
  }

  QuestHero copy() {
    final h = QuestHero()
      ..baseMaxHp = baseMaxHp
      ..hp = hp
      ..baseAtk = baseAtk
      ..baseDef = baseDef
      ..baseCrit = baseCrit
      ..baseSpeed = baseSpeed;
    h.skills.addAll(skills);
    return h;
  }
}

// ------------------------------------------------------------------- enemy

enum EnemyTrait { none, armored, venomous, swift, brute }

class QuestEnemy {
  QuestEnemy({
    required this.name,
    required this.species,
    required this.maxHp,
    required this.atk,
    required this.def,
    required this.speed,
    this.trait = EnemyTrait.none,
    this.crit = 0.06,
    this.rank = DayKind.battle,
  });

  final String name;

  /// Index into the species palette (used by the renderer for shape/colour).
  final int species;
  final int maxHp;
  final int atk;
  final int def;
  final int speed;
  final EnemyTrait trait;
  final double crit;

  /// [DayKind.battle], [DayKind.elite] or [DayKind.boss].
  final DayKind rank;
}

const List<String> kSpecies = [
  'Thistle Rat',
  'Bog Wisp',
  'Gloom Toad',
  'Rustcap Beetle',
  'Mire Leech',
  'Ash Moth',
  'Briar Hound',
  'Slate Crab',
  'Hollow Stag',
  'Murk Eel',
];

const List<String> kBosses = ['Mudmaw the Sunken King', 'The Lantern Widow', 'Grimbark Colossus'];
const String kEliteName = 'Thornback Warden';

const Map<EnemyTrait, String> _traitWord = {
  EnemyTrait.none: '',
  EnemyTrait.armored: 'Plated ',
  EnemyTrait.venomous: 'Venomous ',
  EnemyTrait.swift: 'Darting ',
  EnemyTrait.brute: 'Hulking ',
};

// ------------------------------------------------------------------ combat

enum CombatKind {
  info,
  heroHit,
  heroCrit,
  enemyHit,
  enemyCrit,
  dodge,
  heal,
  shield,
  thorns,
  poison,
  victory,
  defeat,
}

class CombatEntry {
  const CombatEntry(
    this.round,
    this.kind,
    this.text,
    this.heroHp,
    this.enemyHp,
    this.shield, [
    this.value = 0,
  ]);

  final int round;
  final CombatKind kind;
  final String text;

  /// HP values *after* this entry, for animating bars.
  final int heroHp;
  final int enemyHp;
  final int shield;

  /// Damage / heal amount, when meaningful.
  final int value;

  @override
  String toString() => '[$round] $text';
}

class CombatReport {
  const CombatReport(this.entries, {required this.heroWon, required this.heroHpAfter, required this.rounds});

  final List<CombatEntry> entries;
  final bool heroWon;
  final int heroHpAfter;
  final int rounds;
}

/// Damage of one blow: `raw - def`, at least 1. A crit multiplies first.
int strikeDamage(double raw, int def, {bool crit = false, double critMult = 1.5}) =>
    math.max(1, ((crit ? raw * critMult : raw) - def).round());

/// Resolves a fight round by round without mutating [hero]. Faster side
/// strikes first (hero wins ties). From round 13 every blow grows stronger so
/// fights always end; after [maxRounds] the hero is overwhelmed.
CombatReport simulateCombat(QuestHero hero, QuestEnemy enemy, math.Random rng, {int maxRounds = 60}) {
  final log = <CombatEntry>[];
  var hHp = hero.hp;
  var eHp = enemy.maxHp;
  var shield = hero.shieldOnStart;
  var eVenom = 0;
  var hVenom = 0;
  var round = 0;
  var enrage = 1.0;

  void add(CombatKind kind, String text, [int value = 0]) =>
      log.add(CombatEntry(round, kind, text, math.max(0, hHp), math.max(0, eHp), shield, value));

  add(CombatKind.info, 'A ${enemy.name} blocks the trail!');
  if (shield > 0) add(CombatKind.shield, 'Bark Ward raises a $shield-point shield.', shield);
  final heroFirst = hero.speed >= enemy.speed;
  add(CombatKind.info, heroFirst ? '$kHeroName is quicker and strikes first.' : '${enemy.name} moves first!');

  void heroStrike(bool twin) {
    final low = hHp * 2 < hero.maxHp;
    var raw = hero.atk * enrage;
    if (low) raw *= 1 + hero.emberBonus;
    final crit = rng.nextDouble() < hero.critChance;
    final dmg = strikeDamage(raw, enemy.def, crit: crit, critMult: hero.critMult);
    eHp -= dmg;
    final venom = hero.venomPerHit;
    if (venom > 0) eVenom += venom;
    final verb = crit ? 'CRITS' : 'hits';
    final tail = venom > 0 ? ' (+$venom venom)' : '';
    add(
      crit ? CombatKind.heroCrit : CombatKind.heroHit,
      '${twin ? 'Twin strike! ' : ''}$kHeroName $verb for $dmg$tail',
      dmg,
    );
    if (hero.lifesteal > 0 && hHp > 0) {
      final pact = hero.has(Synergy.bloodPact) && low ? 2 : 1;
      final want = math.max(1, (dmg * hero.lifesteal * pact).round());
      final got = math.min(want, hero.maxHp - hHp);
      if (got > 0) {
        hHp += got;
        add(CombatKind.heal, 'Leech Fang drinks $got HP.', got);
      }
    }
  }

  void enemyStrike() {
    if (hero.dodge > 0 && rng.nextDouble() < hero.dodge) {
      add(CombatKind.dodge, '$kHeroName sidesteps the blow.');
      return;
    }
    final crit = rng.nextDouble() < enemy.crit;
    final full = strikeDamage(enemy.atk * enrage, hero.def, crit: crit);
    final blocked = math.min(shield, full);
    shield -= blocked;
    final dmg = full - blocked;
    hHp -= dmg;
    if (enemy.trait == EnemyTrait.venomous) hVenom += 1;
    final blockedText = blocked > 0 ? ' ($blocked blocked)' : '';
    add(
      crit ? CombatKind.enemyCrit : CombatKind.enemyHit,
      '${enemy.name} ${crit ? 'crits' : 'hits'} for $dmg$blockedText',
      dmg,
    );
    if (hero.thorns > 0) {
      final reflect =
          math.max(1, (full * hero.thorns).round()) + (hero.has(Synergy.livingFortress) ? hero.def : 0);
      eHp -= reflect;
      add(CombatKind.thorns, 'Bramble Shell reflects $reflect.', reflect);
    }
  }

  var heroWon = false;
  var decided = false;
  while (!decided && round < maxRounds) {
    round++;
    enrage = round > 12 ? 1 + 0.15 * (round - 12) : 1.0;
    if (round == 13) add(CombatKind.info, 'The fight drags on - every blow grows fiercer!');
    for (final heroTurn in heroFirst ? const [true, false] : const [false, true]) {
      if (heroTurn) {
        heroStrike(false);
        if (eHp > 0 && hero.doubleChance > 0 && rng.nextDouble() < hero.doubleChance) heroStrike(true);
      } else {
        enemyStrike();
      }
      if (eHp <= 0) {
        heroWon = decided = true;
        break;
      }
      if (hHp <= 0) {
        decided = true;
        break;
      }
    }
    if (decided) break;
    if (eVenom > 0) {
      eHp -= eVenom;
      add(CombatKind.poison, 'Venom burns the ${enemy.name} for $eVenom.', eVenom);
      if (eHp <= 0) {
        heroWon = decided = true;
        break;
      }
    }
    if (hVenom > 0) {
      hHp -= hVenom;
      add(CombatKind.poison, 'Poison stings $kHeroName for $hVenom.', hVenom);
      if (hHp <= 0) decided = true;
    }
  }
  if (heroWon) {
    add(CombatKind.victory, '${enemy.name} is defeated!');
  } else {
    hHp = 0;
    add(CombatKind.defeat, '$kHeroName falls...');
  }
  return CombatReport(log, heroWon: heroWon, heroHpAfter: math.max(0, hHp), rounds: round);
}

// ------------------------------------------------------------------- world

/// What happened on one day, for the renderer and the journal.
class DayEvent {
  DayEvent(this.day, this.kind, this.text, {this.enemy, this.report, this.gold = 0, this.healed = 0});

  final int day;
  final DayKind kind;
  final String text;
  final QuestEnemy? enemy;
  final CombatReport? report;
  final int gold;
  final int healed;

  bool get isBattle => report != null;
}

class QuestWorld {
  QuestWorld({required this.seed, this.chapter = 1}) : assert(chapter >= 1) {
    schedule = scheduleFor(seed);
  }

  final int seed;
  final int chapter;
  final QuestHero hero = QuestHero();
  late final List<DayKind> schedule;

  int day = 0;
  int gold = 0;
  int camps = kStartCamps;
  int kills = 0;
  QuestPhase phase = QuestPhase.travelling;
  List<QuestOffer> offers = const [];
  List<ShopItem> shop = const [];
  DayEvent? lastEvent;
  String? deathCause;
  final List<String> journal = [];

  bool get isOver => phase == QuestPhase.won || phase == QuestPhase.lost;
  bool get won => phase == QuestPhase.won;
  bool get canAdvance => phase == QuestPhase.travelling && day < kChapterDays;

  /// Kind of the upcoming day, or null when the trail is done.
  DayKind? get nextKind => day < kChapterDays ? schedule[day] : null;
  bool get canCamp => canAdvance && camps > 0 && nextKind != DayKind.elite && nextKind != DayKind.boss;

  int get daysSurvived => phase == QuestPhase.lost ? day - 1 : day;
  int get score => daysSurvived * 10 + gold + (won ? kBossBonus * chapter : 0);

  /// Enemy strength multiplier for this chapter.
  double get chapterScale => 1 + 0.15 * (chapter - 1);

  /// Fixed 30-day itinerary: day 1 choice, day 2 battle, 15 elite, 30 boss,
  /// shops on days 14 and 29, the rest weighted random.
  static List<DayKind> scheduleFor(int seed) {
    final rng = math.Random(seed * 2654435 + 97);
    final days = <DayKind>[];
    for (var d = 1; d <= kChapterDays; d++) {
      DayKind k;
      if (d == 1) {
        k = DayKind.choice;
      } else if (d == 2) {
        k = DayKind.battle;
      } else if (d == kEliteDay) {
        k = DayKind.elite;
      } else if (d == kBossDay) {
        k = DayKind.boss;
      } else if (d == kEliteDay - 1 || d == kBossDay - 1) {
        k = DayKind.shop;
      } else {
        final r = rng.nextDouble();
        k = r < 0.44
            ? DayKind.battle
            : r < 0.54
            ? DayKind.treasure
            : r < 0.80
            ? DayKind.choice
            : r < 0.89
            ? DayKind.shop
            : DayKind.rest;
        // Never two non-battle "free" days of the same kind in a row.
        if (days.isNotEmpty && days.last == k && k != DayKind.battle) k = DayKind.battle;
      }
      days.add(k);
    }
    return days;
  }

  math.Random _dayRng(int d, int salt) => math.Random(seed * 1000003 + chapter * 7919 + d * 131 + salt);

  void _log(String s) {
    journal.add(s);
    if (journal.length > 80) journal.removeAt(0);
  }

  /// Every dawn the hero recovers [kDawnHeal] of max HP, plus Wayfarer's Tea.
  int _dawn() => hero.heal(math.max(1, (hero.maxHp * (kDawnHeal + hero.dawnHeal)).round()));

  /// Builds the foe for day [d] (deterministic per seed/chapter/day).
  QuestEnemy enemyFor(int d) {
    final kind = schedule[d - 1];
    final rng = _dayRng(d, 1);
    final s = chapterScale;
    final vary = 0.9 + rng.nextDouble() * 0.2;
    var hp = (20 + 5.0 * d) * s * vary;
    var atk = (4 + 0.5 * d) * s;
    var def = d ~/ 7;
    var speed = 3 + rng.nextInt(6);
    if (kind == DayKind.elite) {
      return QuestEnemy(
        name: kEliteName,
        species: 7,
        maxHp: (hp * 1.8).round(),
        atk: (atk * 1.15).round(),
        def: def + 2,
        speed: 6,
        trait: EnemyTrait.armored,
        crit: 0.08,
        rank: DayKind.elite,
      );
    }
    if (kind == DayKind.boss) {
      return QuestEnemy(
        name: kBosses[(chapter - 1) % kBosses.length],
        species: 2,
        maxHp: (hp * 1.8).round(),
        atk: (atk * 1.05).round(),
        def: def + 1,
        speed: 7,
        trait: EnemyTrait.venomous,
        crit: 0.1,
        rank: DayKind.boss,
      );
    }
    final species = rng.nextInt(kSpecies.length);
    final trait = d < 4 ? EnemyTrait.none : EnemyTrait.values[rng.nextInt(EnemyTrait.values.length)];
    switch (trait) {
      case EnemyTrait.armored:
        def += 2;
      case EnemyTrait.swift:
        speed += 4;
        atk *= 0.9;
      case EnemyTrait.brute:
        atk *= 1.2;
        hp *= 1.1;
        speed = math.max(1, speed - 2);
      case EnemyTrait.venomous:
        atk *= 0.85;
      case EnemyTrait.none:
        break;
    }
    return QuestEnemy(
      name: '${_traitWord[trait]}${kSpecies[species]}',
      species: species,
      maxHp: hp.round(),
      atk: atk.round(),
      def: def,
      speed: speed,
      trait: trait,
    );
  }

  /// Gold for beating a foe of day [d].
  int bountyFor(int d, DayKind kind) {
    if (kind == DayKind.boss) return 0;
    final base = kind == DayKind.elite ? 60 : 8 + d + _dayRng(d, 2).nextInt(6);
    return (base * hero.goldMult).round();
  }

  /// Three distinct offers for a choice day.
  List<QuestOffer> offersFor(int d) {
    final rng = _dayRng(d, 3);
    final skills = [
      for (final s in SkillId.values)
        if (hero.level(s) < kMaxSkillLevel) s,
    ];
    final blessings = [...Blessing.values];
    final out = <QuestOffer>[];
    var guard = 0;
    while (out.length < 3 && guard++ < 50) {
      final useBlessing = d > 1 && (skills.isEmpty || rng.nextDouble() < 0.28);
      if (useBlessing && blessings.isNotEmpty) {
        out.add(QuestOffer.blessing(blessings.removeAt(rng.nextInt(blessings.length))));
      } else if (skills.isNotEmpty) {
        out.add(QuestOffer.skill(skills.removeAt(rng.nextInt(skills.length))));
      }
    }
    return out;
  }

  /// Four wares for a shop day: always a tonic, plus three others.
  List<ShopItem> shopFor(int d) {
    final rng = _dayRng(d, 4);
    final infl = 1 + d / 60;
    int price(int p) => (p * infl).round();
    final pool = [ShopKind.whetstone, ShopKind.plating, ShopKind.elixir, ShopKind.tome]..shuffle(rng);
    final items = <ShopItem>[ShopItem(ShopKind.potion, price(22))];
    for (final k in pool.take(3)) {
      switch (k) {
        case ShopKind.whetstone:
          items.add(ShopItem(k, price(38)));
        case ShopKind.plating:
          items.add(ShopItem(k, price(34)));
        case ShopKind.elixir:
          items.add(ShopItem(k, price(40)));
        case ShopKind.tome:
          final learnable = [
            for (final s in SkillId.values)
              if (hero.level(s) < kMaxSkillLevel) s,
          ];
          if (learnable.isEmpty) {
            items.add(ShopItem(ShopKind.elixir, price(40)));
          } else {
            items.add(ShopItem(k, price(60), skill: learnable[rng.nextInt(learnable.length)]));
          }
        case ShopKind.potion:
          break;
      }
    }
    return items;
  }

  /// Walks to the next day and resolves its event. Returns null if the hero
  /// can't move (mid-choice, shopping, or the run is over).
  DayEvent? advanceDay() {
    if (!canAdvance) return null;
    day++;
    final healed = _dawn();
    final kind = schedule[day - 1];
    final DayEvent ev;
    switch (kind) {
      case DayKind.battle:
      case DayKind.elite:
      case DayKind.boss:
        ev = _battle(kind, healed);
      case DayKind.treasure:
        final rng = _dayRng(day, 5);
        final g = ((14 + day * 2 + rng.nextInt(12)) * hero.goldMult).round();
        gold += g;
        ev = DayEvent(day, kind, 'Found a mossy chest with $g gold.', gold: g, healed: healed);
      case DayKind.choice:
        offers = offersFor(day);
        phase = QuestPhase.choosing;
        ev = DayEvent(
          day,
          kind,
          day == 1 ? 'A roadside shrine offers a first gift.' : 'A fork in the trail. Choose a gift.',
          healed: healed,
        );
      case DayKind.shop:
        shop = shopFor(day);
        phase = QuestPhase.shopping;
        ev = DayEvent(day, kind, 'A snail peddler unrolls a mat of wares.', healed: healed);
      case DayKind.rest:
        final h = rest();
        ev = DayEvent(day, kind, 'A quiet glade. $kHeroName rests and recovers $h HP.', healed: healed + h);
    }
    lastEvent = ev;
    _log('Day $day: ${ev.text}');
    return ev;
  }

  /// Heals 40% of max HP. Returns HP restored.
  int rest() => hero.heal((hero.maxHp * 0.4).round());

  /// Spends a camp token: skips the next (non elite/boss) day's event and rests.
  DayEvent? camp() {
    if (!canCamp) return null;
    camps--;
    day++;
    final healed = _dawn() + rest();
    final ev = DayEvent(day, DayKind.rest, '$kHeroName makes camp and recovers $healed HP.', healed: healed);
    lastEvent = ev;
    _log('Day $day: ${ev.text}');
    return ev;
  }

  DayEvent _battle(DayKind kind, int healed) {
    final enemy = enemyFor(day);
    final report = simulateCombat(hero, enemy, _dayRng(day, 6));
    hero.hp = report.heroHpAfter;
    var bounty = 0;
    String text;
    if (report.heroWon) {
      kills++;
      // Every victory toughens the hero a little.
      hero.baseAtk += 1;
      hero.baseMaxHp += 4;
      hero.hp += 4;
      bounty = bountyFor(day, kind);
      gold += bounty;
      if (kind == DayKind.boss) {
        phase = QuestPhase.won;
        text = '${enemy.name} is vanquished! Chapter $chapter complete.';
      } else {
        text = 'Defeated ${enemy.name} in ${report.rounds} rounds (+$bounty gold).';
      }
    } else {
      phase = QuestPhase.lost;
      deathCause = enemy.name;
      text = '$kHeroName fell to ${enemy.name}.';
    }
    return DayEvent(day, kind, text, enemy: enemy, report: report, gold: bounty, healed: healed);
  }

  /// Picks offer [index] on a choice day.
  bool choose(int index) {
    if (phase != QuestPhase.choosing || index < 0 || index >= offers.length) return false;
    final o = offers[index];
    if (o.isSkill) {
      hero.learn(o.skill!);
      _log('  Learned ${o.name} (lv ${hero.level(o.skill!)}).');
    } else {
      applyBlessing(o.blessing!);
      _log('  Received ${o.name}.');
    }
    offers = const [];
    phase = QuestPhase.travelling;
    return true;
  }

  void applyBlessing(Blessing b) {
    switch (b) {
      case Blessing.hearth:
        hero.heal((hero.maxHp * 0.6).round());
      case Blessing.whetstone:
        hero.baseAtk += 3;
      case Blessing.ironOath:
        hero.baseDef += 2;
      case Blessing.giantsBrew:
        hero.baseMaxHp += 25;
        hero.hp += 25;
      case Blessing.goldCache:
        gold += 40;
    }
  }

  /// Buys shop item [index]. Fails (false) when not shopping, sold out, or too poor.
  bool buy(int index) {
    if (phase != QuestPhase.shopping || index < 0 || index >= shop.length) return false;
    final item = shop[index];
    if (item.sold || gold < item.price) return false;
    gold -= item.price;
    item.sold = true;
    switch (item.kind) {
      case ShopKind.potion:
        hero.heal((hero.maxHp * 0.5).round());
      case ShopKind.whetstone:
        hero.baseAtk += 2;
      case ShopKind.plating:
        hero.baseDef += 1;
      case ShopKind.elixir:
        hero.baseMaxHp += 15;
        hero.hp += 15;
      case ShopKind.tome:
        hero.learn(item.skill!);
    }
    _log('  Bought ${item.name} for ${item.price} gold.');
    return true;
  }

  bool leaveShop() {
    if (phase != QuestPhase.shopping) return false;
    shop = const [];
    phase = QuestPhase.travelling;
    return true;
  }
}
