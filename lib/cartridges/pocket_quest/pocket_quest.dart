import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../yantrasobi/adapters/widget_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import 'quest_world.dart';

class PocketQuestCartridge extends WidgetCartridge {
  const PocketQuestCartridge({this.seed});

  /// Fixed run seed for tests/tools; null = a fresh random trail each run.
  final int? seed;

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'pocket-quest',
    title: 'Pocket Quest',
    tagline: 'Thirty days on the trail. One tiny tortoise knight.',
    description:
        'A day-by-day auto-adventure. Moss the tortoise knight walks the trail on his own; '
        'you decide what he learns. Battles resolve blow by blow, shrines offer three gifts, '
        'peddlers sell wares, and stacked skills spark synergies. Survive the elite on day 15 '
        'and topple the boss on day 30 to open the next, harder chapter.',
    genre: 'Roguelike auto-adventure',
    engine: CartridgeEngine.widgets,
    version: '1.0.0',
    accent: Color(0xFF9CCC65),
    icon: Icons.explore_rounded,
    tags: ['roguelike', 'rpg', 'auto-battle', 'builds', 'text', 'hybrid-casual'],
    controls: [
      'Tap NEXT DAY to walk one day along the trail',
      'Tap a gift card to choose it; tap BUY on a ware to purchase it',
      'CAMP skips the next ordinary day to heal (3 per chapter)',
      'Tap SKIP FIGHT to jump to the end of a battle',
    ],
    mechanics: ['auto-battle', 'skill stacking', 'synergies', 'shop', 'daily events', 'chapters'],
    goal: 'Survive 30 days and defeat the boss on day 30. Each cleared chapter unlocks a harder one.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  Widget buildGame(BuildContext context, WidgetCartridgeSession session) =>
      PocketQuestGame(session: session, seed: seed);
}

// -------------------------------------------------------------- palette

const Color _bg = Color(0xFF132019);
const Color _panel = Color(0xFF1E2F25);
const Color _panelHi = Color(0xFF29402F);
const Color _moss = Color(0xFF9CCC65);
const Color _gold = Color(0xFFFFC857);
const Color _foeRed = Color(0xFFE8615A);
const Color _venom = Color(0xFFB67CFF);
const Color _ink = Color(0xFFE9F1E4);
const Color _muted = Color(0xFF9DB3A1);

const List<Color> _speciesColors = [
  Color(0xFFB98B5E),
  Color(0xFF7FD3E6),
  Color(0xFF6E9E4A),
  Color(0xFFC0643A),
  Color(0xFF8E5A8F),
  Color(0xFFB7B0A2),
  Color(0xFF9C4B3B),
  Color(0xFF5C7F9E),
  Color(0xFFA88B59),
  Color(0xFF3F7F7A),
];

IconData skillIcon(SkillId id) => switch (id) {
  SkillId.sharpBlade => Icons.hardware_rounded,
  SkillId.keenEye => Icons.visibility_rounded,
  SkillId.twinStrike => Icons.call_split_rounded,
  SkillId.venomEdge => Icons.science_rounded,
  SkillId.executioner => Icons.gps_fixed_rounded,
  SkillId.emberHeart => Icons.local_fire_department_rounded,
  SkillId.leechFang => Icons.bloodtype_rounded,
  SkillId.barkWard => Icons.shield_rounded,
  SkillId.brambleShell => Icons.grass_rounded,
  SkillId.stoneSkin => Icons.landscape_rounded,
  SkillId.vigor => Icons.favorite_rounded,
  SkillId.quickstep => Icons.directions_run_rounded,
  SkillId.wayfarerTea => Icons.local_cafe_rounded,
  SkillId.luckyCoin => Icons.monetization_on_rounded,
};

IconData blessingIcon(Blessing b) => switch (b) {
  Blessing.hearth => Icons.fireplace_rounded,
  Blessing.whetstone => Icons.auto_fix_high_rounded,
  Blessing.ironOath => Icons.security_rounded,
  Blessing.giantsBrew => Icons.local_drink_rounded,
  Blessing.goldCache => Icons.savings_rounded,
};

