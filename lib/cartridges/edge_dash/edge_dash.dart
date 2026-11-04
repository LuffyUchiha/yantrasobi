import 'dart:math' as math;
import 'dart:ui';

import 'package:asobi_party/asobi_party.dart' show MultiplayerSpec, SyncModel;

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'dash_world.dart';

class EdgeDashCartridge extends FlameCartridge<EdgeDashGame> {
  const EdgeDashCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'edge-dash',
    title: 'Edge Dash',
    tagline: 'One swipe. One line. Everything on it falls.',
    description:
        'An ink-brush slicing arena. Your lantern ronin stands perfectly still until you '
        'swipe, then dashes instantly along that line and cuts down every foe it crosses. '
        'Dodge arrows, flank shieldbearers, stay out of bomber blasts and chain dashes '
        'for combo multipliers through twelve waves and a spinning-eye boss.',
    genre: 'Swipe-to-dash slicer',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFD1345B),
    icon: Icons.content_cut_rounded,
    tags: ['action', 'arena', 'swipe', 'waves', 'boss'],
    controls: [
      'Swipe anywhere: dash along the swipe and slice everything on the line',
      'Longer swipes dash farther (up to 40% of the screen)',
    ],
    mechanics: [
      'instant dash',
      'line slicing',
      'combo multiplier',
      'shield angles',
      'waves',
      'boss weak spot',
    ],
    goal: 'Survive 12 waves with 3 hearts, then cut the boss through its glowing weak spot.',
    multiplayer: MultiplayerSpec(
      sync: SyncModel.parallel,
      maxPlayers: 8,
      summary: 'Same course for everyone; highest score wins',
    ),
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  EdgeDashGame createGame(FlameCartridgeSession<EdgeDashGame> session) =>
      EdgeDashGame(session, seed: session.context.matchSeed);
}

// Ink palette.
const Color _paper = Color(0xFFEDE3CC);
const Color _paperShade = Color(0xFFD9CBAE);
const Color _ink = Color(0xFF1E1A18);
const Color _vermilion = Color(0xFFC8322B);
const Color _gold = Color(0xFFE7B43C);
const Color _lantern = Color(0xFFFF9A3C);

class _Trail {
  double x1 = 0, y1 = 0, x2 = 0, y2 = 0, age = 1;
  bool kill = false;
}

class EdgeDashGame extends AsobiFlameGame {
  EdgeDashGame(super.session, {this.seed});

  final int? seed;
  DashWorld? _w;
  final Sparks sparks = Sparks();
  final List<_Trail> _trails = List.generate(6, (_) => _Trail());
  int _nextTrail = 0;

  Vector2? _down;
  Vector2? _aim;
  double _slowMo = 0;
  double _shake = 0;
  double _clock = 0;
  double _banner = 0;
  String _bannerText = '';
  double _endDelay = 1.0;
  bool _reported = false;

  // Reused drawing objects to keep per-frame allocation low.
  final Path _path = Path();
  final Paint _fill = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _glow = Paint()
    ..shader = Gradient.radial(Offset.zero, 34, const [Color(0x88FF9A3C), Color(0x00FF9A3C)]);
  final List<_Blot> _blots = [];

  /// Rules object (named to avoid FlameGame.world).
  DashWorld get dash => _w!;

  static const double swipeGain = 2.0;
  static const double tapSlop = 12;

  @override
  int get entityCount => (_w?.entityCount ?? 0) + sparks.count;

  @override
  int get liveScore => _w?.score ?? 0;

  @override
  Color backgroundColor() => const Color(0xFF16120F);

  // ---------------------------------------------------------------- layout
  double get arenaLeft => 10;
  double get arenaTop => hudTop + 34;
  double get arenaWidth => math.max(120, size.x - 20);
  double get arenaHeight => math.max(200, size.y - arenaTop - safePadding.bottom - 12);

