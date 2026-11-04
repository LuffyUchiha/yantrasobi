import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'swing_world.dart';

class SwingHookCartridge extends FlameCartridge<SwingHookGame> {
  const SwingHookCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'swing-hook',
    title: 'Swing Hook',
    tagline: 'Hold to hook. Let go to fly.',
    description:
        'A one-thumb grappling acrobat. Hold anywhere to fire a rope at the nearest anchor ahead '
        'and swing like a pendulum; release at the top of the arc to sail forward. Bounce on '
        'springs, dodge spikes, chain swings to the finish gate and spin flips for style.',
    genre: 'Physics swing platformer',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFF25C54),
    icon: Icons.anchor_rounded,
    tags: ['physics', 'one-touch', 'platformer', 'levels', 'arcade'],
    controls: [
      'Hold anywhere to hook the highlighted anchor and swing',
      'Release to let go and keep your momentum',
    ],
    mechanics: ['rope pendulum', 'momentum', 'spring pads', 'spikes', 'checkpoints', 'flips', 'levels'],
    goal: 'Reach the finish gate. Falling into the pit or touching spikes costs a try; 3 retries per level.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  SwingHookGame createGame(FlameCartridgeSession<SwingHookGame> session) => SwingHookGame(session);
}

const Color _kAccent = Color(0xFFF25C54);
const Color _kGold = Color(0xFFFFD166);
const Color _kPad = Color(0xFF5BD68A);
const Color _kSpike = Color(0xFFE8475A);

/// Drawn size of the acrobat relative to its physics radius.
const double _kBodyScale = 1.3;

class SwingHookGame extends AsobiFlameGame {
  SwingHookGame(super.session, {this.seed})
    : levelNumber = math.max(1, session.context.save.intData('level', 1)),
      swing = SwingWorld(levelNumber: math.max(1, session.context.save.intData('level', 1)), seed: seed ?? 0);

  final int? seed;
  final int levelNumber;
  final SwingWorld swing;
  final Sparks sparks = Sparks();

  bool _reported = false;
  double _endDelay = 1.0;
  double _clock = 0;

  // Camera (world units).
  double _camX = 0, _camY = 0, _viewW = 15;
  bool _camReady = false;

  // Event bookkeeping (compared against world counters every frame).
  int _seenAttaches = 0, _seenBounces = 0, _seenFails = 0, _seenFlips = 0, _seenCheckpoint = -1;
  bool _seenOver = false;
  double _flipPop = 0;

  // Trail ring buffer (world coords).
  static const int _trailLen = 18;
  final Float64List _trailX = Float64List(_trailLen);
  final Float64List _trailY = Float64List(_trailLen);
  int _trailHead = 0, _trailCount = 0;
  double _trailClock = 0;

  // Smoothed trailing limb directions (unit vectors): arms 0-1, legs 2-3.
  final Float64List _limbX = Float64List(4);
  final Float64List _limbY = Float64List(4);

  final Paint _paint = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Path _path = Path();

  @override
  int get entityCount => swing.entityCount + sparks.count;

  @override
  Color backgroundColor() => const Color(0xFF1A1030);

  // ---------------------------------------------------------------- camera
  double get _scale => size.x / _viewW;
  double _sx(double x) => (x - _camX) * _scale + size.x / 2;
  double _sy(double y) => (y - _camY) * _scale + size.y * 0.5;
  Offset _s(double x, double y) => Offset(_sx(x), _sy(y));

