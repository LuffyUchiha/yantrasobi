import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'toss_world.dart';

class BladeTossCartridge extends FlameCartridge<BladeTossGame> {
  const BladeTossCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'blade-toss',
    title: 'Blade Toss',
    tagline: 'Time the spin. Sink every blade.',
    description:
        'A wooden target spins, brakes and reverses. Tap to throw a blade into it - but if it '
        'lands too close to a blade already stuck there, the run is over. Sink every blade to '
        'clear the stage, pick off gems on the rim for bonus points, and crack the armoured '
        'boss target every fifth stage. How far can you go?',
    genre: 'Timing / reflex',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF9FB7D9),
    icon: Icons.track_changes_rounded,
    tags: ['timing', 'reflex', 'one-tap', 'endless', 'arcade'],
    controls: ['Tap anywhere to throw a blade upward into the spinning target'],
    mechanics: ['rotating target', 'motion scripts', 'one-mistake run', 'gems', 'boss every 5 stages'],
    goal:
        'Throw every blade without hitting another one. Score = stage x 100 + blades stuck '
        '+ 25 per gem. One clash ends the run.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  BladeTossGame createGame(FlameCartridgeSession<BladeTossGame> session) => BladeTossGame(session);
}

class BladeTossGame extends AsobiFlameGame {
  BladeTossGame(super.session, {this.seed})
    : toss = TossWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff),
      bestStage = session.context.save.intData('bestStage', 0);

  final int? seed;

  /// The rules object (FlameGame already owns `world`).
  final TossWorld toss;
  final int bestStage;
  final Sparks sparks = Sparks(capacity: 320);

  static const Color _accent = Color(0xFF9FB7D9);
  static const Color _gold = Color(0xFFFFD166);
  static const Color _danger = Color(0xFFFF5A5F);
  static const List<Color> _gemColors = [Color(0xFF2EE6A6), Color(0xFFFF5CA8), Color(0xFF52B6FF)];

  bool _reported = false;
  double _endTimer = 0;
  double _clock = 0;
  double _shake = 0;
  double _flash = 0;
  double _intro = 0; // stage drop-in animation, counts down
  double _reload = 0; // next blade slides into the launcher
  double _banner = 0; // "STAGE CLEAR" banner timer
  bool _shattered = false; // boss target broken during the clear pause
  final List<_Debris> _debris = [];

  @override
  int get entityCount => toss.entityCount + sparks.count + _debris.length;

  @override
  Color backgroundColor() => const Color(0xFF141A26);

  // ---------------------------------------------------------------- layout
  bool get _ready => hasLayout && size.x > 0;
  double get _radius {
    final vertical = (size.y - hudTop - safePadding.bottom - 126) / 4.75;
    return math.max(30, math.min(math.min(size.x * 0.25, vertical), 140));
  }

  Offset get _center => Offset(size.x / 2, hudTop + 56 + _radius * 1.9);
  double get _launchTipY => size.y - safePadding.bottom - 40 - _radius;

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (toss.isOver || !_ready) return;
    if (toss.throwBlade()) {
      audio.play(Sfx.whoosh);
      audio.haptic(HapticKind.selection);
    }
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    toss.update(dt);
    if (toss.events.isNotEmpty) {
      for (final e in toss.events) {
        _onEvent(e);
      }
      toss.events.clear();
    }
    sparks.update(dt);
    _shake = math.max(0, _shake - dt);
    _flash = math.max(0, _flash - dt);
    _intro = math.max(0, _intro - dt);
    _reload = math.max(0, _reload - dt);
    _banner = math.max(0, _banner - dt);
    for (final d in _debris) {
      d.vy += 900 * dt;
      d.x += d.vx * dt;
      d.y += d.vy * dt;
      d.rot += d.spin * dt;
      d.life -= dt;
    }
    _debris.removeWhere((d) => d.life <= 0);
    if (toss.isOver && !_reported) {
      _endTimer += dt;
      if (_endTimer >= 1.2) _report();
    }
  }

  void _onEvent(TossEvent e) {
    final reduced = ctx.settings.reducedEffects;
    final ready = _ready;
    final c = ready ? _center : Offset.zero;
    final r = ready ? _radius : 1.0;
    final abs = e.rel + toss.rotation;
    final rim = c + Offset(math.cos(abs), math.sin(abs)) * r;
    switch (e.kind) {
      case TossEventKind.stageStart:
        _intro = 0.3;
        _shattered = false;
        _reload = 0.15;
      case TossEventKind.stick:
        audio.play(Sfx.hit);
        audio.haptic(HapticKind.light);
        if (ready) sparks.burst(rim.dx, rim.dy, reduced ? 3 : 8, const Color(0xFFE8C08A), speed: 140);
        _reload = 0.1;
      case TossEventKind.gem:
        audio.play(Sfx.coin);
        if (ready) {
          sparks.burst(rim.dx, rim.dy, reduced ? 5 : 16, _gemColors[0], speed: 200, life: 0.6);
        }
      case TossEventKind.fail:
        audio.play(Sfx.lose);
        audio.haptic(HapticKind.heavy);
        _flash = 0.35;
        if (!reduced) _shake = 0.35;
        final hit = c + const Offset(0, 1) * r;
        _debris.add(
          _Debris(false, hit.dx, hit.dy + r * 0.3, vx: 140, vy: -380, spin: 9, rot: math.pi / 2, life: 1.6),
        );
        if (ready) sparks.burst(hit.dx, hit.dy, reduced ? 4 : 14, const Color(0xFFFFF1C1), speed: 240);
      case TossEventKind.stageClear:
        audio.play(Sfx.powerup);
        audio.haptic(HapticKind.medium);
        _banner = 0.9;
        if (ready) _ringBurst(c, r, reduced ? 8 : 26, const Color(0xFFE0A86A));
      case TossEventKind.bossShatter:
        audio.play(Sfx.win);
        audio.haptic(HapticKind.heavy);
        _banner = 0.9;
        _shattered = true;
        _spawnShards(c, r, reduced);
    }
  }

  void _ringBurst(Offset c, double r, int n, Color color) {
    for (var i = 0; i < n; i++) {
      final a = i * math.pi * 2 / n;
      sparks.burst(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r, 1, color, speed: 160);
    }
  }

  void _spawnShards(Offset c, double r, bool reduced) {
    final ready = _ready;
    final rot = toss.rotation;
    for (var i = 0; i < _kShards; i++) {
      final a = rot + (i + 0.5) * math.pi * 2 / _kShards;
      final dir = Offset(math.cos(a), math.sin(a));
      _debris.add(
        _Debris(
          true,
          c.dx,
          c.dy,
          vx: dir.dx * (220 + 40 * (i % 3)),
          vy: dir.dy * 220 - 260,
          spin: (i.isEven ? 1 : -1) * 3.0,
          rot: rot + i * math.pi * 2 / _kShards,
          life: 1.4,
          color: _shapeColor(toss.plan.shape),
        ),
      );
    }
    for (final b in toss.stuck) {
      final a = b.rel + rot;
      final dir = Offset(math.cos(a), math.sin(a));
      final p = c + dir * r;
      _debris.add(
        _Debris(
          false,
          p.dx,
          p.dy,
          vx: dir.dx * 260,
          vy: dir.dy * 260 - 200,
          spin: (b.rel > math.pi ? 1 : -1) * 7.0,
          rot: a,
          life: 1.4,
          obstacle: b.obstacle,
        ),
      );
    }
    if (ready) {
      sparks.burst(c.dx, c.dy, reduced ? 12 : 60, _shapeColor(toss.plan.shape), speed: 340, life: 0.8);
      sparks.burst(c.dx, c.dy, reduced ? 4 : 20, _gold, speed: 260, life: 0.7);
    }
  }

  void _report() {
    _reported = true;
    final save = session.context.save;
    final newBest = toss.stage > bestStage;
    if (newBest) save.data['bestStage'] = toss.stage;
    save.data['gems'] = save.intData('gems') + toss.gemsCollected;
    session.context.commitSave();
    finish(
      RunResult(
        score: toss.score,
        headline: newBest && bestStage > 0
            ? 'New best! Reached stage ${toss.stage}'
            : 'Reached stage ${toss.stage}',
        details: {
          'Stage': '${toss.stage}',
          'Best stage': '${math.max(bestStage, toss.stage)}',
          'Blades stuck': '${toss.bladesStuck}',
          'Gems': '${toss.gemsCollected}',
          'Bosses broken': '${toss.bossesCleared}',
          'Time': '${toss.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  final Paint _paint = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (!_ready || size.y <= 0) return;
    canvas.save();
    if (_shake > 0) {
      final k = _shake / 0.35 * 7;
      canvas.translate(math.sin(_clock * 71) * k, math.cos(_clock * 53) * k);
    }
    _drawBackdrop(canvas);
    final c = _center;
    final r = _radius;
    final rot = toss.rotation;
    final hideTarget = _shattered;
    if (!hideTarget) {
      final pop = toss.phase == TossPhase.clearing ? 1 + 0.06 * math.sin(math.pi * toss.clearProgress) : 1.0;
      final intro = 1 - _intro / 0.3;
      final scale = pop * (0.6 + 0.4 * _easeOutBack(intro.clamp(0.0, 1.0)));
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.scale(scale);
      // Blades and gems sit behind/over the rim, so draw blades first.
      for (final b in toss.stuck) {
        _drawBlade(canvas, Offset.zero, b.rel + rot, r * 0.86, r, obstacle: b.obstacle);
      }
      _drawTarget(canvas, r, rot, toss.plan.shape);
      for (var i = 0; i < toss.gems.length; i++) {
        final g = toss.gems[i];
        if (!g.taken) _drawGem(canvas, g.rel + rot, r, _gemColors[i % _gemColors.length]);
      }
      canvas.restore();
    }
    _drawLauncher(canvas, c, r);
    for (final d in _debris) {
      final a = (d.life / 0.5).clamp(0.0, 1.0);
      if (d.shard) {
        _drawShard(canvas, d, r, a);
      } else {
        _drawBlade(canvas, Offset(d.x, d.y), d.rot, 0, r, obstacle: d.obstacle, alpha: a);
      }
    }
    sparks.render(canvas);
    canvas.restore();
    if (_flash > 0) {
      _paint.color = _danger.withValues(alpha: _flash / 0.35 * 0.28);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
    }
    _drawBladeColumn(canvas);
    _drawHud(canvas);
  }

  void _drawBackdrop(Canvas canvas) {
    final c = _center;
    _paint.color = const Color(0xFF1B2333);
    canvas.drawCircle(c, _radius * 2.3, _paint);
    _paint.color = const Color(0xFF202A3D);
    canvas.drawCircle(c, _radius * 1.6, _paint);
    // Floor line under the launcher.
    _paint.color = const Color(0xFF1E2636);
    canvas.drawRect(Rect.fromLTWH(0, _launchTipY + _radius * 1.02, size.x, size.y), _paint);
  }

  static Color _shapeColor(TargetShape s) => switch (s) {
    TargetShape.disc => const Color(0xFFC98A4B),
    TargetShape.gear => const Color(0xFF8A94A8),
    TargetShape.shield => const Color(0xFF4F7A9E),
  };

  void _drawTarget(Canvas canvas, double r, double rot, TargetShape shape) {
    _paint.color = const Color(0x55000000);
    canvas.drawCircle(Offset(0, r * 0.06), r * 1.02, _paint);
    canvas.save();
    canvas.rotate(rot);
    switch (shape) {
      case TargetShape.disc:
        _drawWoodDisc(canvas, r);
      case TargetShape.gear:
        _drawGear(canvas, r);
      case TargetShape.shield:
        _drawShield(canvas, r);
    }
    canvas.restore();
  }

  void _drawWoodDisc(Canvas canvas, double r) {
    _paint.color = const Color(0xFF6B3F1F);
    canvas.drawCircle(Offset.zero, r, _paint);
    _paint.color = const Color(0xFFC98A4B);
    canvas.drawCircle(Offset.zero, r * 0.92, _paint);
    _paint.color = const Color(0xFFD69A5A);
    canvas.drawCircle(Offset(-r * 0.12, -r * 0.14), r * 0.62, _paint);
    _stroke
      ..strokeWidth = math.max(1, r * 0.025)
      ..color = const Color(0x557A4520);
    for (final k in const [0.78, 0.6, 0.42, 0.25]) {
      canvas.drawCircle(Offset.zero, r * k, _stroke);
    }
    // Rotating grain arcs and knots make the spin readable.
    _stroke
      ..strokeWidth = math.max(1, r * 0.03)
      ..color = const Color(0x667A4520);
    for (var i = 0; i < _kGrain.length; i += 3) {
      final rr = r * _kGrain[i];
      canvas.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: rr),
        _kGrain[i + 1],
        _kGrain[i + 2],
        false,
        _stroke,
      );
    }
    _paint.color = const Color(0xFF8A5229);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(r * 0.5, r * 0.18), width: r * 0.16, height: r * 0.1),
      _paint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(-r * 0.3, r * 0.5), width: r * 0.12, height: r * 0.08),
      _paint,
    );
    _paint.color = const Color(0xFF5A3418);
    canvas.drawCircle(Offset.zero, r * 0.07, _paint);
  }

  void _drawGear(Canvas canvas, double r) {
    canvas.save();
    canvas.scale(r);
    _paint.color = const Color(0xFF4A5263);
    canvas.drawPath(_kGearPath, _paint);
    canvas.restore();
    _paint.color = const Color(0xFF8A94A8);
    canvas.drawCircle(Offset.zero, r * 0.86, _paint);
    _paint.color = const Color(0xFF6C7689);
    canvas.drawCircle(Offset.zero, r * 0.62, _paint);
    _paint.color = const Color(0xFFB7C0D1);
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      canvas.drawCircle(Offset(math.cos(a), math.sin(a)) * r * 0.74, r * 0.045, _paint);
    }
    _paint.color = const Color(0xFFFF5A5F);
    canvas.drawCircle(Offset.zero, r * 0.2, _paint);
    _paint.color = const Color(0xFF2B303B);
    canvas.drawCircle(Offset.zero, r * 0.09, _paint);
  }

  void _drawShield(Canvas canvas, double r) {
    canvas.save();
    canvas.scale(r);
    _paint.color = const Color(0xFF2C455C);
    canvas.drawPath(_kOctagon, _paint);
    canvas.scale(0.84);
    _paint.color = const Color(0xFF4F7A9E);
    canvas.drawPath(_kOctagon, _paint);
    canvas.restore();
    _paint.color = const Color(0xFF2C455C);
    canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: r * 1.6, height: r * 0.16), _paint);
    canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: r * 0.16, height: r * 1.6), _paint);
    _paint.color = _gold;
    canvas.drawCircle(Offset.zero, r * 0.24, _paint);
    _paint.color = const Color(0xFFB8862B);
    canvas.drawCircle(Offset.zero, r * 0.13, _paint);
  }

  void _drawShard(Canvas canvas, _Debris d, double r, double alpha) {
    canvas.save();
    canvas.translate(d.x, d.y);
    canvas.rotate(d.rot);
    canvas.scale(r);
    _paint.color = d.color.withValues(alpha: alpha);
    canvas.drawPath(_kWedge, _paint);
    canvas.restore();
  }

  void _drawGem(Canvas canvas, double angle, double r, Color color) {
    canvas.save();
    canvas.rotate(angle);
    canvas.translate(r * 1.0, 0);
    canvas.scale(r * 0.12);
    _paint.color = color;
    canvas.drawPath(_kGemPath, _paint);
    _paint.color = const Color(0xAAFFFFFF);
    canvas.drawPath(_kGemShine, _paint);
    canvas.restore();
  }

  /// Draws a blade whose tip sits [tipDist] from [origin] along [angle]; the
  /// handle points further outward.
  void _drawBlade(
    Canvas canvas,
    Offset origin,
    double angle,
    double tipDist,
    double r, {
    bool obstacle = false,
    double alpha = 1,
  }) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.rotate(angle);
    canvas.translate(tipDist, 0);
    canvas.scale(r);
    _paint.color = (obstacle ? const Color(0xFF7D8596) : const Color(0xFFE3E9F2)).withValues(alpha: alpha);
    canvas.drawPath(_kBladePath, _paint);
    _paint.color = (obstacle ? const Color(0xFF5B6272) : const Color(0xFFAEB8C8)).withValues(alpha: alpha);
    canvas.drawPath(_kBladeEdge, _paint);
    _paint.color = (obstacle ? const Color(0xFF3B3F48) : const Color(0xFF39404F)).withValues(alpha: alpha);
    canvas.drawRect(const Rect.fromLTRB(0.5, -0.1, 0.55, 0.1), _paint);
    _paint.color = (obstacle ? const Color(0xFF6E4A32) : const Color(0xFF3F6FA8)).withValues(alpha: alpha);
    canvas.drawRRect(RRect.fromLTRBR(0.55, -0.042, 0.93, 0.042, const Radius.circular(0.03)), _paint);
    _paint.color = (obstacle ? const Color(0xFF3B3F48) : _accent).withValues(alpha: alpha);
    canvas.drawCircle(const Offset(0.95, 0), 0.05, _paint);
    canvas.restore();
  }

  void _drawLauncher(Canvas canvas, Offset c, double r) {
    final targetTipY = c.dy + r * 0.86;
    if (toss.phase == TossPhase.flying) {
      final t = toss.flightProgress;
      final y = _launchTipY + (targetTipY - _launchTipY) * t;
      _drawBlade(canvas, Offset(c.dx, y), math.pi / 2, 0, r);
    } else if (toss.phase == TossPhase.ready && toss.bladesLeft > 0) {
      final slide = _reload / 0.15 * r * 0.6;
      _drawBlade(canvas, Offset(c.dx, _launchTipY + slide), math.pi / 2, 0, r);
    }
  }

  void _drawBladeColumn(Canvas canvas) {
    final total = toss.plan.blades;
    const iconR = 30.0;
    const spacing = 22.0;
    final baseY = size.y - safePadding.bottom - 24;
    for (var i = 0; i < total; i++) {
      final y = baseY - (i + 1) * spacing;
      final live = i < toss.bladesLeft;
      _drawBlade(canvas, Offset(22, y), math.pi / 4, 0, iconR, alpha: live ? 1 : 0.18);
    }
  }

  void _drawHud(Canvas canvas) {
    CanvasText.draw(canvas, '${toss.score}', Offset(16, hudTop), size: 24, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      'BEST STAGE ${math.max(bestStage, toss.isOver ? toss.stage : 0)}',
      Offset(16, hudTop + 30),
      size: 11,
      color: Colors.white54,
    );
    // Gem counter.
    final gx = size.x - 16;
    CanvasText.draw(
      canvas,
      '${toss.gemsCollected}',
      Offset(gx, hudTop + 2),
      size: 20,
      align: Alignment.topRight,
      weight: FontWeight.w900,
      color: _gemColors[0],
    );
    canvas.save();
    canvas.translate(gx - 40, hudTop + 15);
    canvas.rotate(-math.pi / 2);
    canvas.scale(9);
    _paint.color = _gemColors[0];
    canvas.drawPath(_kGemPath, _paint);
    canvas.restore();

    // Stage title + five pips (the fifth is the boss).
    final boss = toss.isBoss;
    CanvasText.draw(
      canvas,
      boss ? 'BOSS · STAGE ${toss.stage}' : 'STAGE ${toss.stage}',
      Offset(size.x / 2, hudTop),
      size: 18,
      align: Alignment.topCenter,
      weight: FontWeight.w900,
      color: boss ? _danger : Colors.white,
    );
    final inCycle = (toss.stage - 1) % 5;
    for (var i = 0; i < 5; i++) {
      final x = size.x / 2 + (i - 2) * 18;
      final y = hudTop + 34;
      final done = i < inCycle || (i == inCycle && toss.phase == TossPhase.clearing);
      final current = i == inCycle;
      final isBossPip = i == 4;
      _paint.color = done
          ? (isBossPip ? _danger : _accent)
          : (current ? Colors.white : const Color(0xFF3A4458));
      if (isBossPip) {
        canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 11, height: 11), _paint);
      } else {
        canvas.drawCircle(Offset(x, y), 4.5, _paint);
      }
    }

    if (_banner > 0) {
      final a = (_banner / 0.3).clamp(0.0, 1.0);
      CanvasText.draw(
        canvas,
        toss.isBoss ? 'BOSS BROKEN!' : 'STAGE CLEAR',
        Offset(size.x / 2, _center.dy + _radius * 2.1),
        size: 26,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: _gold.withValues(alpha: a),
      );
    } else if (toss.phase != TossPhase.clearing && _intro > 0 && toss.isBoss) {
      CanvasText.draw(
        canvas,
        'BOSS TARGET',
        Offset(size.x / 2, _center.dy + _radius * 2.1),
        size: 24,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: _danger,
      );
    }
    if (toss.stage == 1 && toss.throws == 0 && !toss.isOver) {
      final pulse = 0.6 + 0.4 * math.sin(_clock * 4);
      CanvasText.draw(
        canvas,
        'Tap anywhere to throw · avoid the other blades',
        Offset(size.x / 2, _launchTipY - 18),
        size: 13,
        align: Alignment.bottomCenter,
        color: Colors.white.withValues(alpha: pulse),
      );
    }
    if (toss.isOver) {
      CanvasText.draw(
        canvas,
        'CLASH!',
        Offset(size.x / 2, size.y * 0.5 + _radius * 0.2),
        size: 40,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: _danger,
      );
    }
  }
}

