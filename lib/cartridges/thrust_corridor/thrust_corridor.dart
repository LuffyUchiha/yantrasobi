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
import 'thrust_world.dart';

class ThrustCorridorCartridge extends FlameCartridge<ThrustCorridorGame> {
  const ThrustCorridorCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'thrust-corridor',
    title: 'Thrust Corridor',
    tagline: 'Hold to fly. Let go to drop. Do not touch the lasers.',
    description:
        'An endless service corridor patrolled by laser bars, spinning beams, pulsing '
        'electric gates and homing missiles. Hold anywhere to fire your jetpack, release '
        'to fall, and thread the gaps as the corridor speeds up. Grab coins, a one-hit '
        'shield, a coin magnet, or hop into a Strider walker for a few seconds.',
    genre: 'Endless jetpack flyer',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFFE347),
    icon: Icons.rocket_launch_rounded,
    tags: ['endless', 'one-thumb', 'score-attack', 'side-scroller', 'hold-to-fly'],
    controls: [
      'Hold anywhere to thrust upward, release to fall',
      'Touching the floor means running; the ceiling stops you',
      'In the Strider walker: tap to jump',
    ],
    mechanics: [
      'hold-to-thrust',
      'static & rotating lasers',
      'homing missiles with warnings',
      'pulsing electric gates',
      'shield / magnet / walker vehicle',
      'speed ramp',
    ],
    goal: 'Fly as far as you can. One unshielded hit ends the run. Score = metres + 5 per coin.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  ThrustCorridorGame createGame(FlameCartridgeSession<ThrustCorridorGame> session) =>
      ThrustCorridorGame(session);
}