  double get _targetViewW => 15 + 6 * ((swing.speed - 8) / 14).clamp(0.0, 1.0);
  double get _targetCamX => swing.px + _viewW * 0.16;
  double get _targetCamY => (swing.py * 0.6 + 2.4).clamp(0.0, 10.0);

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (swing.isOver) return;
    swing.press();
  }

  @override
  void onPointerUp(Vector2 position) {
    if (swing.isOver) return;
    swing.release();
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    swing.update(dt);
    sparks.update(dt);
    if (_flipPop > 0) _flipPop = math.max(0, _flipPop - dt);
    _updateCamera(dt);
    _updateTrail(dt);
    _updateLimbs(dt);
    _handleEvents();
    if (swing.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _updateCamera(double dt) {
    if (!_camReady) {
      _viewW = _targetViewW;
      _camX = _targetCamX;
      _camY = _targetCamY;
      _camReady = true;
      return;
    }
    if (!swing.alive) return; // hold the frame while the acrobat is down
    final k = 1 - math.exp(-dt * 5);
    _viewW += (_targetViewW - _viewW) * (1 - math.exp(-dt * 1.5));
    _camX += (_targetCamX - _camX) * k;
    _camY += (_targetCamY - _camY) * k * 0.6;
  }

  void _updateTrail(double dt) {
    if (!swing.alive) {
      _trailCount = 0;
      return;
    }
    _trailClock += dt;
    if (_trailClock < 1 / 60) return;
    _trailClock = 0;
    _trailX[_trailHead] = swing.px;
    _trailY[_trailHead] = swing.py;
    _trailHead = (_trailHead + 1) % _trailLen;
    if (_trailCount < _trailLen) _trailCount++;
  }

  void _updateLimbs(double dt) {
    final ux = math.cos(swing.bodyAngle), uy = math.sin(swing.bodyAngle);
    final sp = swing.speed;
    final tx = sp > 0.1 ? -swing.vx / sp : 0.0, ty = sp > 0.1 ? -swing.vy / sp : 0.0;
    final drag = (sp / 18).clamp(0.0, 0.75);
    final k = 1 - math.exp(-dt * 12);
    for (var i = 0; i < 4; i++) {
      double bx, by;
      if (i < 2) {
        if (swing.attached) {
          bx = ux;
          by = uy;
        } else {
          final a = i == 0 ? 2.3 : -2.3;
          bx = ux * math.cos(a) - uy * math.sin(a);
          by = ux * math.sin(a) + uy * math.cos(a);
        }
      } else {
        final a = i == 2 ? 0.35 : -0.35;
        bx = -(ux * math.cos(a) - uy * math.sin(a));
        by = -(ux * math.sin(a) + uy * math.cos(a));
      }
      final w = (i < 2 && swing.attached) ? drag * 0.2 : drag;
      var dx = bx * (1 - w) + tx * w, dy = by * (1 - w) + ty * w;
      final l = math.sqrt(dx * dx + dy * dy);
      if (l > 1e-6) {
        dx /= l;
        dy /= l;
      }
      _limbX[i] += (dx - _limbX[i]) * k;
      _limbY[i] += (dy - _limbY[i]) * k;
    }
  }

  void _handleEvents() {
    final reduced = ctx.settings.reducedEffects;
    if (swing.attaches != _seenAttaches) {
      _seenAttaches = swing.attaches;
      audio.play(Sfx.whoosh);
      audio.haptic(HapticKind.selection);
    }
    if (swing.bounces != _seenBounces) {
      _seenBounces = swing.bounces;
      audio.play(Sfx.pop);
      audio.haptic(HapticKind.medium);
      sparks.burst(_sx(swing.px), _sy(swing.py + 0.4), reduced ? 4 : 14, _kPad, speed: 180);
    }
    if (swing.fails != _seenFails) {
      _seenFails = swing.fails;
      audio.play(Sfx.hit);
      audio.haptic(HapticKind.heavy);
      sparks.burst(_sx(swing.px), _sy(swing.py), reduced ? 8 : 30, _kSpike, speed: 260);
    }
    if (swing.flips != _seenFlips) {
      _seenFlips = swing.flips;
      _flipPop = 0.9;
      audio.play(Sfx.coin);
      sparks.burst(_sx(swing.px), _sy(swing.py), reduced ? 4 : 12, _kGold, speed: 160);
    }
    if (swing.checkpoint != _seenCheckpoint) {
      _seenCheckpoint = swing.checkpoint;
      if (_seenCheckpoint >= 0) {
        audio.play(Sfx.powerup);
        final c = swing.level.checkpoints[_seenCheckpoint];
        sparks.burst(_sx(c.x), _sy(c.y - 1.5), reduced ? 4 : 16, _kPad, speed: 150);
      }
    }
    if (swing.isOver && !_seenOver) {
      _seenOver = true;
      if (swing.won) {
        audio.play(Sfx.win);
        sparks.burst(_sx(swing.px), _sy(swing.py), reduced ? 12 : 60, _kGold, speed: 320);
      } else {
        audio.play(Sfx.lose);
      }
    }
  }

  void _report() {
    _reported = true;
    final won = swing.won;
    if (won) {
      session.context.save.data['level'] = levelNumber + 1;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: swing.score,
        won: won,
        headline: won
            ? '${swing.level.name} cleared! Level ${levelNumber + 1} unlocked.'
            : 'Out of tries on level $levelNumber.',
        details: {
          'Level': '$levelNumber · ${swing.level.name}',
          'Flips': '${swing.flips}',
          'Falls': '${swing.fails}',
          'Progress': '${(swing.progress * 100).round()}%',
          if (won) 'Clear bonus': '${swing.clearBonus}',
          'Time': '${swing.elapsed.toStringAsFixed(1)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    if (!_camReady) _updateCamera(0);
    _drawBackdrop(canvas);
    _drawPit(canvas);
    _drawStart(canvas);
    _drawFinish(canvas);
    _drawCheckpoints(canvas);
    _drawSpikes(canvas);
    _drawPads(canvas);
    _drawAnchors(canvas);
    _drawTrail(canvas);
    if (swing.alive) _drawAcrobat(canvas);
    sparks.render(canvas);
    _drawHud(canvas);
  }

  double get _left => _camX - _viewW / 2 - 1;
  double get _right => _camX + _viewW / 2 + 1;

  void _drawBackdrop(Canvas canvas) {
    // Distant striped tents scrolling at a slower parallax rate.
    const par = 0.35;
    final s = _scale * 0.8;
    final baseY = size.y * 0.78;
    final shift = _camX * par;
    final first = ((shift - _viewW) / 11).floor();
    for (var i = first; i < first + 6; i++) {
      final h = 5.0 + ((i * 7919) % 5);
      final w = 7.0 + ((i * 104729) % 4);
      final cx = (i * 11 - shift) * s + size.x / 2;
      _path
        ..reset()
        ..moveTo(cx - w / 2 * s, baseY)
        ..lineTo(cx, baseY - h * s)
        ..lineTo(cx + w / 2 * s, baseY)
        ..close();
      _paint.color = i.isEven ? const Color(0xFF2A1A45) : const Color(0xFF241638);
      canvas.drawPath(_path, _paint);
      _stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF3A2560);
      canvas.drawLine(Offset(cx, baseY - h * s), Offset(cx, baseY - h * s - 0.9 * s), _stroke);
    }
    _paint.color = const Color(0xFF20133A);
    canvas.drawRect(Rect.fromLTWH(0, baseY, size.x, size.y - baseY), _paint);
  }

  void _drawPit(Canvas canvas) {
    final y = _sy(swing.level.killY);
    if (y > size.y) return;
    _paint.color = const Color(0xFF0B0614);
    canvas.drawRect(Rect.fromLTWH(0, y, size.x, size.y - y), _paint);
    final pulse = 0.5 + 0.5 * math.sin(_clock * 3);
    _stroke
      ..strokeWidth = 2
      ..color = _kSpike.withValues(alpha: 0.3 + 0.3 * pulse);
    canvas.drawLine(Offset(0, y), Offset(size.x, y), _stroke);
  }

  void _drawStart(Canvas canvas) {
    final l = swing.level;
    if (l.startX + 2 < _left) return;
    final r = Rect.fromLTRB(_sx(l.startX - 1.5), _sy(l.startY + 0.4), _sx(l.startX + 1), _sy(l.killY));
    _paint.color = const Color(0xFF3A2A5C);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), _paint);
    _paint.color = _kAccent;
    canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width, 0.25 * _scale), _paint);
  }

  void _drawFinish(Canvas canvas) {
    final fx = swing.level.finishX;
    if (fx - 1 > _right || fx + 1 < _left) return;
    final bottom = math.min(size.y, _sy(swing.level.killY));
    final w = 0.7 * _scale;
    final cell = w / 2;
    // Rows are anchored to world y = 0 so the pattern scrolls with the level.
    var row = ((0 - _sy(0)) / cell).floor();
    for (var y = _sy(0) + row * cell; y < bottom; y += cell) {
      for (var c = 0; c < 2; c++) {
        _paint.color = (row + c).isEven ? Colors.white : const Color(0xFF221833);
        canvas.drawRect(Rect.fromLTWH(_sx(fx) - w / 2 + c * cell, y, cell, cell), _paint);
      }
      row++;
    }
    CanvasText.draw(
      canvas,
      'FINISH',
      Offset(_sx(fx) + w, _sy(1)),
      size: 14,
      weight: FontWeight.w900,
      color: _kGold,
      align: Alignment.centerLeft,
    );
  }

  void _drawCheckpoints(Canvas canvas) {
    final cps = swing.level.checkpoints;
    for (var i = 0; i < cps.length; i++) {
      final c = cps[i];
      if (c.x < _left || c.x > _right) continue;
      final on = i <= swing.checkpoint;
      _stroke
        ..strokeWidth = 0.08 * _scale
        ..color = const Color(0xFFB7A8D6);
      canvas.drawLine(_s(c.x, c.y + 1.2), _s(c.x, c.y - 2), _stroke);
      final wave = math.sin(_clock * 6) * 0.1;
      _path
        ..reset()
        ..moveTo(_sx(c.x), _sy(c.y - 2))
        ..lineTo(_sx(c.x + 1.1), _sy(c.y - 1.7 + wave))
        ..lineTo(_sx(c.x), _sy(c.y - 1.4))
        ..close();
      _paint.color = on ? _kPad : const Color(0xFF6C5A8E);
      canvas.drawPath(_path, _paint);
    }
  }

  void _drawSpikes(Canvas canvas) {
    const tooth = 0.5;
    for (final s in swing.level.spikes) {
      if (s.x > _right || s.x + s.w < _left) continue;
      final x0 = math.max(s.x, _left), x1 = math.min(s.x + s.w, _right);
      _paint.color = const Color(0xFF4A1A2A);
      canvas.drawRect(Rect.fromLTRB(_sx(x0), _sy(s.y + s.h * 0.25), _sx(x1), _sy(s.y + s.h * 0.75)), _paint);
      _paint.color = _kSpike;
      _path.reset();
      if (s.w >= s.h) {
        final start = s.x + ((x0 - s.x) / tooth).floor() * tooth;
        for (var x = start; x < x1; x += tooth) {
          final xe = math.min(x + tooth, s.x + s.w);
          final xm = (x + xe) / 2;
          _path
            ..moveTo(_sx(x), _sy(s.y + s.h * 0.5))
            ..lineTo(_sx(xm), _sy(s.y))
            ..lineTo(_sx(xe), _sy(s.y + s.h * 0.5))
            ..moveTo(_sx(x), _sy(s.y + s.h * 0.5))
            ..lineTo(_sx(xm), _sy(s.y + s.h))
            ..lineTo(_sx(xe), _sy(s.y + s.h * 0.5));
        }
      } else {
        for (var y = s.y; y < s.y + s.h; y += tooth) {
          final ye = math.min(y + tooth, s.y + s.h);
          final ym = (y + ye) / 2;
          _path
            ..moveTo(_sx(s.x + s.w * 0.5), _sy(y))
            ..lineTo(_sx(s.x), _sy(ym))
            ..lineTo(_sx(s.x + s.w * 0.5), _sy(ye))
            ..moveTo(_sx(s.x + s.w * 0.5), _sy(y))
            ..lineTo(_sx(s.x + s.w), _sy(ym))
            ..lineTo(_sx(s.x + s.w * 0.5), _sy(ye));
        }
      }
      canvas.drawPath(_path, _paint);
    }
  }

  void _drawPads(Canvas canvas) {
    final pads = swing.level.pads;
    for (var i = 0; i < pads.length; i++) {
      final p = pads[i];
      if (p.x > _right || p.x + p.w < _left) continue;
      final squash = swing.padFlash[i] > 0 ? 0.25 * math.sin(swing.padFlash[i] / 0.3 * math.pi) : 0.0;
      final top = p.y + squash;
      // Spring coils.
      _stroke
        ..strokeWidth = 0.08 * _scale
        ..color = const Color(0xFF9AA4B8);
      final coils = math.max(2, (p.w / 1.5).floor());
      for (var c = 0; c < coils; c++) {
        final cx = p.x + (c + 0.5) * p.w / coils;
        _path.reset();
        _path.moveTo(_sx(cx), _sy(top + 0.3));
        for (var z = 1; z <= 4; z++) {
          final zy = top + 0.3 + z * (1.2 - squash) / 4;
          _path.lineTo(_sx(cx + (z.isOdd ? 0.25 : -0.25)), _sy(zy));
        }
        canvas.drawPath(_path, _stroke);
      }
      _paint.color = swing.padFlash[i] > 0 ? Colors.white : _kPad;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(_sx(p.x), _sy(top), _sx(p.x + p.w), _sy(top + 0.35)),
          Radius.circular(0.15 * _scale),
        ),
        _paint,
      );
    }
  }

  void _drawAnchors(Canvas canvas) {
    final pulse = 0.5 + 0.5 * math.sin(_clock * 8);
    for (var i = 0; i < swing.anchors.length; i++) {
      final a = swing.anchors[i];
      final d = a.def;
      if (a.x < _left - 3 || a.x > _right + 3) continue;
      if (d.moving) {
        _stroke
          ..strokeWidth = 0.06 * _scale
          ..color = const Color(0x667A68A6);
        canvas.drawLine(_s(d.x - d.dx, d.y - d.dy), _s(d.x + d.dx, d.y + d.dy), _stroke);
      }
      final c = _s(a.x, a.y);
      final r = 0.28 * _scale;
      if (i == swing.targetIndex) {
        _stroke
          ..strokeWidth = 0.08 * _scale
          ..color = _kAccent.withValues(alpha: 0.5 + 0.5 * pulse);
        canvas.drawCircle(c, r * (2.0 + 0.4 * pulse), _stroke);
        _stroke
          ..strokeWidth = 0.03 * _scale
          ..color = _kAccent.withValues(alpha: 0.35);
        canvas.drawLine(_s(swing.px, swing.py), c, _stroke);
      }
      _paint.color = const Color(0xFF2A1F40);
      canvas.drawCircle(c, r * 1.25, _paint);
      _paint.color = i == swing.ropeIndex ? Colors.white : (d.moving ? const Color(0xFF8FD3FF) : _kGold);
      canvas.drawCircle(c, r, _paint);
    }
    if (swing.attached) {
      final a = swing.anchors[swing.ropeIndex];
      final ux = math.cos(swing.bodyAngle), uy = math.sin(swing.bodyAngle);
      _stroke
        ..strokeWidth = math.max(1.5, 0.07 * _scale)
        ..color = const Color(0xFFF5EBDD);
      canvas.drawLine(
        _s(swing.px + ux * 0.65 * _kBodyScale, swing.py + uy * 0.65 * _kBodyScale),
        _s(a.x, a.y),
        _stroke,
      );
    }
  }

  void _drawTrail(Canvas canvas) {
    if (_trailCount < 2 || ctx.settings.reducedEffects) return;
    _stroke.strokeWidth = 0.12 * _scale;
    for (var i = 1; i < _trailCount; i++) {
      final a = (_trailHead - _trailCount + i - 1 + _trailLen * 2) % _trailLen;
      final b = (a + 1) % _trailLen;
      _stroke.color = _kAccent.withValues(alpha: 0.35 * i / _trailCount);
      canvas.drawLine(_s(_trailX[a], _trailY[a]), _s(_trailX[b], _trailY[b]), _stroke);
    }
  }

  void _drawAcrobat(Canvas canvas) {
    const k = _kBodyScale;
    final px = swing.px, py = swing.py;
    final ux = math.cos(swing.bodyAngle) * k, uy = math.sin(swing.bodyAngle) * k;
    final hipX = px - ux * 0.3, hipY = py - uy * 0.3;
    final neckX = px + ux * 0.3, neckY = py + uy * 0.3;
    _stroke
      ..strokeWidth = math.max(2, 0.15 * _scale)
      ..color = Colors.white;
    canvas.drawLine(_s(hipX, hipY), _s(neckX, neckY), _stroke);
    for (var i = 0; i < 4; i++) {
      final bx = i < 2 ? neckX : hipX, by = i < 2 ? neckY : hipY;
      final len = (i < 2 ? 0.45 : 0.55) * k;
      _stroke.color = i < 2 ? Colors.white : const Color(0xFFFFE0D6);
      canvas.drawLine(_s(bx, by), _s(bx + _limbX[i] * len, by + _limbY[i] * len), _stroke);
    }
    _paint.color = _kAccent;
    canvas.drawCircle(_s(px + ux * 0.58, py + uy * 0.58), 0.24 * k * _scale, _paint);
    _paint.color = Colors.white;
    canvas.drawCircle(_s(px + ux * 0.62 + uy * 0.06, py + uy * 0.62 - ux * 0.06), 0.07 * k * _scale, _paint);
  }

  void _drawHud(Canvas canvas) {
    final top = hudTop;
    CanvasText.draw(canvas, 'LEVEL $levelNumber', Offset(16, top), size: 18, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      swing.level.name,
      Offset(16, top + 22),
      size: 12,
      color: Colors.white60,
      weight: FontWeight.w600,
    );
    CanvasText.draw(
      canvas,
      '${swing.score}',
      Offset(size.x - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: _kGold,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      'FLIPS ${swing.flips}',
      Offset(size.x - 16, top + 26),
      size: 12,
      align: Alignment.topRight,
      color: Colors.white70,
    );
    // Remaining tries.
    for (var i = 0; i <= kSwingRetries; i++) {
      final alive = i < swing.retriesLeft + (swing.alive || swing.won ? 1 : 0);
      _paint.color = alive ? _kAccent : const Color(0x44FFFFFF);
      canvas.drawCircle(Offset(size.x / 2 - 21 + i * 14, top + 10), 5, _paint);
    }
    drawBar(
      canvas,
      Rect.fromLTWH(16, top + 44, size.x - 32, 5),
      swing.progress,
      _kAccent,
      back: const Color(0x33FFFFFF),
    );
    if (_flipPop > 0 && swing.alive) {
      CanvasText.draw(
        canvas,
        'FLIP +$kSwingFlipPoints',
        _s(swing.px, swing.py - 1.4 - (0.9 - _flipPop)),
        size: 16,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: _kGold.withValues(alpha: (_flipPop / 0.9).clamp(0.0, 1.0)),
      );
    }
    if (!swing.isOver && swing.attaches == 0 && swing.fails == 0) {
      CanvasText.draw(
        canvas,
        'Hold anywhere to swing · release to fly',
        Offset(size.x / 2, size.y - safePadding.bottom - 28),
        size: 14,
        align: Alignment.bottomCenter,
        color: Colors.white70,
      );
    }
    if (swing.phase == SwingPhase.dying && !swing.isOver) {
      CanvasText.draw(
        canvas,
        swing.retriesLeft > 0 ? 'OUCH! ${swing.retriesLeft} left' : 'LAST FALL',
        Offset(size.x / 2, size.y * 0.4),
        size: 26,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: _kSpike,
      );
    }
    if (swing.isOver) {
      CanvasText.draw(
        canvas,
        swing.won ? 'COURSE CLEAR!' : 'OUT OF TRIES',
        Offset(size.x / 2, size.y * 0.4),
        size: 34,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: swing.won ? _kGold : _kSpike,
      );
    }
  }
}
