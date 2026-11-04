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
import 'circle_physics.dart';
import 'pour_world.dart';

class BallPourCartridge extends FlameCartridge<BallPourGame> {
  const BallPourCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'ball-pour',
    title: 'Ball Pour',
    tagline: 'Open the gate. Steer the stream. Fill the cup.',
    description:
        'A physics pouring puzzle. Hold to open the hopper gate and let a stream of bouncy balls '
        'tumble through ramps, pegs and splitting rings. Drag planks along their rails to steer '
        'the flow and settle enough balls in the cup before they all fall away.',
    genre: 'Physics puzzle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFF5FA2),
    icon: Icons.local_drink_rounded,
    tags: ['physics', 'puzzle', 'balls', 'casual', 'levels', 'one-thumb'],
    controls: [
      'Hold anywhere to open the hopper gate; release to close it',
      'Drag a plank (pink bar) to slide or tilt it along its rail',
    ],
    mechanics: ['circle physics', 'pouring', 'draggable planks', 'multiplier rings', 'moving cup', 'levels'],
    goal: 'Settle at least the target number of balls in the cup. Balls that fall off the bottom are lost.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  BallPourGame createGame(FlameCartridgeSession<BallPourGame> session) => BallPourGame(session);
}

/// Candy palette for balls (picked by ball id).
const List<Color> kPourBallColors = [
  Color(0xFFFF5FA2),
  Color(0xFFFFC94A),
  Color(0xFF4FD1FF),
  Color(0xFF7CF29A),
  Color(0xFFB98CFF),
  Color(0xFFFF8A5B),
];

class BallPourGame extends AsobiFlameGame {
  BallPourGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      pour = PourWorld(
        level: math.max(1, session.context.save.intData('level', 1)),
        seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x3fffffff,
      );

  final int? seed;
  final int level;

  /// The rules + physics (named `pour` because FlameGame already owns `world`).
  final PourWorld pour;
  final Sparks sparks = Sparks(capacity: 300);

  bool _reported = false;
  double _endDelay = 1.2;
  double _clock = 0;
  bool _touched = false;
  bool _endSounded = false;

  /// Plank being dragged (-1 = none) and the grab offset in world units.
  int _drag = -1;
  double _grabDx = 0, _grabDy = 0;

  /// 0 = gate closed, 1 = fully open (eased for the animation).
  double _gateAnim = 0;

  int _seenEntries = 0;
  int _seenSplits = 0;
  int _seenLost = 0;
  late final List<int> _seenRingHits = List<int>.filled(pour.def.rings.length, 0);
  late final List<double> _ringFlash = List<double>.filled(pour.def.rings.length, 0);
  final List<double> _sfxCooldown = List<double>.filled(Sfx.values.length, 0);

  @override
  int get entityCount => pour.entityCount + sparks.count;

  @override
  Color backgroundColor() => const Color(0xFF120F24);

  // ---------------------------------------------------------------- layout
  double get _worldTop => hudTop + 46;
  double get _worldBottom => size.y - safePadding.bottom - 8;

  /// Pixels per world unit (letterboxed to keep the portrait aspect).
  double get _scale =>
      math.max(1, math.min((size.x - 16) / PourWorld.width, (_worldBottom - _worldTop) / PourWorld.height));

  double get _ox => (size.x - PourWorld.width * _scale) / 2;
  double get _oy => _worldTop + ((_worldBottom - _worldTop) - PourWorld.height * _scale) / 2;

  Offset _toScreen(double x, double y) => Offset(_ox + x * _scale, _oy + y * _scale);
  double _toWorldX(double sx) => (sx - _ox) / _scale;
  double _toWorldY(double sy) => (sy - _oy) / _scale;