class _Debris {
  _Debris(
    this.shard,
    this.x,
    this.y, {
    required this.vx,
    required this.vy,
    required this.spin,
    required this.rot,
    required this.life,
    this.obstacle = false,
    this.color = const Color(0xFFFFFFFF),
  });

  final bool shard;
  final bool obstacle;
  final Color color;
  double x, y, vx, vy, spin, rot, life;
}

double _easeOutBack(double t) {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  final u = t - 1;
  return 1 + c3 * u * u * u + c1 * u * u;
}

const int _kShards = 9;

/// Grain arcs on the wooden disc: (radius fraction, start angle, sweep).
const List<double> _kGrain = [
  0.86, 0.3, 1.1, //
  0.7, 2.2, 0.9,
  0.52, 4.0, 1.3,
  0.34, 1.0, 1.6,
  0.68, 5.0, 0.6,
  0.5, 0.6, 0.7,
];

// Unit-sized paths, built once and scaled at draw time.
final Path _kBladePath = Path()
  ..moveTo(0, 0)
  ..lineTo(0.16, -0.048)
  ..lineTo(0.5, -0.05)
  ..lineTo(0.5, 0.05)
  ..lineTo(0.16, 0.048)
  ..close();

final Path _kBladeEdge = Path()
  ..moveTo(0, 0)
  ..lineTo(0.16, 0.048)
  ..lineTo(0.5, 0.05)
  ..lineTo(0.5, 0.012)
  ..lineTo(0.16, 0.01)
  ..close();

