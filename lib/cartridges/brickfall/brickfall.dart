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
import 'brick_world.dart';

class BrickfallCartridge extends FlameCartridge<BrickfallGame> {
  const BrickfallCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'brickfall',
    title: 'Brickfall',
    tagline: 'Angle the bounce. Chain the breaks.',
    description:
        'A paddle-and-ball brick breaker. Slide the paddle under the ball and use where it '
        'lands to steer the bounce. Tough bricks take several hits, steel never breaks and '
        'blast bricks take their neighbours with them. Catch falling capsules for a wide '
        'paddle, extra balls, a slower ball, a laser or an extra life.',
    genre: 'Brick breaker',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF2EC4F1),
    icon: Icons.sports_baseball_rounded,
    tags: ['arcade', 'brick breaker', 'paddle', 'levels', 'power-ups'],
    controls: [
      'Drag anywhere: the paddle follows your finger left and right',
      'Lift your finger to launch the ball',
      'With the laser capsule: tap to fire',
    ],
    mechanics: [
      'paddle angle control',
      'tough, steel and blast bricks',
      'power-up capsules',
      'combo',
      'levels',
    ],
    goal: 'Break every breakable brick. Losing all 3 balls ends the run.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  BrickfallGame createGame(FlameCartridgeSession<BrickfallGame> session) => BrickfallGame(session);
}

/// Display colours for each capsule kind.
const Map<PowerKind, Color> kPowerColors = {
  PowerKind.wide: Color(0xFF4EA8FF),
  PowerKind.multi: Color(0xFFFFC145),
  PowerKind.slow: Color(0xFF6EE7B7),
  PowerKind.laser: Color(0xFFFF4D6D),
  PowerKind.life: Color(0xFFFF7EB6),
};

const Map<PowerKind, String> kPowerLetters = {
  PowerKind.wide: 'W',
  PowerKind.multi: 'M',
  PowerKind.slow: 'S',
  PowerKind.laser: 'L',
  PowerKind.life: '+',
};

const List<Color> _rowColors = [
  Color(0xFF2EC4F1),
  Color(0xFF3DDC97),
  Color(0xFFB8E356),
  Color(0xFFFFD166),
  Color(0xFFFF9F45),
  Color(0xFFFF6B8B),
  Color(0xFFC77DFF),
];

class BrickfallGame extends AsobiFlameGame {
  BrickfallGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      bricks = BrickWorld(
        seed: seed ?? DateTime.now().microsecondsSinceEpoch,
        level: math.max(1, session.context.save.intData('level', 1)),
      );

  final int? seed;
  final int level;
  final BrickWorld bricks;
  final Sparks sparks = Sparks();

  bool _reported = false;
  double _endDelay = 1.0;
  double _clock = 0;
  double _shake = 0;
  bool _dragged = false;
  double _downX = 0;

  final Paint _paint = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  @override
  int get entityCount => bricks.entityCount + sparks.count;

  @override
  Color backgroundColor() => const Color(0xFF0B1020);

  // ---------------------------------------------------------------- layout
  double get _fieldTop => hudTop + 30;
  double get _fieldBottom => size.y - safePadding.bottom - 10;
  double get _scale => math.max(
    0.1,
    math.min((size.x - 16) / BrickWorld.width, (_fieldBottom - _fieldTop) / BrickWorld.height),
  );
  Offset get _origin {
    final s = _scale;
    final h = BrickWorld.height * s;
    return Offset((size.x - BrickWorld.width * s) / 2, _fieldTop + (_fieldBottom - _fieldTop - h) / 2);
  }