IconData shopIcon(ShopKind k) => switch (k) {
  ShopKind.potion => Icons.healing_rounded,
  ShopKind.whetstone => Icons.hardware_rounded,
  ShopKind.plating => Icons.security_rounded,
  ShopKind.elixir => Icons.favorite_border_rounded,
  ShopKind.tome => Icons.menu_book_rounded,
};

IconData dayIcon(DayKind k) => switch (k) {
  DayKind.battle => Icons.flash_on_rounded,
  DayKind.treasure => Icons.inventory_2_rounded,
  DayKind.choice => Icons.alt_route_rounded,
  DayKind.shop => Icons.storefront_rounded,
  DayKind.rest => Icons.nights_stay_rounded,
  DayKind.elite => Icons.whatshot_rounded,
  DayKind.boss => Icons.dangerous_rounded,
};

String dayLabel(DayKind k) => switch (k) {
  DayKind.battle => 'Battle',
  DayKind.treasure => 'Treasure',
  DayKind.choice => 'Shrine',
  DayKind.shop => 'Peddler',
  DayKind.rest => 'Glade',
  DayKind.elite => 'Elite foe',
  DayKind.boss => 'Chapter boss',
};

Color dayColor(DayKind k) => switch (k) {
  DayKind.battle => _foeRed,
  DayKind.treasure => _gold,
  DayKind.choice => _moss,
  DayKind.shop => const Color(0xFF7FB8FF),
  DayKind.rest => const Color(0xFF8FA0C8),
  DayKind.elite => const Color(0xFFFF8A3D),
  DayKind.boss => const Color(0xFFFF4F7B),
};

// ----------------------------------------------------------------- game

class PocketQuestGame extends StatefulWidget {
  const PocketQuestGame({super.key, required this.session, this.seed});

  final WidgetCartridgeSession session;
  final int? seed;

  @override
  State<PocketQuestGame> createState() => PocketQuestGameState();
}

class PocketQuestGameState extends State<PocketQuestGame> {
  /// Time between revealed combat rounds.
  static const Duration roundTick = Duration(milliseconds: 400);

  late final QuestWorld world;
  Timer? _timer;
  CombatReport? _battle;
  QuestEnemy? _foe;
  int _shown = 0;
  bool _ended = false;

  WidgetCartridgeSession get _session => widget.session;
  AsobiAudio get _audio => _session.context.audio;
  bool get _paused => _session.paused.value;

  /// True while a combat log is still being revealed.
  bool get animating => _battle != null && _shown < _battle!.entries.length;

  /// Number of combat entries revealed so far (for tests and the perf overlay).
  int get revealed => _shown;