final Path _kGemPath = Path()
  ..moveTo(-1, 0)
  ..lineTo(0, -0.7)
  ..lineTo(1.1, 0)
  ..lineTo(0, 0.7)
  ..close();

final Path _kGemShine = Path()
  ..moveTo(-0.55, -0.05)
  ..lineTo(0, -0.45)
  ..lineTo(0.2, -0.15)
  ..close();

final Path _kGearPath = () {
  const teeth = 14;
  final p = Path();
  for (var i = 0; i < teeth * 4; i++) {
    final a = i * math.pi * 2 / (teeth * 4);
    final rr = (i % 4 == 1 || i % 4 == 2) ? 1.08 : 0.95;
    final x = math.cos(a) * rr;
    final y = math.sin(a) * rr;
    if (i == 0) {
      p.moveTo(x, y);
    } else {
      p.lineTo(x, y);
    }
  }
  return p..close();
}();

final Path _kOctagon = () {
  final p = Path();
  for (var i = 0; i < 8; i++) {
    final a = math.pi / 8 + i * math.pi / 4;
    final x = math.cos(a) * 1.04;
    final y = math.sin(a) * 1.04;
    if (i == 0) {
      p.moveTo(x, y);
    } else {
      p.lineTo(x, y);
    }
  }
  return p..close();
}();

final Path _kWedge = () {
  final p = Path()..moveTo(0, 0);
  const steps = 6;
  for (var i = 0; i <= steps; i++) {
    final a = i * math.pi * 2 / _kShards / steps;
    p.lineTo(math.cos(a), math.sin(a));
  }
  return p..close();
}();