  double _toFieldX(double sx) => (sx - _origin.dx) / _scale;

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (bricks.isOver || !hasLayout || size.x <= 0) return;
    _dragged = false;
    _downX = position.x;
    bricks.setPaddleTarget(_toFieldX(position.x));
    if (bricks.laserActive && !bricks.hasHeldBall && bricks.fire()) {
      audio.play(Sfx.whoosh);
    }
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (bricks.isOver || !hasLayout || size.x <= 0) return;
    if ((position.x - _downX).abs() > 6) _dragged = true;
    bricks.setPaddleTarget(_toFieldX(position.x));
  }

  @override
  void onPointerUp(Vector2 position) {
    if (bricks.isOver) return;
    if (bricks.launch()) {
      audio.play(Sfx.tap);
      audio.haptic(HapticKind.selection);
    }
    _dragged = false;
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    bricks.update(dt);
    final reduced = ctx.settings.reducedEffects;
    final ready = hasLayout && size.x > 0;
    final s = ready ? _scale : 1.0;
    final o = ready ? _origin : Offset.zero;
    for (final e in bricks.events) {
      final x = o.dx + e.x * s, y = o.dy + e.y * s;
      switch (e.kind) {
        case BrickEventKind.hit:
          audio.play(Sfx.tap);
          sparks.burst(x, y, reduced ? 2 : 5, const Color(0xFFE0D4FF), speed: 120, life: 0.3);
        case BrickEventKind.broke:
          audio.play(e.brick == BrickKind.explosive ? Sfx.hit : Sfx.pop);
          final c = e.brick == BrickKind.explosive ? const Color(0xFFFF7A2F) : const Color(0xFFFFFFFF);
          sparks.burst(x, y, reduced ? 3 : (e.brick == BrickKind.explosive ? 26 : 9), c, speed: 200);
          if (e.brick == BrickKind.explosive) {
            audio.haptic(HapticKind.medium);
            if (!reduced) _shake = 0.25;
          }
        case BrickEventKind.steel:
          audio.play(Sfx.thud);
        case BrickEventKind.paddle:
          audio.play(Sfx.pop);
          audio.haptic(HapticKind.light);
        case BrickEventKind.wall:
          break;
        case BrickEventKind.launch:
          break;
        case BrickEventKind.capsule:
          audio.play(Sfx.powerup);
          audio.haptic(HapticKind.medium);
          sparks.burst(x, y, reduced ? 4 : 16, kPowerColors[e.power]!, speed: 180);
        case BrickEventKind.laser:
          break;
        case BrickEventKind.lifeLost:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          if (!reduced) _shake = 0.35;
        case BrickEventKind.won:
          audio.play(Sfx.win);
          sparks.burst(x, y, reduced ? 12 : 60, const Color(0xFFFFD166), speed: 320);
        case BrickEventKind.lost:
          audio.play(Sfx.lose);
      }
    }
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (bricks.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _report() {
    _reported = true;
    final won = bricks.won;
    if (won) {
      session.context.save.data['level'] = level + 1;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: bricks.score,
        won: won,
        headline: won
            ? '${BrickWorld.levelName(level)} cleared! Level ${level + 1} unlocked.'
            : 'Out of balls on level $level.',
        details: {
          'Level': '$level',
          'Bricks broken': '${bricks.bricksBroken}',
          'Best combo': 'x${bricks.bestCombo}',
          'Capsules': '${bricks.powersCaught}',
          if (won) 'Ball bonus': '${bricks.earnedLifeBonus}',
          'Time': '${bricks.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (!hasLayout || size.x <= 0 || size.y <= 0) return;
    final s = _scale;
    final o = _origin;
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 10;
      canvas.translate(math.sin(_clock * 90) * m, math.cos(_clock * 77) * m);
    }
    canvas.translate(o.dx, o.dy);
    canvas.scale(s);
    _drawField(canvas);
    for (final b in bricks.bricks) {
      if (b.alive) _drawBrick(canvas, b);
    }
    _drawCapsules(canvas);
    _drawBolts(canvas);
    _drawPaddle(canvas);
    _drawBalls(canvas);
    canvas.restore();
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _drawField(Canvas canvas) {
    const field = Rect.fromLTWH(0, 0, BrickWorld.width, BrickWorld.height);
    _paint.color = const Color(0xFF111833);
    canvas.drawRect(field, _paint);
    _paint.color = const Color(0xFF161F40);
    for (var y = 24.0; y < BrickWorld.height; y += 48) {
      canvas.drawRect(Rect.fromLTWH(0, y, BrickWorld.width, 1), _paint);
    }
    _stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF2EC4F1).withValues(alpha: 0.4);
    canvas.drawRect(field.deflate(1), _stroke);
    // Danger line under the paddle.
    _paint.color = const Color(0x33FF4D6D);
    canvas.drawRect(const Rect.fromLTWH(0, BrickWorld.height - 3, BrickWorld.width, 3), _paint);
  }

  Color _brickColor(Brick b) {
    switch (b.kind) {
      case BrickKind.normal:
        return _rowColors[b.row % _rowColors.length];
      case BrickKind.tough:
        return b.hp >= 3
            ? const Color(0xFF6A3FD9)
            : b.hp == 2
            ? const Color(0xFF9466F0)
            : const Color(0xFFC6A9FF);
      case BrickKind.steel:
        return const Color(0xFF8A94A8);
      case BrickKind.explosive:
        return Color.lerp(
          const Color(0xFFE8452C),
          const Color(0xFFFF9A3C),
          0.5 + 0.5 * math.sin(_clock * 6),
        )!;
    }
  }

  void _drawBrick(Canvas canvas, Brick b) {
    final r = Rect.fromLTRB(b.left + 1.5, b.top + 1.5, b.right - 1.5, b.bottom - 1.5);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(3.5));
    final c = b.flash > 0 ? Colors.white : _brickColor(b);
    _paint.color = c;
    canvas.drawRRect(rr, _paint);
    // Bevel.
    _paint.color = const Color(0x40FFFFFF);
    canvas.drawRect(Rect.fromLTWH(r.left + 2, r.top + 1.5, r.width - 4, 2.5), _paint);
    _paint.color = const Color(0x33000000);
    canvas.drawRect(Rect.fromLTWH(r.left + 2, r.bottom - 3, r.width - 4, 2), _paint);
    switch (b.kind) {
      case BrickKind.tough:
        // One pip per remaining hit, and cracks once damaged.
        _paint.color = const Color(0xCCFFFFFF);
        for (var i = 0; i < b.hp; i++) {
          canvas.drawCircle(Offset(r.center.dx + (i - (b.hp - 1) / 2) * 6, r.center.dy), 1.6, _paint);
        }
        if (b.hp < b.maxHp) {
          _stroke
            ..strokeWidth = 1
            ..color = const Color(0x99140A2E);
          canvas.drawLine(Offset(r.left + 5, r.top + 3), Offset(r.left + 11, r.bottom - 4), _stroke);
          canvas.drawLine(Offset(r.right - 6, r.top + 4), Offset(r.right - 12, r.bottom - 3), _stroke);
        }
      case BrickKind.steel:
        _paint.color = const Color(0xFF5B6478);
        canvas.drawCircle(Offset(r.left + 4, r.center.dy), 1.6, _paint);
        canvas.drawCircle(Offset(r.right - 4, r.center.dy), 1.6, _paint);
      case BrickKind.explosive:
        _paint.color = const Color(0xFFFFF1C2);
        canvas.drawCircle(r.center, 3.2, _paint);
        _stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xAA3A1200);
        canvas.drawCircle(r.center, 5.5, _stroke);
      case BrickKind.normal:
        if (b.capsule != null) {
          _paint.color = kPowerColors[b.capsule]!.withValues(alpha: 0.9);
          canvas.drawCircle(r.center, 2.6, _paint);
        }
    }
  }

  void _drawCapsules(Canvas canvas) {
    for (final c in bricks.capsules) {
      final r = Rect.fromCenter(
        center: Offset(c.x, c.y),
        width: BrickWorld.capsuleHalfW * 2,
        height: BrickWorld.capsuleHalfH * 2,
      );
      final col = kPowerColors[c.kind]!;
      _paint.color = col;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(7)), _paint);
      _paint.color = const Color(0x55FFFFFF);
      canvas.drawRect(Rect.fromLTWH(r.left + 5, r.top + 2, r.width - 10, 2), _paint);
      CanvasText.draw(
        canvas,
        kPowerLetters[c.kind]!,
        r.center,
        size: 10,
        align: Alignment.center,
        color: const Color(0xFF0B1020),
        weight: FontWeight.w900,
      );
    }
  }

  void _drawBolts(Canvas canvas) {
    _paint.color = const Color(0xFFFF4D6D);
    for (final t in bricks.bolts) {
      canvas.drawRect(Rect.fromLTWH(t.x - 1.5, t.y - 8, 3, 10), _paint);
    }
  }

  void _drawPaddle(Canvas canvas) {
    final hw = bricks.paddleHalfWidth;
    final r = Rect.fromLTWH(bricks.paddleX - hw, BrickWorld.paddleY, hw * 2, BrickWorld.paddleH);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(6));
    _paint.color = bricks.wideTime > 0 ? kPowerColors[PowerKind.wide]! : const Color(0xFFE8F1FF);
    canvas.drawRRect(rr, _paint);
    _paint.color = const Color(0xFF2EC4F1);
    canvas.drawRect(Rect.fromLTWH(r.center.dx - 8, r.top + 3, 16, r.height - 6), _paint);
    if (bricks.laserActive) {
      _paint.color = kPowerColors[PowerKind.laser]!;
      canvas.drawRect(Rect.fromLTWH(r.left + 3, r.top - 4, 6, 6), _paint);
      canvas.drawRect(Rect.fromLTWH(r.right - 9, r.top - 4, 6, 6), _paint);
    }
  }

  void _drawBalls(Canvas canvas) {
    final slow = bricks.slowTime > 0;
    for (final b in bricks.balls) {
      _paint.color = (slow ? kPowerColors[PowerKind.slow]! : const Color(0xFFFFFFFF)).withValues(alpha: 0.18);
      canvas.drawCircle(Offset(b.x - b.vx * 0.012, b.y - b.vy * 0.012), BrickWorld.ballRadius * 0.9, _paint);
      _paint.color = slow ? kPowerColors[PowerKind.slow]! : const Color(0xFFFFFFFF);
      canvas.drawCircle(Offset(b.x, b.y), BrickWorld.ballRadius, _paint);
    }
  }

  void _drawHud(Canvas canvas) {
    CanvasText.draw(canvas, 'LEVEL $level', Offset(16, hudTop), size: 18, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      '${bricks.score}',
      Offset(size.x - 16, hudTop),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
      weight: FontWeight.w900,
    );
    // Lives as small balls.
    _paint.color = const Color(0xFFE8F1FF);
    for (var i = 0; i < bricks.lives; i++) {
      canvas.drawCircle(Offset(size.x / 2 - (bricks.lives - 1) * 8 + i * 16, hudTop + 11), 5, _paint);
    }
    if (bricks.combo >= 2 && !bricks.isOver) {
      CanvasText.draw(
        canvas,
        'COMBO x${bricks.multiplier}',
        Offset(16, hudTop + 24),
        size: 12,
        color: const Color(0xFFFFC145),
        weight: FontWeight.w800,
      );
    }
    // Active power timers.
    var y = hudTop + 26;
    void timer(PowerKind k, double t, double max) {
      if (t <= 0) return;
      final rect = Rect.fromLTWH(size.x - 96, y, 80, 6);
      drawBar(canvas, rect, t / max, kPowerColors[k]!);
      CanvasText.draw(
        canvas,
        kPowerLetters[k]!,
        Offset(rect.left - 6, rect.center.dy),
        size: 10,
        align: Alignment.centerRight,
        color: kPowerColors[k]!,
      );
      y += 11;
    }

    timer(PowerKind.wide, bricks.wideTime, BrickWorld.wideDuration);
    timer(PowerKind.slow, bricks.slowTime, BrickWorld.slowDuration);
    timer(PowerKind.laser, bricks.laserTime, BrickWorld.laserDuration);

    final o = _origin;
    final s = _scale;
    if (!bricks.isOver && bricks.hasHeldBall) {
      final hint = bricks.paddleHits == 0 && bricks.lives == BrickWorld.startLives
          ? 'Drag to move · lift your finger to launch'
          : 'Lift your finger to launch';
      CanvasText.draw(
        canvas,
        hint,
        Offset(size.x / 2, o.dy + (BrickWorld.paddleY - 40) * s),
        size: 13,
        align: Alignment.center,
        color: Colors.white70,
      );
    } else if (bricks.laserActive && !_dragged && bricks.time < 60 && bricks.bolts.isEmpty) {
      CanvasText.draw(
        canvas,
        'Tap to fire',
        Offset(size.x / 2, o.dy + (BrickWorld.paddleY - 40) * s),
        size: 12,
        align: Alignment.center,
        color: kPowerColors[PowerKind.laser]!,
      );
    }
    if (bricks.isOver) {
      CanvasText.draw(
        canvas,
        bricks.won ? 'LEVEL CLEARED!' : 'OUT OF BALLS',
        Offset(size.x / 2, size.y * 0.45),
        size: 32,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: bricks.won ? const Color(0xFFFFD166) : const Color(0xFFFF4D6D),
      );
    } else if (_clock < 2.5) {
      CanvasText.draw(
        canvas,
        BrickWorld.levelName(level).toUpperCase(),
        Offset(size.x / 2, size.y * 0.55),
        size: 22,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: Colors.white.withValues(alpha: (2.5 - _clock).clamp(0.0, 1.0)),
      );
    }
  }
}