  /// Whether the round timer is currently scheduled.
  bool get timerActive => _timer?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    final chapter = math.max(1, _session.context.save.intData('chapter', 1));
    world = QuestWorld(seed: widget.seed ?? math.Random().nextInt(1 << 31), chapter: chapter);
    _session.paused.addListener(_onPausedChanged);
    _syncEntities();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _session.paused.removeListener(_onPausedChanged);
    super.dispose();
  }

  void _syncEntities() {
    final combatants = 1 + (_battle != null ? 1 : 0);
    final log = _battle != null ? _shown : world.journal.length;
    _session.entityCount = combatants + log + world.offers.length + world.shop.length;
  }

  void _update(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _syncEntities();
  }

  // --------------------------------------------------------------- timer

  void _onPausedChanged() {
    if (_paused) {
      _timer?.cancel();
      _timer = null;
    } else {
      _ensureTimer();
    }
  }

  bool get _needsTicks => animating || (world.isOver && !_ended);

  void _ensureTimer() {
    if (_timer != null || _paused || !mounted || !_needsTicks) return;
    _timer = Timer.periodic(roundTick, (_) => _tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    if (!mounted || _paused) {
      _stopTimer();
      return;
    }
    if (animating) {
      final entries = _battle!.entries;
      final round = entries[_shown].round;
      final before = _shown;
      _update(() {
        while (_shown < entries.length && entries[_shown].round == round) {
          _shown++;
        }
      });
      _soundFor(entries.sublist(before, _shown));
      if (!animating) _afterBattle();
      if (!_needsTicks) _stopTimer();
      return;
    }
    if (world.isOver && !_ended) {
      _stopTimer();
      _finishRun();
      return;
    }
    _stopTimer();
  }

  void _soundFor(List<CombatEntry> revealed) {
    final kinds = revealed.map((e) => e.kind).toSet();
    if (kinds.contains(CombatKind.heroCrit)) {
      _audio.play(Sfx.hit);
      _audio.haptic(HapticKind.medium);
    } else if (kinds.contains(CombatKind.enemyHit) || kinds.contains(CombatKind.enemyCrit)) {
      _audio.play(Sfx.thud);
    } else if (kinds.contains(CombatKind.heroHit)) {
      _audio.play(Sfx.tap);
    }
    if (kinds.contains(CombatKind.heal)) _audio.play(Sfx.pop);
  }

  void _afterBattle() {
    final report = _battle!;
    if (report.heroWon) {
      _audio.play(world.won ? Sfx.win : Sfx.coin);
    } else {
      _audio.play(Sfx.lose);
      _audio.haptic(HapticKind.heavy);
    }
  }

  // ------------------------------------------------------------- actions

  void _onNext() {
    if (_paused || _ended) return;
    if (animating) {
      _skipFight();
      return;
    }
    if (world.phase == QuestPhase.shopping) {
      _leaveShop();
      return;
    }
    if (!world.canAdvance) return;
    final ev = world.advanceDay();
    if (ev == null) return;
    _update(() {
      if (ev.isBattle) {
        _battle = ev.report;
        _foe = ev.enemy;
        _shown = ev.report!.entries.where((e) => e.round == 0).length;
      } else {
        _battle = null;
        _foe = null;
        _shown = 0;
      }
    });
    switch (ev.kind) {
      case DayKind.battle:
      case DayKind.elite:
      case DayKind.boss:
        _audio.play(Sfx.whoosh);
      case DayKind.treasure:
        _audio.play(Sfx.coin);
      case DayKind.choice:
        _audio.play(Sfx.powerup);
      case DayKind.shop:
        _audio.play(Sfx.pop);
      case DayKind.rest:
        _audio.play(Sfx.merge);
    }
    _ensureTimer();
  }

  void _skipFight() {
    if (!animating) return;
    _audio.play(Sfx.whoosh);
    _update(() => _shown = _battle!.entries.length);
    _afterBattle();
    _ensureTimer();
  }

  void _onCamp() {
    if (_paused || animating || !world.canCamp) return;
    world.camp();
    _audio.play(Sfx.merge);
    _update(() {
      _battle = null;
      _foe = null;
    });
  }

  void _choose(int i) {
    if (_paused || !world.choose(i)) return;
    _audio.play(Sfx.powerup);
    _audio.haptic(HapticKind.selection);
    _update(() {});
  }

  void _buy(int i) {
    if (_paused) return;
    if (world.buy(i)) {
      _audio.play(Sfx.coin);
      _update(() {});
    } else {
      _audio.play(Sfx.thud);
      _audio.haptic();
    }
  }

  void _leaveShop() {
    if (world.leaveShop()) {
      _audio.play(Sfx.tap);
      _update(() {});
    }
  }

  void _finishRun() {
    if (_ended) return;
    _ended = true;
    final save = _session.context.save;
    if (world.won) {
      save.data['chapter'] = world.chapter + 1;
      _session.context.commitSave();
    }
    final headline = world.won
        ? 'Chapter ${world.chapter} cleared - ${world.lastEvent?.enemy?.name ?? 'the boss'} falls!'
        : 'Moss fell on day ${world.day} to ${world.deathCause ?? 'the wilds'}';
    _session.end(
      RunResult(
        score: world.score,
        won: world.won,
        headline: headline,
        details: {
          'Chapter': '${world.chapter}',
          'Days': '${world.daysSurvived}/$kChapterDays',
          'Foes defeated': '${world.kills}',
          'Gold': '${world.gold}',
          'Build': world.hero.buildSummary,
        },
      ),
    );
    _update(() {});
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Material(
      color: _bg,
      child: Padding(
        padding: EdgeInsets.only(
          top: mq.padding.top,
          bottom: mq.padding.bottom + 10,
          left: mq.padding.left + 12,
          right: mq.padding.right + 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 64, child: _header()),
            _trail(),
            const SizedBox(height: 8),
            _heroCard(),
            const SizedBox(height: 8),
            Expanded(child: _middle()),
            const SizedBox(height: 10),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      // Leaves room for the host's pause button in the top-left corner.
      padding: const EdgeInsets.only(left: 60),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CHAPTER ${world.chapter}',
                  style: const TextStyle(
                    color: _moss,
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Day ${world.day} / $kChapterDays',
                    key: const Key('pq-day'),
                    maxLines: 1,
                    style: const TextStyle(color: _ink, fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
          _chip(Icons.monetization_on_rounded, '${world.gold}', _gold, key: const Key('pq-gold')),
          const SizedBox(width: 6),
          _chip(Icons.nights_stay_rounded, '${world.camps}', const Color(0xFF8FA0C8)),
        ],
      ),
    );
  }

  Widget _trail() {
    final next = world.nextKind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 18, child: CustomPaint(painter: _TrailPainter(world.schedule, world.day))),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(next == null ? Icons.flag_rounded : dayIcon(next), size: 14, color: _muted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                next == null ? 'The trail ends here.' : 'Tomorrow: ${dayLabel(next)}',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _heroCard() {
    final h = world.hero;
    final last = _battle != null && _shown > 0 ? _battle!.entries[_shown - 1] : null;
    final hp = last?.heroHp ?? h.hp;
    final shield = last?.shield ?? 0;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(width: 58, height: 50, child: CustomPaint(painter: TortoisePainter())),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '$kHeroName, tortoise knight',
                      style: TextStyle(color: _ink, fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    _HpBar(
                      value: hp,
                      max: h.maxHp,
                      shield: shield,
                      color: _moss,
                      key: const Key('pq-hero-hp'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _chip(Icons.flash_on_rounded, 'ATK ${h.atk}', const Color(0xFFFF9F68)),
              _chip(Icons.shield_rounded, 'DEF ${h.def}', const Color(0xFF7FB8FF)),
              _chip(Icons.gps_fixed_rounded, 'CRIT ${(h.critChance * 100).round()}%', _gold),
              _chip(Icons.speed_rounded, 'SPD ${h.speed}', const Color(0xFF8FE3C0)),
            ],
          ),
          if (h.skills.isNotEmpty || h.synergies.isNotEmpty) ...[
            const SizedBox(height: 6),
            // Big builds scroll inside the card instead of squeezing the log.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 82),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in h.skills.entries) _skillChip(e.key, e.value),
                    for (final s in h.synergies) _synergyChip(s),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _middle() {
    final Widget child;
    if (world.phase == QuestPhase.choosing) {
      child = _choices();
    } else if (world.phase == QuestPhase.shopping) {
      child = _shop();
    } else if (_battle != null) {
      child = _battleView();
    } else {
      child = _journal();
    }
    return Container(
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.all(10),
      child: child,
    );
  }

  Widget _title(String text, IconData icon, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14),
          ),
        ),
      ],
    ),
  );

  Widget _journal() {
    final entries = world.journal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title('Trail journal', Icons.menu_book_rounded, _moss),
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text(
                    'Moss tightens his shell straps.\nTap NEXT DAY to set out.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted, fontSize: 14, height: 1.4),
                  ),
                )
              : ListView.builder(
                  key: const Key('pq-journal'),
                  reverse: true,
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final line = entries[entries.length - 1 - i];
                    final sub = line.startsWith('  ');
                    return Padding(
                      padding: EdgeInsets.only(left: sub ? 14 : 0, bottom: 4),
                      child: Text(
                        line.trim(),
                        style: TextStyle(color: sub ? _moss : _ink, fontSize: 13, height: 1.3),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _battleView() {
    final report = _battle!;
    final foe = _foe!;
    final last = _shown > 0 ? report.entries[_shown - 1] : null;
    final foeHp = last?.enemyHp ?? foe.maxHp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 54,
              height: 46,
              child: CustomPaint(painter: MonsterPainter(foe, defeated: foeHp <= 0)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    foe.name,
                    style: TextStyle(
                      color: foe.rank == DayKind.battle ? _ink : dayColor(foe.rank),
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'ATK ${foe.atk}  DEF ${foe.def}  SPD ${foe.speed}',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  _HpBar(value: foeHp, max: foe.maxHp, color: _foeRed, key: const Key('pq-foe-hp')),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            key: const Key('pq-combat-log'),
            reverse: true,
            itemCount: _shown,
            itemBuilder: (context, i) => _logLine(report.entries[_shown - 1 - i]),
          ),
        ),
      ],
    );
  }

  Widget _logLine(CombatEntry e) {
    final (IconData icon, Color color) = switch (e.kind) {
      CombatKind.heroHit => (Icons.flash_on_rounded, _ink),
      CombatKind.heroCrit => (Icons.auto_awesome_rounded, _gold),
      CombatKind.enemyHit => (Icons.south_rounded, const Color(0xFFF2A39D)),
      CombatKind.enemyCrit => (Icons.priority_high_rounded, _foeRed),
      CombatKind.dodge => (Icons.directions_run_rounded, const Color(0xFF8FE3C0)),
      CombatKind.heal => (Icons.favorite_rounded, _moss),
      CombatKind.shield => (Icons.shield_rounded, const Color(0xFF7FB8FF)),
      CombatKind.thorns => (Icons.grass_rounded, const Color(0xFFB5D96B)),
      CombatKind.poison => (Icons.science_rounded, _venom),
      CombatKind.victory => (Icons.emoji_events_rounded, _gold),
      CombatKind.defeat => (Icons.heart_broken_rounded, _foeRed),
      CombatKind.info => (Icons.info_outline_rounded, _muted),
    };
    final strong = e.kind == CombatKind.victory || e.kind == CombatKind.defeat;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              e.round == 0 ? '' : 'R${e.round}',
              style: const TextStyle(color: _muted, fontSize: 10),
            ),
          ),
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              e.text,
              style: TextStyle(
                color: color,
                fontSize: strong ? 14 : 12.5,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choices() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(world.lastEvent?.text ?? 'Choose a gift', Icons.alt_route_rounded, _moss),
        Expanded(
          child: ListView(
            children: [for (var i = 0; i < world.offers.length; i++) _offerCard(i, world.offers[i])],
          ),
        ),
      ],
    );
  }

  Widget _offerCard(int i, QuestOffer o) {
    final h = world.hero;
    final String sub;
    final String effect;
    final IconData icon;
    final Color color;
    if (o.isSkill) {
      final lv = h.level(o.skill!);
      sub = lv == 0 ? 'New skill' : 'Level $lv -> ${lv + 1}';
      effect = describeSkill(o.skill!, lv + 1);
      icon = skillIcon(o.skill!);
      color = o.isDamage ? const Color(0xFFFF9F68) : const Color(0xFF7FB8FF);
    } else {
      sub = 'Blessing';
      effect = kBlessings[o.blessing]!.text;
      icon = blessingIcon(o.blessing!);
      color = _gold;
    }
    final synergy = o.isSkill ? _synergyHint(o.skill!) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _panelHi,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: Key('pq-choice-$i'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => _choose(i),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.18), shape: BoxShape.circle),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        o.name,
                        style: const TextStyle(color: _ink, fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        sub,
                        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(effect, style: const TextStyle(color: _ink, fontSize: 12.5)),
                      if (synergy != null)
                        Text(
                          synergy,
                          style: const TextStyle(color: _gold, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Unlocks Deadeye" when picking [id] would complete a synergy pair.
  String? _synergyHint(SkillId id) {
    final h = world.hero;
    if (h.level(id) > 0) return null;
    for (final e in kSynergies.entries) {
      final def = e.value;
      if ((def.a == id && h.level(def.b) > 0) || (def.b == id && h.level(def.a) > 0)) {
        return 'Unlocks ${def.name}: ${def.text}';
      }
    }
    return null;
  }

  Widget _shop() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title('Snail peddler - spend your gold', Icons.storefront_rounded, const Color(0xFF7FB8FF)),
        Expanded(
          child: ListView(children: [for (var i = 0; i < world.shop.length; i++) _shopRow(i, world.shop[i])]),
        ),
      ],
    );
  }

  Widget _shopRow(int i, ShopItem item) {
    final affordable = !item.sold && world.gold >= item.price;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: _panelHi, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Icon(shopIcon(item.kind), color: item.sold ? _muted : const Color(0xFF7FB8FF)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: TextStyle(
                      color: item.sold ? _muted : _ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      decoration: item.sold ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(item.text, style: const TextStyle(color: _muted, fontSize: 11.5)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: Key('pq-buy-$i'),
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: const Color(0xFF3A2A00),
                disabledBackgroundColor: const Color(0xFF3A4A3F),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 36),
              ),
              onPressed: affordable ? () => _buy(i) : null,
              icon: const Icon(Icons.monetization_on_rounded, size: 16),
              label: Text(item.sold ? 'Sold' : '${item.price}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final String label;
    final IconData icon;
    VoidCallback? onPressed = _onNext;
    if (animating) {
      label = 'SKIP FIGHT';
      icon = Icons.fast_forward_rounded;
    } else if (world.isOver) {
      label = world.won ? 'VICTORY' : 'JOURNEY ENDS';
      icon = world.won ? Icons.emoji_events_rounded : Icons.heart_broken_rounded;
      onPressed = null;
    } else if (world.phase == QuestPhase.choosing) {
      label = 'CHOOSE A GIFT';
      icon = Icons.touch_app_rounded;
      onPressed = null;
    } else if (world.phase == QuestPhase.shopping) {
      label = 'LEAVE SHOP';
      icon = Icons.logout_rounded;
    } else {
      label = 'NEXT DAY';
      icon = Icons.directions_walk_rounded;
    }
    final canCamp = !animating && world.canCamp;
    return SizedBox(
      height: 64,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(
            key: const Key('pq-camp'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB9C6E8),
              side: BorderSide(
                color: canCamp ? const Color(0xFF8FA0C8) : const Color(0xFF34443A),
                width: 1.5,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: canCamp ? _onCamp : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.nights_stay_rounded, size: 20),
                Text(
                  'CAMP ${world.camps}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              key: const Key('pq-next'),
              style: FilledButton.styleFrom(
                backgroundColor: _moss,
                foregroundColor: const Color(0xFF14240C),
                disabledBackgroundColor: const Color(0xFF34443A),
                disabledForegroundColor: _muted,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.5),
              ),
              onPressed: onPressed,
              icon: Icon(icon, size: 26),
              label: Text(label),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text, Color color, {Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _skillChip(SkillId id, int level) {
    final dmg = kSkills[id]!.damage;
    final color = dmg ? const Color(0xFFFF9F68) : const Color(0xFF7FB8FF);
    return Tooltip(
      message: describeSkill(id, level),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: _panelHi, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(skillIcon(id), size: 13, color: color),
            const SizedBox(width: 4),
            Text(kSkills[id]!.name, style: const TextStyle(color: _ink, fontSize: 11)),
            const SizedBox(width: 4),
            Text(
              'Lv$level',
              style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Widget _synergyChip(Synergy s) {
    final def = kSynergies[s]!;
    return Tooltip(
      message: def.text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _gold.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_rounded, size: 13, color: _gold),
            const SizedBox(width: 4),
            Text(
              def.name,
              style: const TextStyle(color: _gold, fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- widgets

class _HpBar extends StatelessWidget {
  const _HpBar({super.key, required this.value, required this.max, required this.color, this.shield = 0});

  final int value;
  final int max;
  final int shield;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final f = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    final s = max <= 0 ? 0.0 : (shield / max).clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 12,
            decoration: BoxDecoration(color: const Color(0xFF0D1611), borderRadius: BorderRadius.circular(6)),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 220),
                  widthFactor: f,
                  heightFactor: 1,
                  alignment: Alignment.centerLeft,
                  child: Container(color: f < 0.3 ? _foeRed : color),
                ),
                if (s > 0)
                  FractionallySizedBox(
                    widthFactor: s,
                    heightFactor: 0.4,
                    alignment: Alignment.topLeft,
                    child: Container(color: const Color(0xFF7FB8FF)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              shield > 0 ? '$value/$max +$shield' : '$value/$max',
              maxLines: 1,
              style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

/// The 30-day trail as a dotted path; elite and boss days are larger marks.
class _TrailPainter extends CustomPainter {
  _TrailPainter(this.schedule, this.day);

  final List<DayKind> schedule;
  final int day;

  @override
  void paint(Canvas canvas, Size size) {
    final n = schedule.length;
    if (n == 0 || size.width <= 0) return;
    final step = size.width / n;
    final cy = size.height / 2;
    canvas.drawLine(
      Offset(step / 2, cy),
      Offset(size.width - step / 2, cy),
      Paint()
        ..color = const Color(0xFF2E4636)
        ..strokeWidth = 2,
    );
    for (var i = 0; i < n; i++) {
      final d = i + 1;
      final k = schedule[i];
      final big = k == DayKind.elite || k == DayKind.boss;
      final c = Offset(step * i + step / 2, cy);
      final past = d <= day;
      final r = big ? math.min(step * 0.48, 7.0) : math.min(step * 0.3, 4.0);
      final color = past ? _moss : (big || d == day + 1 ? dayColor(k) : const Color(0xFF3F5A47));
      canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: past ? 0.55 : 1));
      if (d == day) {
        canvas.drawCircle(
          c,
          r + 3,
          Paint()
            ..color = _ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TrailPainter old) => old.day != day || old.schedule != schedule;
}

/// Moss: a domed, plated shell, a stubby head under a plumed helm and a tiny sword.
class TortoisePainter extends CustomPainter {
  const TortoisePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final skin = Paint()..color = const Color(0xFF8BC48A);
    final dark = Paint()..color = const Color(0xFF2F5A3A);
    // Feet.
    for (final fx in [0.22, 0.62]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(w * fx, h * 0.74, w * 0.14, h * 0.2), const Radius.circular(4)),
        skin,
      );
    }
    // Sword behind.
    final blade = Paint()
      ..color = const Color(0xFFDDE6EA)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.06, h * 0.78), Offset(w * 0.02, h * 0.2), blade);
    canvas.drawLine(
      Offset(w * -0.02, h * 0.66),
      Offset(w * 0.15, h * 0.66),
      Paint()
        ..color = _gold
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // Shell dome.
    final shell = Rect.fromLTWH(w * 0.1, h * 0.28, w * 0.66, h * 0.6);
    final shellPath = Path()
      ..moveTo(shell.left, shell.bottom)
      ..arcTo(Rect.fromLTWH(shell.left, shell.top, shell.width, shell.height * 2), math.pi, math.pi, false)
      ..close();
    canvas.drawPath(shellPath, Paint()..color = const Color(0xFF5E8F3E));
    canvas.save();
    canvas.clipPath(shellPath);
    final plate = Paint()
      ..color = const Color(0xFF3D6B2B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (var i = 0; i < 3; i++) {
      final cx = shell.left + shell.width * (0.22 + 0.28 * i);
      canvas.drawCircle(Offset(cx, shell.top + shell.height * 0.6), shell.width * 0.15, plate);
    }
    canvas.restore();
    canvas.drawRect(
      Rect.fromLTWH(shell.left - 2, shell.bottom - 4, shell.width + 4, 5),
      Paint()..color = const Color(0xFFC9A66B),
    );
    // Head + helm.
    final head = Offset(w * 0.84, h * 0.5);
    canvas.drawCircle(head, h * 0.17, skin);
    canvas.drawArc(
      Rect.fromCircle(center: head, radius: h * 0.19),
      math.pi * 1.05,
      math.pi * 0.95,
      true,
      Paint()..color = const Color(0xFFB8C4CC),
    );
    canvas.drawCircle(Offset(head.dx + h * 0.06, head.dy + h * 0.02), h * 0.035, dark);
    final plume = Path()
      ..moveTo(head.dx - h * 0.04, head.dy - h * 0.18)
      ..quadraticBezierTo(head.dx - h * 0.2, head.dy - h * 0.42, head.dx - h * 0.3, head.dy - h * 0.22)
      ..quadraticBezierTo(head.dx - h * 0.16, head.dy - h * 0.26, head.dx - h * 0.04, head.dy - h * 0.18);
    canvas.drawPath(plume, Paint()..color = _foeRed);
  }

  @override
  bool shouldRepaint(TortoisePainter oldDelegate) => false;
}

/// A procedural trail creature: a blob body coloured by species, with spikes,
/// plates or fangs depending on its trait, and a crown for the boss.
class MonsterPainter extends CustomPainter {
  MonsterPainter(this.enemy, {this.defeated = false});

  final QuestEnemy enemy;
  final bool defeated;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final base = _speciesColors[enemy.species % _speciesColors.length];
    final body = Paint()..color = defeated ? const Color(0xFF4A524C) : base;
    final center = Offset(w / 2, h * 0.6);
    final rx = w * 0.4;
    final ry = h * 0.36;
    if (enemy.trait == EnemyTrait.brute || enemy.rank != DayKind.battle) {
      final spike = Paint()..color = Color.lerp(base, Colors.black, 0.35)!;
      for (var i = 0; i < 5; i++) {
        final a = math.pi * (1.1 + 0.2 * i);
        final p = Path()
          ..moveTo(center.dx + math.cos(a - 0.15) * rx, center.dy + math.sin(a - 0.15) * ry)
          ..lineTo(center.dx + math.cos(a) * rx * 1.3, center.dy + math.sin(a) * ry * 1.35)
          ..lineTo(center.dx + math.cos(a + 0.15) * rx, center.dy + math.sin(a + 0.15) * ry)
          ..close();
        canvas.drawPath(p, spike);
      }
    }
    canvas.drawOval(Rect.fromCenter(center: center, width: rx * 2, height: ry * 2), body);
    if (enemy.trait == EnemyTrait.armored) {
      canvas.drawArc(
        Rect.fromCenter(center: center, width: rx * 2, height: ry * 2),
        math.pi,
        math.pi,
        false,
        Paint()
          ..color = const Color(0xFFB8C4CC)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    if (enemy.trait == EnemyTrait.venomous) {
      final drip = Paint()..color = _venom;
      canvas.drawCircle(Offset(center.dx - rx * 0.4, center.dy + ry * 0.95), 2.5, drip);
      canvas.drawCircle(Offset(center.dx + rx * 0.3, center.dy + ry * 1.05), 2, drip);
    }
    // Eyes.
    final eyeY = center.dy - ry * 0.2;
    for (final dx in [-0.35, 0.35]) {
      final e = Offset(center.dx + rx * dx, eyeY);
      if (defeated) {
        final x = Paint()
          ..color = Colors.black
          ..strokeWidth = 2;
        canvas.drawLine(e.translate(-3, -3), e.translate(3, 3), x);
        canvas.drawLine(e.translate(-3, 3), e.translate(3, -3), x);
      } else {
        canvas.drawCircle(e, 4.5, Paint()..color = Colors.white);
        canvas.drawCircle(e.translate(dx > 0 ? -1 : 1, 1), 2.2, Paint()..color = Colors.black);
      }
    }
    // Fangs.
    final fang = Paint()..color = Colors.white;
    for (final dx in [-0.15, 0.15]) {
      final x = center.dx + rx * dx;
      final y = center.dy + ry * 0.3;
      canvas.drawPath(
        Path()
          ..moveTo(x - 3, y)
          ..lineTo(x + 3, y)
          ..lineTo(x, y + 6)
          ..close(),
        fang,
      );
    }
    if (enemy.rank == DayKind.boss) {
      final crown = Path()
        ..moveTo(center.dx - 12, center.dy - ry - 2)
        ..lineTo(center.dx - 12, center.dy - ry - 12)
        ..lineTo(center.dx - 5, center.dy - ry - 6)
        ..lineTo(center.dx, center.dy - ry - 14)
        ..lineTo(center.dx + 5, center.dy - ry - 6)
        ..lineTo(center.dx + 12, center.dy - ry - 12)
        ..lineTo(center.dx + 12, center.dy - ry - 2)
        ..close();
      canvas.drawPath(crown, Paint()..color = _gold);
    }
  }

  @override
  bool shouldRepaint(MonsterPainter old) => old.enemy != enemy || old.defeated != defeated;
}