  // ---------------------------------------------------------------- audio
  void _sfx(Sfx s, double gap) {
    if (_sfxCooldown[s.index] > 0) return;
    _sfxCooldown[s.index] = gap;
    audio.play(s);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (pour.isOver || !hasLayout || size.x <= 0) return;
    _touched = true;
    final wx = _toWorldX(position.x), wy = _toWorldY(position.y);
    final idx = pour.plankAt(wx, wy, math.max(0.7, 30 / _scale));
    if (idx >= 0) {
      _drag = idx;
      final p = pour.planks[idx];
      _grabDx = p.isPivot ? 0 : wx - p.centerX;
      _grabDy = p.isPivot ? 0 : wy - p.centerY;
      _sfx(Sfx.whoosh, 0.15);
      audio.haptic(HapticKind.selection);
      return;
    }
    pour.setGateOpen(true);
    _sfx(Sfx.tap, 0.1);
    audio.haptic(HapticKind.light);
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (_drag < 0 || pour.isOver) return;
    pour.movePlank(_drag, _toWorldX(position.x) - _grabDx, _toWorldY(position.y) - _grabDy);
  }

  @override
  void onPointerUp(Vector2 position) {
    _drag = -1;
    pour.setGateOpen(false);
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    for (var i = 0; i < _sfxCooldown.length; i++) {
      if (_sfxCooldown[i] > 0) _sfxCooldown[i] -= dt;
    }
    final wasOver = pour.isOver;
    pour.update(dt);
    sparks.update(dt);
    final k = 1 - math.exp(-dt * 14);
    _gateAnim += ((pour.gateOpen ? 1.0 : 0.0) - _gateAnim) * k;
    _reactToEvents();
    for (var i = 0; i < _ringFlash.length; i++) {
      if (_ringFlash[i] > 0) _ringFlash[i] -= dt;
    }
    if (pour.isOver && !_endSounded) {
      _endSounded = true;
      _drag = -1;
      if (pour.won) {
        audio.play(Sfx.win);
        audio.haptic(HapticKind.medium);
        if (hasLayout) {
          final c = _toScreen(pour.cupX, pour.cupTop);
          sparks.burst(
            c.dx,
            c.dy,
            ctx.settings.reducedEffects ? 12 : 60,
            const Color(0xFFFFD166),
            speed: 320,
          );
        }
      } else {
        audio.play(Sfx.lose);
        audio.haptic(HapticKind.heavy);
      }
    }
    if (pour.isOver && wasOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _reactToEvents() {
    final reduced = ctx.settings.reducedEffects;
    if (pour.cupEntries > _seenEntries) {
      _seenEntries = pour.cupEntries;
      _sfx(Sfx.pop, 0.07);
      if (hasLayout && !reduced) {
        final c = _toScreen(pour.cupX, pour.cupTop + 0.2);
        sparks.burst(c.dx, c.dy, 3, const Color(0xFFFFF0B3), speed: 120, life: 0.35);
      }
    }
    if (pour.splits > _seenSplits) {
      _seenSplits = pour.splits;
      _sfx(Sfx.coin, 0.09);
    }
    for (var i = 0; i < _seenRingHits.length; i++) {
      if (pour.ringHits[i] != _seenRingHits[i]) {
        _seenRingHits[i] = pour.ringHits[i];
        _ringFlash[i] = 0.3;
        if (hasLayout && !reduced) {
          final r = pour.def.rings[i];
          final c = _toScreen(r.x, r.y);
          sparks.burst(c.dx, c.dy, 2, const Color(0xFFFFD166), speed: 140, life: 0.3);
        }
      }
    }
    if (pour.lost > _seenLost) {
      _seenLost = pour.lost;
      _sfx(Sfx.thud, 0.3);
    }
  }

  void _report() {
    _reported = true;
    final won = pour.won;
    if (won) {
      session.context.save.data['level'] = level + 1;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: pour.score,
        won: won,
        headline: won
            ? '${pour.def.name} filled! Level ${level + 1} unlocked.'
            : 'Only ${pour.cupCount} of ${pour.target} balls made it on level $level.',
        details: {
          'Level': '$level',
          'In cup': '${pour.cupCount} / ${pour.target}',
          'Lost': '${pour.lost}',
          if (pour.splits > 0) 'Splits': '${pour.splits}',
          if (won) 'Level bonus': '${pour.levelBonus}',
          'Time': '${pour.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  final Paint _fill = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Path _path = Path();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (!hasLayout || size.x <= 0 || size.y <= 0) return;
    _drawField(canvas);
    _drawHopper(canvas);
    _drawStatics(canvas);
    _drawRings(canvas);
    _drawPlanks(canvas);
    _drawCup(canvas, back: true);
    _drawBalls(canvas);
    _drawCup(canvas, back: false);
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _drawField(Canvas canvas) {
    final s = _scale;
    final r = Rect.fromLTWH(_ox, _oy, PourWorld.width * s, PourWorld.height * s);
    _fill.color = const Color(0xFF1B1636);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(14)), _fill);
    // Soft horizontal bands for depth.
    _fill.color = const Color(0x0DFFFFFF);
    for (var i = 1; i < 8; i += 2) {
      canvas.drawRect(Rect.fromLTWH(r.left, r.top + i * r.height / 8, r.width, r.height / 8), _fill);
    }
    // The drop-off zone at the bottom.
    _fill.color = const Color(0x33FF4D6D);
    canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - 0.25 * s, r.width, 0.25 * s), _fill);
  }

  void _drawHopper(Canvas canvas) {
    final s = _scale;
    final hx = pour.def.hopperX;
    const top = PourWorld.hopperTop, bottom = PourWorld.hopperBottom;
    const halfTop = 1.4, halfBottom = PourWorld.spoutHalfWidth + 0.05;
    final a = _toScreen(hx - halfTop, top), b = _toScreen(hx + halfTop, top);
    final c = _toScreen(hx + halfBottom, bottom), d = _toScreen(hx - halfBottom, bottom);
    _path
      ..reset()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..lineTo(c.dx, c.dy)
      ..lineTo(d.dx, d.dy)
      ..close();
    _fill.color = const Color(0xFF2C2552);
    canvas.drawPath(_path, _fill);
    // Balls waiting inside, packed from the bottom up.
    const r = PourWorld.ballRadius;
    var shown = 0;
    final maxShown = pour.hopper;
    for (var row = 0; row < 8 && shown < maxShown; row++) {
      final y = bottom - r - 0.04 - row * r * 1.75;
      if (y < top + r) break;
      final f = (bottom - y) / (bottom - top);
      final half = halfBottom + (halfTop - halfBottom) * f - r - 0.03;
      final n = math.max(1, (half * 2 / (r * 2)).floor());
      final x0 = hx - (n - 1) * r;
      for (var i = 0; i < n && shown < maxShown; i++) {
        _fill.color = kPourBallColors[shown % kPourBallColors.length].withValues(alpha: 0.85);
        canvas.drawCircle(_toScreen(x0 + i * r * 2, y), r * s, _fill);
        shown++;
      }
    }
    _stroke
      ..strokeWidth = math.max(2, 0.08 * s)
      ..color = const Color(0xFF8C7BD9);
    canvas.drawPath(_path, _stroke);
    CanvasText.draw(
      canvas,
      '${pour.hopper}',
      _toScreen(hx, top - 0.05),
      size: 13,
      align: Alignment.bottomCenter,
      color: Colors.white70,
    );
    // Gate: a bar across the spout that slides aside when open.
    final shift = _gateAnim * (halfBottom * 2 + 0.1);
    final g0 = _toScreen(hx - halfBottom + shift, bottom + 0.02);
    final g1 = _toScreen(hx + halfBottom + shift, bottom + 0.02);
    _stroke
      ..strokeWidth = math.max(3, 0.12 * s)
      ..color = pour.gateOpen ? const Color(0xFF7CF29A) : const Color(0xFFFF5FA2);
    canvas.drawLine(g0, g1, _stroke);
  }

  void _drawStatics(Canvas canvas) {
    final s = _scale;
    final def = pour.def;
    _stroke.color = const Color(0xFF6E7BB8);
    for (final w in def.walls) {
      _stroke.strokeWidth = math.max(2, 0.12 * s);
      canvas.drawLine(_toScreen(w.ax, w.ay), _toScreen(w.bx, w.by), _stroke);
    }
    for (final p in def.pegs) {
      _fill.color = const Color(0xFF8E9BD6);
      canvas.drawCircle(_toScreen(p.x, p.y), p.r * s, _fill);
      _fill.color = const Color(0x55FFFFFF);
      canvas.drawCircle(_toScreen(p.x - p.r * 0.3, p.y - p.r * 0.3), p.r * 0.35 * s, _fill);
    }
  }

  void _drawRings(Canvas canvas) {
    final s = _scale;
    for (var i = 0; i < pour.def.rings.length; i++) {
      final r = pour.def.rings[i];
      final flash = (_ringFlash[i] / 0.3).clamp(0.0, 1.0);
      final c = _toScreen(r.x, r.y);
      final pulse = 0.5 + 0.5 * math.sin(_clock * 4 + i);
      _fill.color = Color.lerp(const Color(0x22FFD166), const Color(0x66FFD166), flash)!;
      canvas.drawCircle(c, r.r * s, _fill);
      _stroke
        ..strokeWidth = math.max(2, 0.07 * s) + flash * 2
        ..color = Color.lerp(const Color(0xFFE0A93A), const Color(0xFFFFF0B3), math.max(flash, pulse * 0.4))!;
      canvas.drawCircle(c, r.r * s, _stroke);
      CanvasText.draw(canvas, 'x2', c, size: 12, align: Alignment.center, color: const Color(0xFFFFE08A));
    }
  }

  void _drawPlanks(Canvas canvas) {
    final s = _scale;
    for (var i = 0; i < pour.planks.length; i++) {
      final p = pour.planks[i];
      final d = p.def;
      // Rail guide.
      _stroke
        ..strokeWidth = 2
        ..color = const Color(0x55FF9CC8);
      if (p.isPivot) {
        final c = _toScreen(d.ax, d.ay);
        final rr = d.length / 2 * s;
        final a0 = d.minAngle * math.pi / 180, a1 = d.maxAngle * math.pi / 180;
        final rect = Rect.fromCircle(center: c, radius: rr);
        canvas.drawArc(rect, a0, a1 - a0, false, _stroke);
        canvas.drawArc(rect, a0 + math.pi, a1 - a0, false, _stroke);
      } else {
        final a = _toScreen(d.ax, d.ay), b = _toScreen(d.bx, d.by);
        const dashes = 14;
        for (var k = 0; k < dashes; k += 2) {
          canvas.drawLine(Offset.lerp(a, b, k / dashes)!, Offset.lerp(a, b, (k + 1) / dashes)!, _stroke);
        }
        _fill.color = const Color(0x88FF9CC8);
        canvas.drawCircle(a, 3, _fill);
        canvas.drawCircle(b, 3, _fill);
      }
      // Plank body.
      final seg = p.seg;
      final a = _toScreen(seg.ax, seg.ay), b = _toScreen(seg.bx, seg.by);
      final active = _drag == i;
      _stroke
        ..strokeWidth = math.max(5, PourWorld.plankThickness * 2 * s) + 3
        ..color = active ? const Color(0xFFFFC2DC) : const Color(0xFFB8336F);
      canvas.drawLine(a, b, _stroke);
      _stroke
        ..strokeWidth = math.max(3, PourWorld.plankThickness * 2 * s)
        ..color = const Color(0xFFFF5FA2);
      canvas.drawLine(a, b, _stroke);
      // Grip dots.
      final m = Offset.lerp(a, b, 0.5)!;
      _fill.color = Colors.white;
      canvas.drawCircle(m, active ? 4 : 3, _fill);
      if (p.isPivot) {
        _fill.color = const Color(0xFF3A1730);
        canvas.drawCircle(m, 1.6, _fill);
      } else {
        canvas.drawCircle(Offset.lerp(a, b, 0.38)!, 2, _fill);
        canvas.drawCircle(Offset.lerp(a, b, 0.62)!, 2, _fill);
      }
    }
  }

  void _drawCup(Canvas canvas, {required bool back}) {
    final s = _scale;
    final l = pour.cupLeftX, r = pour.cupRightX, t = pour.cupTop, b = pour.cupBottomY;
    if (back) {
      final rect = Rect.fromLTRB(_ox + l * s, _oy + t * s, _ox + r * s, _oy + b * s);
      _fill.color = const Color(0x3348E5C2);
      canvas.drawRect(rect, _fill);
      return;
    }
    final full = pour.cupCount >= pour.target;
    _stroke
      ..strokeWidth = math.max(3, PourWorld.cupThickness * 2 * s)
      ..color = full ? const Color(0xFF7CF29A) : const Color(0xFF48E5C2);
    final p0 = _toScreen(l, t), p1 = _toScreen(l, b), p2 = _toScreen(r, b), p3 = _toScreen(r, t);
    _path
      ..reset()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo(p3.dx, p3.dy);
    canvas.drawPath(_path, _stroke);
    CanvasText.draw(
      canvas,
      '${pour.cupCount}/${pour.target}',
      _toScreen((l + r) / 2, t - 0.15),
      size: 14,
      align: Alignment.bottomCenter,
      weight: FontWeight.w900,
      color: full ? const Color(0xFF7CF29A) : Colors.white,
    );
  }

  void _drawBalls(Canvas canvas) {
    final s = _scale;
    final List<PBall> balls = pour.balls;
    for (var i = 0; i < balls.length; i++) {
      final b = balls[i];
      final c = _toScreen(b.x, b.y);
      _fill.color = kPourBallColors[b.id % kPourBallColors.length];
      canvas.drawCircle(c, b.radius * s, _fill);
      _fill.color = const Color(0x66FFFFFF);
      canvas.drawCircle(c.translate(-b.radius * s * 0.35, -b.radius * s * 0.35), b.radius * s * 0.35, _fill);
    }
  }

  void _drawHud(Canvas canvas) {
    CanvasText.draw(canvas, 'LEVEL $level', Offset(16, hudTop), size: 18, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      pour.def.name,
      Offset(16, hudTop + 22),
      size: 12,
      color: Colors.white60,
      weight: FontWeight.w600,
    );
    CanvasText.draw(
      canvas,
      '${pour.score}',
      Offset(size.x - 16, hudTop),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
      weight: FontWeight.w900,
    );
    final barW = math.min(150.0, size.x - 240);
    if (barW > 40) {
      final bar = Rect.fromLTWH((size.x - barW) / 2, hudTop + 6, barW, 10);
      drawBar(canvas, bar, pour.cupCount / pour.target, const Color(0xFF48E5C2));
      CanvasText.draw(
        canvas,
        'cup ${pour.cupCount}/${pour.target} · ${pour.ballsRemaining} left',
        Offset(size.x / 2, hudTop + 20),
        size: 12,
        align: Alignment.topCenter,
        color: Colors.white70,
      );
    } else {
      CanvasText.draw(
        canvas,
        '${pour.cupCount}/${pour.target} · ${pour.ballsRemaining} left',
        Offset(size.x - 16, hudTop + 26),
        size: 12,
        align: Alignment.topRight,
        color: Colors.white70,
      );
    }
    if (!pour.isOver && !_touched && pour.def.tip.isNotEmpty) {
      CanvasText.draw(
        canvas,
        pour.def.tip,
        Offset(size.x / 2, _oy + PourWorld.height * _scale * 0.45),
        size: 15,
        align: Alignment.center,
        color: Colors.white70,
        maxWidth: size.x - 48,
      );
    }
    if (pour.isOver) {
      CanvasText.draw(
        canvas,
        pour.won ? 'CUP FILLED!' : 'NOT ENOUGH BALLS',
        Offset(size.x / 2, size.y * 0.42),
        size: 32,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: pour.won ? const Color(0xFFFFD166) : const Color(0xFFFF4D6D),
      );
    }
  }
}