class ThrustCorridorGame extends AsobiFlameGame {
  ThrustCorridorGame(super.session, {this.seed})
    : run = ThrustWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff),
      best = session.context.save.bestScore;

  final int? seed;

  /// The rules object (FlameGame already owns `world`).
  final ThrustWorld run;
  final int best;
  final Sparks sparks = Sparks(capacity: 240);

  static const Color _accent = Color(0xFFFFE347);
  static const Color _laser = Color(0xFFFF3B5C);
  static const Color _gate = Color(0xFF5CE1FF);
  static const Color _missile = Color(0xFFFF9F1C);
  static const Color _coin = Color(0xFFFFC233);
  static const Color _visor = Color(0xFF39F3C4);
  static const Color _wall = Color(0xFF151A2E);

  final Paint _paint = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _back = Paint();
  final Path _path = Path();

  // Corridor mapping, refreshed on resize.
  double _top = 0;
  double _bottom = 0;
  double _scale = 1;
  double _heroX = 0;

  double _shake = 0;
  double _flash = 0;
  double _endTimer = 0;
  bool _reported = false;

  @override
  int get entityCount => run.entityCount + sparks.count;

  double _sx(double x) => _heroX + (x - run.distance) * _scale;
  double _sy(double y) => _bottom - y * _scale;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _top = hudTop + 28;
    _bottom = size.y - safePadding.bottom - 18;
    if (_bottom - _top < 160) _bottom = _top + 160;
    _scale = (_bottom - _top) / ThrustWorld.height;
    _heroX = size.x * 0.25;
    _back.shader = Gradient.linear(
      Offset(0, _top),
      Offset(0, _bottom),
      const [Color(0xFF1B2140), Color(0xFF10142A), Color(0xFF1B2140)],
      const [0, 0.5, 1],
    );
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) => run.press();

  @override
  void onPointerUp(Vector2 position) => run.release();

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    final w = run;
    w.update(dt);
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      switch (e.kind) {
        case ThrustEventKind.coin:
          audio.play(Sfx.coin);
          if (!reduced) _burst(e.x, e.y, 5, _coin, 120);
        case ThrustEventKind.pickup:
          audio.play(Sfx.powerup);
          audio.haptic(HapticKind.medium);
          _burst(e.x, e.y, reduced ? 6 : 20, _pickupColor(e.pickup!), 200);
        case ThrustEventKind.shieldBreak:
        case ThrustEventKind.striderBreak:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.heavy);
          _burst(e.x, e.y, reduced ? 8 : 28, e.kind == ThrustEventKind.shieldBreak ? _visor : _accent, 260);
          _flash = 0.2;
          if (!reduced) _shake = 0.2;
        case ThrustEventKind.striderEnd:
          audio.play(Sfx.pop);
        case ThrustEventKind.crash:
          audio.play(Sfx.hit);
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
          _burst(e.x, e.y, reduced ? 10 : 48, _laser, 320);
          _flash = 0.45;
          if (!reduced) _shake = 0.4;
        case ThrustEventKind.missileWarn:
          audio.play(Sfx.tap);
          audio.haptic(HapticKind.selection);
        case ThrustEventKind.missileLaunch:
          audio.play(Sfx.whoosh);
        case ThrustEventKind.stomp:
          if (!reduced) _burst(e.x, 0.1, 4, Colors.white70, 90);
      }
    }
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (_flash > 0) _flash -= dt;
    if (w.isOver) {
      _endTimer += dt;
      if (_endTimer >= 0.9 && !_reported) _report(w);
    }
  }

  void _burst(double x, double y, int n, Color color, double speed) {
    if (n <= 0 || size.x <= 0) return;
    sparks.burst(_sx(x), _sy(y), n, color, speed: speed);
  }

  void _report(ThrustWorld w) {
    _reported = true;
    final m = w.metres;
    finish(
      RunResult(
        score: w.score,
        headline: w.score > best && best > 0
            ? 'New best! Hit ${w.crashedBy ?? 'a hazard'} at $m m'
            : 'Hit ${w.crashedBy ?? 'a hazard'} at $m m',
        details: {
          'Distance': '$m m',
          'Coins': '${w.coins}',
          'Hits absorbed': '${w.hitsAbsorbed}',
          'Top speed': '${(w.topSpeed * 3.6).round()} km/h',
          'Time': '${w.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  static Color _pickupColor(PickupKind k) => switch (k) {
    PickupKind.shield => _visor,
    PickupKind.magnet => const Color(0xFFFF5CF0),
    PickupKind.strider => _accent,
  };

  static String _pickupLabel(PickupKind k) => switch (k) {
    PickupKind.shield => 'S',
    PickupKind.magnet => 'M',
    PickupKind.strider => 'W',
  };

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    final w = run;
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 10;
      canvas.translate(math.sin(w.time * 90) * m, math.cos(w.time * 77) * m);
    }
    _drawCorridor(canvas, w);
    _drawCoins(canvas, w);
    _drawPickups(canvas, w);
    _drawGates(canvas, w);
    _drawLasers(canvas, w);
    _drawMissiles(canvas, w);
    if (!w.isOver) w.inStrider ? _drawStrider(canvas, w) : _drawPilot(canvas, w);
    sparks.render(canvas);
    canvas.restore();
    _drawWarnings(canvas, w);
    if (_flash > 0) {
      _paint.color = Colors.white.withValues(alpha: (_flash * 0.8).clamp(0.0, 0.45));
      canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
    }
    _drawHud(canvas, w);
  }

  void _drawCorridor(Canvas canvas, ThrustWorld w) {
    canvas.drawRect(Rect.fromLTRB(0, _top, size.x, _bottom), _back);
    // Back-wall pillars and pipes scroll at half speed for depth.
    final span = 6 * _scale;
    final off = (w.distance * 0.5 * _scale) % span;
    _paint.color = const Color(0xFF222A4D);
    for (var x = -off; x < size.x + span; x += span) {
      canvas.drawRect(Rect.fromLTRB(x, _top, x + span * 0.18, _bottom), _paint);
    }
    _stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF2B3560);
    for (final f in const [0.3, 0.68]) {
      final y = _top + (_bottom - _top) * f;
      canvas.drawLine(Offset(0, y), Offset(size.x, y), _stroke);
    }
    // Floor and ceiling plates with scrolling hazard stripes.
    _paint.color = _wall;
    canvas.drawRect(Rect.fromLTRB(0, 0, size.x, _top), _paint);
    canvas.drawRect(Rect.fromLTRB(0, _bottom, size.x, size.y), _paint);
    final stripe = 1.2 * _scale;
    final soff = (w.distance * _scale) % (stripe * 2);
    _stroke
      ..strokeWidth = math.max(2, stripe * 0.45)
      ..strokeCap = StrokeCap.butt
      ..color = const Color(0xFF3A3F55);
    for (var x = -soff - stripe; x < size.x + stripe; x += stripe * 2) {
      canvas.drawLine(Offset(x, _bottom + 14), Offset(x + 8, _bottom + 5), _stroke);
      canvas.drawLine(Offset(x, _top - 5), Offset(x + 8, _top - 14), _stroke);
    }
    _stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF6C7AB8);
    canvas.drawLine(Offset(0, _bottom), Offset(size.x, _bottom), _stroke);
    canvas.drawLine(Offset(0, _top), Offset(size.x, _top), _stroke);
  }

  bool _visible(double x, double pad) {
    final sx = _sx(x);
    return sx > -pad && sx < size.x + pad;
  }

  void _drawCoins(Canvas canvas, ThrustWorld w) {
    final r = ThrustWorld.coinRadius * _scale;
    for (final c in w.coinItems) {
      if (!_visible(c.x, r)) continue;
      final spin = math.cos(w.time * 5 + c.x).abs() * 0.75 + 0.25;
      final o = Offset(_sx(c.x), _sy(c.y));
      _paint.color = _coin;
      canvas.drawOval(Rect.fromCenter(center: o, width: r * 2 * spin, height: r * 2), _paint);
      _stroke
        ..strokeWidth = math.max(1, r * 0.22)
        ..color = const Color(0xFFFFF0B8);
      canvas.drawOval(Rect.fromCenter(center: o, width: r * 1.1 * spin, height: r * 1.1), _stroke);
    }
  }

  void _drawPickups(Canvas canvas, ThrustWorld w) {
    final r = ThrustWorld.pickupRadius * _scale;
    for (final p in w.pickups) {
      if (!_visible(p.x, r * 2)) continue;
      final cx = _sx(p.x), cy = _sy(p.y + math.sin(w.time * 4) * 0.2);
      final color = _pickupColor(p.kind);
      _path.reset();
      for (var i = 0; i < 6; i++) {
        final a = math.pi / 6 + i * math.pi / 3;
        final px = cx + math.cos(a) * r, py = cy + math.sin(a) * r;
        i == 0 ? _path.moveTo(px, py) : _path.lineTo(px, py);
      }
      _path.close();
      _paint.color = color.withValues(alpha: 0.25);
      canvas.drawCircle(Offset(cx, cy), r * 1.5, _paint);
      _paint.color = color;
      canvas.drawPath(_path, _paint);
      _label(canvas, _pickupLabel(p.kind), cx, cy, r / 24, const Color(0xFF14102A));
    }
  }

  void _drawLasers(Canvas canvas, ThrustWorld w) {
    final er = math.max(4.0, 0.32 * _scale);
    for (final l in w.lasers) {
      if (_sx(l.maxX) < -er || _sx(l.minX) > size.x + er) continue;
      final a = l.angleAt(w.distance);
      final dx = math.cos(a) * l.halfLen, dy = math.sin(a) * l.halfLen;
      final p0 = Offset(_sx(l.cx - dx), _sy(l.cy - dy));
      final p1 = Offset(_sx(l.cx + dx), _sy(l.cy + dy));
      final flicker = 0.85 + 0.15 * math.sin(w.time * 31 + l.cx);
      _stroke
        ..strokeWidth = ThrustWorld.laserHalfWidth * 2 * _scale * 2.6
        ..color = _laser.withValues(alpha: 0.22 * flicker);
      canvas.drawLine(p0, p1, _stroke);
      _stroke
        ..strokeWidth = ThrustWorld.laserHalfWidth * 2 * _scale
        ..color = _laser;
      canvas.drawLine(p0, p1, _stroke);
      _stroke
        ..strokeWidth = math.max(1.5, ThrustWorld.laserHalfWidth * _scale * 0.7)
        ..color = const Color(0xFFFFE0E6).withValues(alpha: flicker);
      canvas.drawLine(p0, p1, _stroke);
      _emitter(canvas, p0, er);
      _emitter(canvas, p1, er);
      if (l.rotating) {
        final c = Offset(_sx(l.cx), _sy(l.cy));
        _paint.color = const Color(0xFF2A2F45);
        canvas.drawCircle(c, er * 1.2, _paint);
        _stroke
          ..strokeWidth = 2.5
          ..color = Colors.white70;
        canvas.drawArc(Rect.fromCircle(center: c, radius: er * 0.8), a, math.pi * 1.2, false, _stroke);
      }
    }
  }

  void _emitter(Canvas canvas, Offset p, double er) {
    _paint.color = const Color(0xFF2A2F45);
    canvas.drawCircle(p, er, _paint);
    _stroke
      ..strokeWidth = 2
      ..color = _laser;
    canvas.drawCircle(p, er, _stroke);
  }

  void _drawGates(Canvas canvas, ThrustWorld w) {
    final pw = math.max(5.0, 0.36 * _scale);
    for (final g in w.gates) {
      if (!_visible(g.x, pw * 2)) continue;
      final x = _sx(g.x), y0 = _sy(g.y0), y1 = _sy(g.y1);
      final on = g.onAt(w.distance);
      final soon = !on && g.untilOn(w.distance) < 0.3;
      if (on) {
        // Jagged arc, re-rolled 20 times a second.
        final seg = math.max(4, ((y0 - y1) / 14).round());
        final roll = (w.time * 20).floor();
        _path
          ..reset()
          ..moveTo(x, y0);
        for (var i = 1; i < seg; i++) {
          final h = ((i * 73 + roll * 37 + g.x.floor() * 11) % 17) / 16 - 0.5;
          _path.lineTo(x + h * pw * 1.6, y0 + (y1 - y0) * i / seg);
        }
        _path.lineTo(x, y1);
        _stroke
          ..strokeWidth = pw * 1.6
          ..color = _gate.withValues(alpha: 0.25);
        canvas.drawPath(_path, _stroke);
        _stroke
          ..strokeWidth = 2.5
          ..color = Colors.white;
        canvas.drawPath(_path, _stroke);
      } else {
        _stroke
          ..strokeWidth = 1.5
          ..color = _gate.withValues(alpha: soon && (w.time * 16).floor().isEven ? 0.8 : 0.18);
        canvas.drawLine(Offset(x, y0), Offset(x, y1), _stroke);
      }
      _post(canvas, x, y0, pw, on);
      _post(canvas, x, y1, pw, on);
    }
  }

  void _post(Canvas canvas, double x, double y, double pw, bool on) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, y), width: pw * 1.6, height: pw),
      const Radius.circular(3),
    );
    _paint.color = const Color(0xFF2A2F45);
    canvas.drawRRect(rect, _paint);
    _stroke
      ..strokeWidth = 2
      ..color = on ? _gate : _gate.withValues(alpha: 0.45);
    canvas.drawRRect(rect, _stroke);
  }

  void _drawMissiles(Canvas canvas, ThrustWorld w) {
    final r = ThrustWorld.missileRadius * _scale;
    for (final m in w.missiles) {
      if (!m.launched || m.exploded) continue;
      final mx = m.xAt(w.tick);
      if (!_visible(mx, r * 6)) continue;
      final cx = _sx(mx), cy = _sy(m.y);
      // Exhaust trail to the right (it flies left).
      final flame = 0.7 + 0.3 * math.sin(w.time * 50);
      _paint.color = const Color(0xFFFFD166).withValues(alpha: 0.55);
      canvas.drawOval(
        Rect.fromLTRB(cx + r * 1.2, cy - r * 0.5, cx + r * (2.6 + 2.2 * flame), cy + r * 0.5),
        _paint,
      );
      _path
        ..reset()
        ..moveTo(cx - r * 1.6, cy)
        ..lineTo(cx - r * 0.6, cy - r * 0.7)
        ..lineTo(cx + r * 1.4, cy - r * 0.7)
        ..lineTo(cx + r * 1.4, cy + r * 0.7)
        ..lineTo(cx - r * 0.6, cy + r * 0.7)
        ..close();
      _paint.color = const Color(0xFFDDE3F0);
      canvas.drawPath(_path, _paint);
      _paint.color = _missile;
      canvas.drawRect(Rect.fromLTRB(cx + r * 0.6, cy - r * 0.7, cx + r * 1.0, cy + r * 0.7), _paint);
      _path
        ..reset()
        ..moveTo(cx + r * 0.8, cy - r * 0.7)
        ..lineTo(cx + r * 1.6, cy - r * 1.3)
        ..lineTo(cx + r * 1.4, cy - r * 0.7)
        ..moveTo(cx + r * 0.8, cy + r * 0.7)
        ..lineTo(cx + r * 1.6, cy + r * 1.3)
        ..lineTo(cx + r * 1.4, cy + r * 0.7);
      canvas.drawPath(_path, _paint);
    }
  }

  /// Missile warnings at the right edge: amber while tracking, red once locked.
  void _drawWarnings(Canvas canvas, ThrustWorld w) {
    if (w.isOver) return;
    final x = size.x - 26;
    for (final m in w.missiles) {
      if (!m.warned || m.launched || m.exploded) continue;
      final left = (m.launchAtX - w.distance) / w.speed;
      final rate = left < 0.4 ? 18 : 8;
      final on = (w.time * rate).floor().isEven;
      final color = m.locked ? _laser : _missile;
      final y = _sy(m.y).clamp(_top + 16, _bottom - 16);
      const s = 16.0;
      _paint.color = color.withValues(alpha: 0.18);
      canvas.drawCircle(Offset(x, y), s * 1.5, _paint);
      _path
        ..reset()
        ..moveTo(x, y - s)
        ..lineTo(x + s * 0.95, y + s * 0.7)
        ..lineTo(x - s * 0.95, y + s * 0.7)
        ..close();
      _paint.color = color.withValues(alpha: on ? 0.95 : 0.45);
      canvas.drawPath(_path, _paint);
      CanvasText.draw(
        canvas,
        '!',
        Offset(x, y + 2),
        size: 14,
        align: Alignment.center,
        color: const Color(0xFF1A1000),
        weight: FontWeight.w900,
      );
      if (m.locked) {
        _stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.35);
        canvas.drawLine(Offset(_heroX + 30, y), Offset(x - s, y), _stroke);
      }
    }
  }

  void _drawPilot(Canvas canvas, ThrustWorld w) {
    final r = ThrustWorld.heroRadius * _scale;
    final cx = _heroX, cy = _sy(w.hero.y);
    if (w.ghost && (w.time * 14).floor().isEven) return;
    final thrusting = w.holding;
    // Jetpack and flame.
    final pack = Rect.fromLTWH(cx - r * 1.15, cy - r * 0.7, r * 0.6, r * 1.2);
    if (thrusting) {
      final f = 0.75 + 0.25 * math.sin(w.time * 60);
      _path
        ..reset()
        ..moveTo(pack.left + 1, pack.bottom)
        ..lineTo(pack.center.dx, pack.bottom + r * 1.5 * f)
        ..lineTo(pack.right - 1, pack.bottom)
        ..close();
      _paint.color = const Color(0xFFFF8A3D);
      canvas.drawPath(_path, _paint);
      _paint.color = const Color(0xFFFFE9A8);
      canvas.drawCircle(Offset(pack.center.dx, pack.bottom + r * 0.35), r * 0.18, _paint);
    }
    _paint.color = const Color(0xFF5A6488);
    canvas.drawRRect(RRect.fromRectAndRadius(pack, Radius.circular(r * 0.2)), _paint);
    // Legs: a running cycle on the floor, trailing in the air.
    _stroke
      ..strokeWidth = math.max(2, r * 0.28)
      ..color = const Color(0xFF39406A);
    final hip = Offset(cx - r * 0.05, cy + r * 0.45);
    if (w.hero.grounded) {
      final ph = w.distance * 2.4;
      for (final s in const [0.0, math.pi]) {
        final k = math.sin(ph + s);
        canvas.drawLine(hip, Offset(cx + k * r * 0.55, cy + r * 1.0), _stroke);
      }
    } else {
      canvas.drawLine(hip, Offset(cx - r * 0.35, cy + r * 1.0), _stroke);
      canvas.drawLine(hip, Offset(cx - r * 0.05, cy + r * 1.05), _stroke);
    }
    // Body and helmet.
    _paint.color = _accent;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(cx - r * 0.55, cy - r * 0.35, cx + r * 0.45, cy + r * 0.6),
        Radius.circular(r * 0.3),
      ),
      _paint,
    );
    _paint.color = const Color(0xFFE8ECF8);
    canvas.drawCircle(Offset(cx, cy - r * 0.6), r * 0.5, _paint);
    _paint.color = _visor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(cx + r * 0.02, cy - r * 0.82, cx + r * 0.48, cy - r * 0.45),
        Radius.circular(r * 0.15),
      ),
      _paint,
    );
    _drawAuras(canvas, w, cx, cy, r);
  }

  void _drawStrider(Canvas canvas, ThrustWorld w) {
    final r = ThrustWorld.striderRadius * _scale;
    final cx = _heroX, cy = _sy(w.hero.y);
    final blink = w.striderLeft < 1.5 && (w.time * 10).floor().isEven;
    // Legs with knees: walking on the floor, tucked in the air.
    _stroke
      ..strokeWidth = math.max(3, r * 0.2)
      ..color = const Color(0xFF8A93B8);
    final hipY = cy + r * 0.25;
    final footY = cy + r;
    final ph = w.distance * 1.6;
    for (final s in const [0.0, math.pi]) {
      final k = w.hero.grounded ? math.sin(ph + s) : -0.3;
      final lift = w.hero.grounded ? math.max(0.0, math.cos(ph + s)) * r * 0.25 : r * 0.2;
      final foot = Offset(cx + k * r * 0.6, footY - lift);
      final knee = Offset(cx + k * r * 0.3 + r * 0.3, (hipY + foot.dy) / 2);
      canvas.drawLine(Offset(cx, hipY), knee, _stroke);
      canvas.drawLine(knee, foot, _stroke);
      canvas.drawLine(foot - Offset(r * 0.18, 0), foot + Offset(r * 0.22, 0), _stroke);
    }
    // Hull with a cockpit window and the pilot inside.
    final hull = Rect.fromLTRB(cx - r * 0.8, cy - r * 0.75, cx + r * 0.8, cy + r * 0.3);
    _paint.color = blink ? const Color(0xFF8C7A2A) : const Color(0xFFCFA92E);
    canvas.drawRRect(RRect.fromRectAndRadius(hull, Radius.circular(r * 0.25)), _paint);
    _paint.color = const Color(0xFF1B2140);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(cx - r * 0.1, cy - r * 0.6, cx + r * 0.62, cy - r * 0.1),
        Radius.circular(r * 0.15),
      ),
      _paint,
    );
    _paint.color = const Color(0xFFE8ECF8);
    canvas.drawCircle(Offset(cx + r * 0.22, cy - r * 0.32), r * 0.2, _paint);
    _paint.color = _visor;
    canvas.drawRect(Rect.fromLTRB(cx + r * 0.25, cy - r * 0.42, cx + r * 0.42, cy - r * 0.28), _paint);
    _stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF3A2F0A);
    canvas.drawLine(Offset(cx - r * 0.65, cy - r * 0.2), Offset(cx - r * 0.25, cy - r * 0.2), _stroke);
    _drawAuras(canvas, w, cx, cy, r);
  }

  void _drawAuras(Canvas canvas, ThrustWorld w, double cx, double cy, double r) {
    if (w.shield) {
      _stroke
        ..strokeWidth = 2
        ..color = _visor.withValues(alpha: 0.55 + 0.3 * math.sin(w.time * 6));
      canvas.drawCircle(Offset(cx, cy), r * 1.7, _stroke);
    }
    if (w.magnetActive) {
      _stroke
        ..strokeWidth = 1.5
        ..color = _pickupColor(PickupKind.magnet).withValues(alpha: 0.4);
      canvas.drawCircle(Offset(cx, cy), r * (1.8 + ((w.time * 2) % 1) * 2.5), _stroke);
    }
  }

  void _label(Canvas canvas, String text, double x, double y, double scale, Color color) {
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(scale.clamp(0.4, 2.5));
    CanvasText.draw(
      canvas,
      text,
      Offset.zero,
      size: 20,
      align: Alignment.center,
      color: color,
      weight: FontWeight.w900,
    );
    canvas.restore();
  }

  void _drawHud(Canvas canvas, ThrustWorld w) {
    final top = safePadding.top + 14;
    CanvasText.draw(
      canvas,
      '${w.metres} m',
      Offset(size.x / 2, top),
      size: 20,
      align: Alignment.topCenter,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(size.x - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: _coin,
      weight: FontWeight.w900,
    );
    final rowY = hudTop;
    _paint.color = _coin;
    canvas.drawCircle(Offset(24, rowY + 10), 7, _paint);
    CanvasText.draw(canvas, '${w.coins}', Offset(36, rowY), size: 17, weight: FontWeight.w800);
    CanvasText.draw(
      canvas,
      'BEST ${math.max(best, w.isOver ? w.score : 0)}',
      Offset(size.x - 16, rowY + 2),
      size: 13,
      align: Alignment.topRight,
      color: Colors.white70,
    );
    CanvasText.draw(
      canvas,
      '${(w.speed * 3.6).round()} km/h',
      Offset(size.x / 2, rowY + 2),
      size: 13,
      align: Alignment.topCenter,
      color: _gate,
    );
    // Power-up timers, inside the corridor's top-left corner.
    var y = _top + 10;
    void timer(PickupKind k, double t, double max, String label) {
      if (t <= 0) return;
      drawBar(canvas, Rect.fromLTWH(16, y, 80, 6), t / max, _pickupColor(k));
      CanvasText.draw(
        canvas,
        label,
        Offset(102, y - 4),
        size: 11,
        color: _pickupColor(k),
        weight: FontWeight.w800,
      );
      y += 14;
    }

    timer(PickupKind.magnet, w.magnetLeft, ThrustWorld.magnetDuration, 'MAGNET');
    timer(PickupKind.strider, w.striderLeft, ThrustWorld.striderDuration, 'WALKER');
    if (w.shield) {
      CanvasText.draw(canvas, 'SHIELD', Offset(16, y - 4), size: 11, color: _visor, weight: FontWeight.w900);
    }
    if (w.time < 4 && !w.isOver) {
      CanvasText.draw(
        canvas,
        'Hold anywhere to fly · release to drop',
        Offset(size.x / 2, _top + (_bottom - _top) * 0.3),
        size: 15,
        align: Alignment.center,
        color: Colors.white70,
        maxWidth: size.x - 32,
      );
    }
    if (w.inStrider && w.striderLeft > ThrustWorld.striderDuration - 2) {
      CanvasText.draw(
        canvas,
        'WALKER! Tap to jump',
        Offset(size.x / 2, _top + (_bottom - _top) * 0.3),
        size: 16,
        align: Alignment.center,
        color: _accent,
        weight: FontWeight.w900,
      );
    }
    if (w.isOver) {
      CanvasText.draw(
        canvas,
        'ZAPPED!',
        Offset(size.x / 2, size.y * 0.42),
        size: 40,
        align: Alignment.center,
        color: const Color(0xFFFF6B8A),
        weight: FontWeight.w900,
      );
    }
  }
}