  Vector2 toScreen(double x, double y) => Vector2(arenaLeft + x, arenaTop + y);

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (_w == null) {
      _w = DashWorld(
        width: arenaWidth,
        height: arenaHeight,
        seed: seed ?? DateTime.now().microsecondsSinceEpoch,
      );
    } else {
      _w!.resize(arenaWidth, arenaHeight);
    }
    _blots.clear();
    final rng = math.Random(17);
    for (var i = 0; i < 14; i++) {
      _blots.add(
        _Blot(rng.nextDouble() * arenaWidth, rng.nextDouble() * arenaHeight, 18 + rng.nextDouble() * 50),
      );
    }
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (_w == null || dash.isOver) return;
    _down = position.clone();
    _aim = position.clone();
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (_down == null) return;
    _aim = position.clone();
  }

  @override
  void onPointerUp(Vector2 position) {
    final d = _down;
    _down = null;
    _aim = null;
    if (d == null || _w == null) return;
    final dx = position.x - d.x;
    final dy = position.y - d.y;
    if (dx * dx + dy * dy < tapSlop * tapSlop) return;
    if (dash.dash(dx * swipeGain, dy * swipeGain)) {
      audio.play(Sfx.whoosh);
      audio.haptic(HapticKind.light);
      _consumeEvents();
    }
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    final w = _w;
    if (w == null) return;
    _clock += dt;
    // Slow motion is presentation only: the rules just receive less time.
    final scale = _slowMo > 0 ? 0.3 : 1.0;
    if (_slowMo > 0) _slowMo -= dt;
    w.update(dt * scale);
    _consumeEvents();
    sparks.update(dt * scale);
    for (final t in _trails) {
      if (t.age < 1) t.age += dt * 2.5;
    }
    if (_shake > 0) _shake -= dt;
    if (_banner > 0) _banner -= dt;
    if (w.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report(w);
    }
  }

  void _consumeEvents() {
    final w = _w!;
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      switch (e.kind) {
        case DashEventKind.dash:
          final t = _trails[_nextTrail];
          _nextTrail = (_nextTrail + 1) % _trails.length;
          t
            ..x1 = e.x
            ..y1 = e.y
            ..x2 = e.x2
            ..y2 = e.y2
            ..age = 0
            ..kill = e.count > 0;
        case DashEventKind.slice:
          audio.play(Sfx.pop);
          sparks.burst(e.x, e.y, reduced ? 5 : 14, _ink, speed: 180, life: 0.45);
          if (!reduced) sparks.burst(e.x, e.y, 6, _vermilion, speed: 120, life: 0.4);
        case DashEventKind.multiKill:
          _slowMo = 0.2;
          audio.haptic(HapticKind.medium);
          _banner = 0.9;
          _bannerText = '${e.count}x CUT  ·  x${w.combo} COMBO';
        case DashEventKind.blocked:
          audio.play(Sfx.thud);
          sparks.burst(e.x, e.y, reduced ? 3 : 8, _gold, speed: 140, life: 0.3);
        case DashEventKind.bossHit:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          sparks.burst(e.x, e.y, reduced ? 8 : 24, _gold, speed: 220);
          if (!reduced) _shake = 0.2;
        case DashEventKind.bossDown:
          audio.play(Sfx.win);
          sparks.burst(e.x, e.y, reduced ? 20 : 80, _ink, speed: 320, life: 0.9);
          if (!reduced) _shake = 0.5;
        case DashEventKind.blast:
          audio.play(Sfx.thud);
          sparks.burst(e.x, e.y, reduced ? 6 : 18, _vermilion, speed: 260, life: 0.4);
          if (!reduced) _shake = math.max(_shake, 0.15);
        case DashEventKind.hurt:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          if (!reduced) _shake = 0.3;
          if (e.count == 0) audio.play(Sfx.lose);
        case DashEventKind.shot:
          break;
        case DashEventKind.waveStart:
          _banner = 1.4;
          _bannerText = e.count >= DashWorld.bossWave ? 'THE LANTERN EATER' : 'WAVE ${e.count}';
        case DashEventKind.waveClear:
          audio.play(Sfx.powerup);
          _banner = 1.4;
          _bannerText = 'WAVE ${e.count} CLEAR';
        case DashEventKind.heal:
          audio.play(Sfx.coin);
          sparks.burst(e.x, e.y, 12, _lantern, speed: 120);
      }
    }
    w.events.clear();
  }

  void _report(DashWorld w) {
    _reported = true;
    final save = session.context.save;
    final prev = save.intData('bestWave');
    final reached = w.won ? DashWorld.bossWave : w.wave;
    if (reached > prev) {
      save.data['bestWave'] = reached;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: w.score,
        won: w.won,
        headline: w.won
            ? 'The boss falls. All ${DashWorld.finalWave} waves cut down!'
            : w.isBossWave
            ? 'Fell to the boss after ${DashWorld.finalWave} waves'
            : 'Fell on wave ${w.wave} of ${DashWorld.finalWave}',
        details: {
          'Wave': w.isBossWave ? 'Boss' : '${w.wave}',
          'Best wave': '${math.max(prev, reached) >= DashWorld.bossWave ? 'Boss' : math.max(prev, reached)}',
          'Kills': '${w.kills}',
          'Best multi-cut': '${w.bestMultiKill}',
          'Dashes': '${w.dashes}',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final w = _w;
    if (w == null || size.x <= 0) return;
    canvas.save();
    canvas.translate(arenaLeft, arenaTop);
    if (_shake > 0) {
      final m = _shake * 12;
      canvas.translate(math.sin(_clock * 90) * m, math.cos(_clock * 71) * m);
    }
    _drawPaper(canvas, w);
    _drawBlasts(canvas, w);
    _drawTrails(canvas);
    for (final f in w.foes) {
      _drawFoe(canvas, w, f);
    }
    _drawBolts(canvas, w);
    _drawAim(canvas, w);
    _drawHero(canvas, w);
    sparks.render(canvas);
    canvas.restore();
    if (_slowMo > 0 && !ctx.settings.reducedEffects) {
      _fill.color = const Color(0x221E1A18);
      canvas.drawRect(Rect.fromLTWH(arenaLeft, arenaTop, w.width, w.height), _fill);
    }
    _drawHud(canvas, w);
  }

  void _drawPaper(Canvas canvas, DashWorld w) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w.width, w.height), const Radius.circular(10));
    _fill.color = _paper;
    canvas.drawRRect(r, _fill);
    _fill.color = _paperShade.withValues(alpha: 0.35);
    for (final b in _blots) {
      canvas.drawOval(Rect.fromCenter(center: Offset(b.x, b.y), width: b.r * 2, height: b.r * 0.7), _fill);
    }
    _stroke
      ..color = _ink.withValues(alpha: 0.75)
      ..strokeWidth = 3;
    canvas.drawRRect(r, _stroke);
  }

  void _drawBlasts(Canvas canvas, DashWorld w) {
    for (final b in w.blasts) {
      final c = Offset(b.pos.x, b.pos.y);
      final t = (b.age / 0.5).clamp(0.0, 1.0);
      if (b.active) {
        _fill.color = _vermilion.withValues(alpha: 0.28 * (1 - b.age / DashWorld.blastWindow) + 0.1);
        canvas.drawCircle(c, DashWorld.blastRadius, _fill);
      }
      _stroke
        ..color = _vermilion.withValues(alpha: 1 - t)
        ..strokeWidth = 5 * (1 - t) + 1;
      canvas.drawCircle(c, DashWorld.blastRadius * (0.4 + 0.6 * t), _stroke);
    }
  }

  /// Tapered brush stroke along each recent dash.
  void _drawTrails(Canvas canvas) {
    for (final t in _trails) {
      if (t.age >= 1) continue;
      final dx = t.x2 - t.x1;
      final dy = t.y2 - t.y1;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1) continue;
      final nx = -dy / len;
      final ny = dx / len;
      final wdt = 7 * (1 - t.age * 0.6);
      final mx = t.x1 + dx * 0.62;
      final my = t.y1 + dy * 0.62;
      _path
        ..reset()
        ..moveTo(t.x1, t.y1)
        ..quadraticBezierTo(mx + nx * wdt, my + ny * wdt, t.x2, t.y2)
        ..quadraticBezierTo(mx - nx * wdt * 0.6, my - ny * wdt * 0.6, t.x1, t.y1)
        ..close();
      _fill.color = _ink.withValues(alpha: (1 - t.age) * 0.85);
      canvas.drawPath(_path, _fill);
      if (t.kill) {
        _stroke
          ..color = _vermilion.withValues(alpha: 1 - t.age)
          ..strokeWidth = 1.5;
        canvas.drawLine(Offset(t.x1, t.y1), Offset(t.x2, t.y2), _stroke);
      }
    }
  }

  /// Wobbly ink blot built in the shared path.
  void _blob(Canvas canvas, double cx, double cy, double r, int seed, Color color) {
    _path.reset();
    const n = 12;
    for (var i = 0; i <= n; i++) {
      final a = i * math.pi * 2 / n;
      final k = 1 + 0.09 * math.sin(a * 3 + seed * 1.7) + 0.05 * math.sin(a * 5 + _clock * 3 + seed);
      final x = cx + math.cos(a) * r * k;
      final y = cy + math.sin(a) * r * k;
      if (i == 0) {
        _path.moveTo(x, y);
      } else {
        _path.lineTo(x, y);
      }
    }
    _path.close();
    _fill.color = color;
    canvas.drawPath(_path, _fill);
  }

  void _drawFoe(Canvas canvas, DashWorld w, Foe f) {
    final c = Offset(f.pos.x, f.pos.y);
    final fx = f.facing.x;
    final fy = f.facing.y;
    final body = f.flash > 0 ? Colors.white : _ink;
    if (f.kind == FoeKind.boss) {
      _drawBoss(canvas, w, f, c, body);
      return;
    }
    // Soft shadow.
    _fill.color = const Color(0x22000000);
    canvas.drawOval(
      Rect.fromCenter(center: c + const Offset(2, 5), width: f.radius * 2.1, height: f.radius),
      _fill,
    );
    _blob(canvas, c.dx, c.dy, f.radius, f.id, body);
    switch (f.kind) {
      case FoeKind.walker:
        break;
      case FoeKind.archer:
        _stroke
          ..color = _vermilion
          ..strokeWidth = 2.5;
        final a = math.atan2(fy, fx);
        canvas.drawArc(Rect.fromCircle(center: c, radius: f.radius + 5), a - 0.9, 1.8, false, _stroke);
      case FoeKind.shieldbearer:
        final a = math.atan2(fy, fx);
        _stroke
          ..color = _vermilion
          ..strokeWidth = 6;
        canvas.drawArc(Rect.fromCircle(center: c, radius: f.radius + 5), a - 1.05, 2.1, false, _stroke);
        _stroke
          ..color = _gold
          ..strokeWidth = 1.5;
        canvas.drawArc(Rect.fromCircle(center: c, radius: f.radius + 5), a - 0.9, 1.8, false, _stroke);
      case FoeKind.bomber:
        final pulse = 0.5 + 0.5 * math.sin(_clock * 10 + f.id);
        _stroke
          ..color = _vermilion.withValues(alpha: 0.4 + 0.5 * pulse)
          ..strokeWidth = 2;
        canvas.drawCircle(c, f.radius + 3 + pulse * 2, _stroke);
        _fill.color = _gold;
        canvas.drawCircle(c - Offset(fx, fy) * f.radius, 3 + pulse * 1.5, _fill);
      case FoeKind.boss:
        break;
    }
    // Eyes looking along the facing.
    final ex = -fy * f.radius * 0.32;
    final ey = fx * f.radius * 0.32;
    final eo = Offset(fx, fy) * f.radius * 0.35;
    _fill.color = f.kind == FoeKind.bomber ? _gold : _paper;
    canvas.drawCircle(c + eo + Offset(ex, ey), 2.4, _fill);
    canvas.drawCircle(c + eo - Offset(ex, ey), 2.4, _fill);
  }

  void _drawBoss(Canvas canvas, DashWorld w, Foe b, Offset c, Color body) {
    _fill.color = const Color(0x33000000);
    canvas.drawOval(
      Rect.fromCenter(center: c + const Offset(4, 10), width: b.radius * 2.2, height: b.radius),
      _fill,
    );
    _blob(canvas, c.dx, c.dy, b.radius, b.id, body);
    // Rotating weak-spot arc: the only way in.
    final weak = Rect.fromCircle(center: c, radius: b.radius + 6);
    _stroke
      ..color = _gold.withValues(alpha: b.hitCooldown > 0 ? 0.35 : 0.95)
      ..strokeWidth = 7;
    canvas.drawArc(
      weak,
      b.weakAngle - DashWorld.bossWeakHalfArc,
      DashWorld.bossWeakHalfArc * 2,
      false,
      _stroke,
    );
    _stroke
      ..color = _ink
      ..strokeWidth = 3;
    canvas.drawArc(
      weak,
      b.weakAngle + DashWorld.bossWeakHalfArc,
      math.pi * 2 - DashWorld.bossWeakHalfArc * 2,
      false,
      _stroke,
    );
    // One big lantern eye that tracks the weak spot.
    final eye = c + Offset(math.cos(b.weakAngle), math.sin(b.weakAngle)) * b.radius * 0.4;
    _fill.color = _lantern;
    canvas.drawCircle(eye, b.radius * 0.24, _fill);
    _fill.color = _ink;
    canvas.drawCircle(eye, b.radius * 0.1, _fill);
    // Health pips.
    for (var i = 0; i < b.maxHp; i++) {
      _fill.color = i < b.hp ? _vermilion : const Color(0x55000000);
      canvas.drawCircle(Offset(c.dx - (b.maxHp - 1) * 7 + i * 14, c.dy - b.radius - 16), 4.5, _fill);
    }
  }

  void _drawBolts(Canvas canvas, DashWorld w) {
    _stroke
      ..color = _vermilion.withValues(alpha: 0.5)
      ..strokeWidth = 3;
    _fill.color = _vermilion;
    for (final b in w.bolts) {
      final c = Offset(b.pos.x, b.pos.y);
      canvas.drawLine(c, c - Offset(b.vel.x, b.vel.y) * 0.09, _stroke);
      canvas.drawCircle(c, b.radius, _fill);
    }
  }

  void _drawAim(Canvas canvas, DashWorld w) {
    final d = _down;
    final a = _aim;
    if (d == null || a == null) return;
    var dx = (a.x - d.x) * swipeGain;
    var dy = (a.y - d.y) * swipeGain;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < tapSlop) return;
    if (len > w.maxDash) {
      dx *= w.maxDash / len;
      dy *= w.maxDash / len;
    }
    final steps = (math.min(len, w.maxDash) / 10).floor();
    _fill.color = (w.cooldown > 0 ? _ink : _vermilion).withValues(alpha: 0.55);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      canvas.drawCircle(Offset(w.hero.x + dx * t, w.hero.y + dy * t), 1.6 + t, _fill);
    }
  }

  /// The lantern ronin: wide straw hat, ink cloak and a glowing paper lantern.
  void _drawHero(Canvas canvas, DashWorld w) {
    final h = w.hero;
    final blink = w.invulnerable > 0 && (_clock * 18).floor().isEven;
    canvas.save();
    canvas.translate(h.x, h.y);
    canvas.drawCircle(Offset.zero, 34, _glow);
    if (!blink) {
      const r = DashWorld.heroRadius;
      // Cloak: a brush-stroke teardrop.
      _path
        ..reset()
        ..moveTo(0, -r * 0.4)
        ..quadraticBezierTo(r * 1.3, r * 0.5, r * 0.3, r * 1.25)
        ..lineTo(-r * 0.4, r * 1.2)
        ..quadraticBezierTo(-r * 1.3, r * 0.4, 0, -r * 0.4)
        ..close();
      _fill.color = _ink;
      canvas.drawPath(_path, _fill);
      // Hat.
      _path
        ..reset()
        ..moveTo(-r * 1.35, -r * 0.15)
        ..quadraticBezierTo(0, -r * 1.5, r * 1.35, -r * 0.15)
        ..quadraticBezierTo(0, -r * 0.45, -r * 1.35, -r * 0.15)
        ..close();
      _fill.color = const Color(0xFFB98A4A);
      canvas.drawPath(_path, _fill);
      _stroke
        ..color = _ink
        ..strokeWidth = 1.5;
      canvas.drawPath(_path, _stroke);
      // Lantern on a short pole.
      canvas.drawLine(const Offset(r * 0.5, r * 0.4), const Offset(r * 1.1, -r * 0.2), _stroke);
      _fill.color = _lantern;
      canvas.drawOval(Rect.fromCenter(center: const Offset(r * 1.15, r * 0.25), width: 8, height: 10), _fill);
      // Cooldown tick under the feet.
      if (w.cooldown > 0) {
        _stroke
          ..color = _vermilion
          ..strokeWidth = 2;
        canvas.drawArc(
          Rect.fromCircle(center: Offset.zero, radius: r + 6),
          math.pi / 2,
          math.pi * 2 * w.cooldown / DashWorld.dashCooldown,
          false,
          _stroke,
        );
      }
    }
    canvas.restore();
  }

  void _drawHud(Canvas canvas, DashWorld w) {
    final top = safePadding.top + 14;
    CanvasText.draw(
      canvas,
      w.isBossWave ? 'BOSS' : 'WAVE ${w.wave}/${DashWorld.finalWave}',
      Offset(size.x / 2, top),
      size: 18,
      align: Alignment.topCenter,
    );
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(size.x - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: _gold,
    );
    // Hearts as small paper lanterns.
    for (var i = 0; i < DashWorld.maxHearts; i++) {
      final c = Offset(24 + i * 22.0, hudTop + 12);
      final full = i < w.hearts;
      _fill.color = full ? _lantern : const Color(0x33FFFFFF);
      canvas.drawOval(Rect.fromCenter(center: c, width: 14, height: 17), _fill);
      _stroke
        ..color = full ? const Color(0xFF7A2E10) : const Color(0x55FFFFFF)
        ..strokeWidth = 1.5;
      canvas.drawLine(c - const Offset(5, 8.5), c - const Offset(-5, 8.5), _stroke);
      canvas.drawLine(c + const Offset(-5, 8.5), c + const Offset(5, 8.5), _stroke);
    }
    if (w.combo > 0) {
      CanvasText.draw(
        canvas,
        'COMBO x${w.combo}',
        Offset(size.x - 16, hudTop + 2),
        size: 14,
        align: Alignment.topRight,
        color: _lantern,
        weight: FontWeight.w900,
      );
      drawBar(
        canvas,
        Rect.fromLTWH(size.x - 112, hudTop + 21, 96, 4),
        w.comboTimer / DashWorld.comboWindow,
        _lantern,
      );
    } else {
      CanvasText.draw(
        canvas,
        '${w.remainingInWave} left',
        Offset(size.x - 16, hudTop + 4),
        size: 12,
        align: Alignment.topRight,
        color: Colors.white54,
      );
    }
    if (_banner > 0 && _bannerText.isNotEmpty) {
      final alpha = _banner.clamp(0.0, 1.0);
      CanvasText.draw(
        canvas,
        _bannerText,
        Offset(size.x / 2, arenaTop + arenaHeight * 0.28),
        size: 28,
        align: Alignment.center,
        color: _ink.withValues(alpha: alpha),
        weight: FontWeight.w900,
      );
    }
    if (w.wave == 1 && w.time < 5 && w.dashes == 0) {
      CanvasText.draw(
        canvas,
        'Swipe to dash · everything on the line is cut',
        Offset(size.x / 2, arenaTop + arenaHeight - 28),
        size: 14,
        align: Alignment.center,
        color: _ink.withValues(alpha: 0.75),
      );
    }
    if (w.isOver) {
      CanvasText.draw(
        canvas,
        w.won ? 'VICTORY' : 'FALLEN',
        Offset(size.x / 2, arenaTop + arenaHeight * 0.45),
        size: 40,
        align: Alignment.center,
        color: w.won ? _gold : _vermilion,
        weight: FontWeight.w900,
      );
    }
  }
}

class _Blot {
  _Blot(this.x, this.y, this.r);
  final double x;
  final double y;
  final double r;
}
