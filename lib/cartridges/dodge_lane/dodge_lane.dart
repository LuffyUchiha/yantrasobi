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
import 'dodge_world.dart';

class DodgeLaneCartridge extends FlameCartridge<DodgeLaneGame> {
  const DodgeLaneCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'dodge-lane',
    title: 'Dodge Lane',
    tagline: 'Three lanes. One hit. How far can you go?',
    description:
        'An endless neon highway with three lanes. Slide between lanes, hop over low '
        'barriers, duck under high bars and read the sliding blockers before they move. '
        'The road keeps speeding up; grab coins, shields, magnets and slow-mo on the way.',
    genre: 'Endless dodger',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFF3EA5),
    icon: Icons.alt_route_rounded,
    tags: ['endless', 'runner', 'one-thumb', 'score-attack', 'pseudo-3d', 'neon'],
    controls: [
      'Swipe left / right (or tap the left / right half) to switch lanes',
      'Swipe up to jump over low barriers',
      'Swipe down to duck under high bars',
    ],
    mechanics: [
      'lane switching',
      'jump & duck',
      'speed ramp',
      'coins',
      'shield / magnet / slow-mo',
      'near misses',
    ],
    goal: 'Survive as long as you can. One hit ends the run unless shielded. Score = metres + 10 per coin.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  DodgeLaneGame createGame(FlameCartridgeSession<DodgeLaneGame> session) => DodgeLaneGame(session);
}

class DodgeLaneGame extends AsobiFlameGame {
  DodgeLaneGame(super.session, {this.seed})
    : run = DodgeWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff),
      best = session.context.save.bestScore;

  final int? seed;

  /// The rules object (FlameGame already owns `world`).
  final DodgeWorld run;
  final int best;
  final Sparks sparks = Sparks(capacity: 260);

  static const double swipeThreshold = 24;

  // Look and feel.
  static const Color _accent = Color(0xFFFF3EA5);
  static const Color _cyan = Color(0xFF2EF2FF);
  static const Color _blockColor = Color(0xFFFF3E6C);
  static const Color _moverColor = Color(0xFFFF9F1C);
  static const Color _lowColor = Color(0xFFFFE14D);
  static const Color _highColor = Color(0xFF8C6BFF);
  static const Color _coinColor = Color(0xFFFFD166);
  static const double _laneWidth = 2.4;
  static const double _camBack = 10;
  static const double _viewFar = 85;

  final Paint _paint = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _sky = Paint();
  final Path _path = Path();

  // Projection, refreshed on resize.
  double _horizon = 0;
  double _focal = 1;
  double _camH = 9;
  double _cx = 0;

  // Last projection result.
  double _px = 0, _py = 0, _ps = 0;

  // Gesture tracking.
  Vector2? _down;
  bool _consumed = false;

  double _shake = 0;
  double _flash = 0;
  double _endTimer = 0;
  double _visualX = 1;
  bool _reported = false;

  @override
  int get entityCount => run.entityCount + sparks.count;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _cx = size.x / 2;
    _horizon = math.max(hudTop + 40, size.y * 0.3);
    final craftY = size.y - safePadding.bottom - math.max(90, size.y * 0.16);
    // Road spans ~86% of the width at the craft; camera height puts the craft at craftY.
    _focal = 0.86 * size.x * _camBack / (_laneWidth * DodgeWorld.laneCount);
    _camH = math.max(1.0, (craftY - _horizon) * _camBack / _focal);
    _sky.shader = Gradient.linear(
      Offset.zero,
      Offset(0, _horizon + 20),
      const [Color(0xFF070718), Color(0xFF2A0C46), Color(0xFF6B1060)],
      const [0, 0.7, 1],
    );
  }

  /// Projects lane coordinate [lane], track-relative distance [dz] (metres
  /// ahead of the craft) and height [h]. Returns false when behind the camera.
  bool _project(double lane, double dz, double h) {
    final depth = dz + _camBack;
    if (depth < 0.5) return false;
    _ps = _focal / depth;
    _px = _cx + (lane - 1) * _laneWidth * _ps;
    _py = _horizon + (_camH - h) * _ps;
    return true;
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    _down = position.clone();
    _consumed = false;
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final d = _down;
    if (d == null || _consumed) return;
    final dx = position.x - d.x;
    final dy = position.y - d.y;
    if (math.max(dx.abs(), dy.abs()) < swipeThreshold) return;
    _consumed = true;
    if (dx.abs() >= dy.abs()) {
      dx < 0 ? run.laneLeft() : run.laneRight();
    } else {
      dy < 0 ? run.jump() : run.duck();
    }
  }

  @override
  void onPointerUp(Vector2 position) {
    final d = _down;
    _down = null;
    if (d == null || _consumed) return;
    final dx = position.x - d.x;
    final dy = position.y - d.y;
    if (math.max(dx.abs(), dy.abs()) >= swipeThreshold) {
      // A fast flick may only report its movement on release.
      if (dx.abs() >= dy.abs()) {
        dx < 0 ? run.laneLeft() : run.laneRight();
      } else {
        dy < 0 ? run.jump() : run.duck();
      }
      return;
    }
    position.x < size.x / 2 ? run.laneLeft() : run.laneRight();
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    final w = run;
    w.update(dt);
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      switch (e.kind) {
        case DodgeEventKind.lane:
          audio.play(Sfx.tap);
        case DodgeEventKind.jump:
        case DodgeEventKind.duck:
          audio.play(Sfx.whoosh);
        case DodgeEventKind.coin:
          audio.play(Sfx.coin);
          if (!reduced) _burst(e.x, e.z - w.distance, 0.8, 6, _coinColor, 140);
        case DodgeEventKind.pickup:
          audio.play(Sfx.powerup);
          audio.haptic(HapticKind.medium);
          _burst(e.x, e.z - w.distance, 0.8, reduced ? 6 : 20, _pickupColor(e.pickup!), 220);
        case DodgeEventKind.shieldBreak:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.heavy);
          _burst(e.x, e.z - w.distance, 1, reduced ? 8 : 28, _cyan, 260);
          _flash = 0.25;
          if (!reduced) _shake = 0.2;
        case DodgeEventKind.crash:
          audio.play(Sfx.hit);
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
          _burst(e.x, 0, 0.8, reduced ? 10 : 50, _accent, 320);
          _flash = 0.5;
          if (!reduced) _shake = 0.45;
        case DodgeEventKind.nearMiss:
          audio.play(Sfx.pop);
          if (!reduced) _burst(e.x, 0, 0.6, 5, Colors.white, 160);
        case DodgeEventKind.telegraph:
          break;
      }
    }
    sparks.update(dt);
    _visualX += (w.x - _visualX) * (1 - math.exp(-dt * 30));
    if (_shake > 0) _shake -= dt;
    if (_flash > 0) _flash -= dt;
    if (w.isOver) {
      _endTimer += dt;
      if (_endTimer >= 0.9 && !_reported) _report(w);
    }
  }

  void _burst(double lane, double dz, double h, int n, Color color, double speed) {
    if (n <= 0 || size.x <= 0 || !_project(lane, dz, h)) return;
    sparks.burst(_px, _py, n, color, speed: speed);
  }

  void _report(DodgeWorld w) {
    _reported = true;
    final metres = w.distance.floor();
    finish(
      RunResult(
        score: w.score,
        headline: w.score > best && best > 0 ? 'New best! Crashed at $metres m' : 'Crashed at $metres m',
        details: {
          'Distance': '$metres m',
          'Coins': '${w.coins}',
          'Near misses': '${w.nearMisses}',
          'Top speed': '${(w.topSpeed * 3.6).round()} km/h',
          'Time': '${w.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  static Color _pickupColor(PickupKind k) => switch (k) {
    PickupKind.shield => _cyan,
    PickupKind.magnet => const Color(0xFFFF5CF0),
    PickupKind.slowmo => const Color(0xFF7CFF6B),
  };

  static String _pickupLabel(PickupKind k) => switch (k) {
    PickupKind.shield => 'S',
    PickupKind.magnet => 'M',
    PickupKind.slowmo => 'T',
  };

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    final w = run;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, _horizon + 1), _sky);
    _paint.color = const Color(0xFF07070F);
    canvas.drawRect(Rect.fromLTWH(0, _horizon, size.x, size.y - _horizon), _paint);
    _drawSun(canvas, w);
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 12;
      canvas.translate(math.sin(w.time * 90) * m, math.cos(w.time * 77) * m);
    }
    _drawRoad(canvas, w);
    _drawObjects(canvas, w);
    _drawCraft(canvas, w);
    sparks.render(canvas);
    canvas.restore();
    if (!ctx.settings.reducedEffects && w.speed > 22 && !w.isOver) _drawSpeedLines(canvas, w);
    if (_flash > 0) {
      _paint.color = Colors.white.withValues(alpha: (_flash * 0.8).clamp(0.0, 0.5));
      canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
    }
    _drawHud(canvas, w);
  }

  void _drawSun(Canvas canvas, DodgeWorld w) {
    final r = math.min(size.x * 0.22, 90.0);
    final c = Offset(_cx, _horizon - r * 0.35);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.x, _horizon));
    _paint.shader = Gradient.linear(c - Offset(0, r), c + Offset(0, r), const [
      Color(0xFFFFE14D),
      Color(0xFFFF3EA5),
    ]);
    canvas.drawCircle(c, r, _paint);
    _paint.shader = null;
    _paint.color = const Color(0xFF2A0C46);
    for (var i = 0; i < 5; i++) {
      final y = c.dy + r * (0.1 + i * 0.18);
      canvas.drawRect(Rect.fromLTWH(c.dx - r, y, r * 2, 2.0 + i * 1.6), _paint);
    }
    canvas.restore();
  }

  void _drawRoad(Canvas canvas, DodgeWorld w) {
    const halfRoad = DodgeWorld.laneCount / 2;
    // Road surface.
    _project(1 - halfRoad, -_camBack + 0.6, 0);
    final nlx = _px, nly = _py;
    _project(1 + halfRoad, -_camBack + 0.6, 0);
    final nrx = _px;
    _project(1 - halfRoad, _viewFar, 0);
    final flx = _px, fly = _py;
    _project(1 + halfRoad, _viewFar, 0);
    final frx = _px;
    _path
      ..reset()
      ..moveTo(nlx, nly)
      ..lineTo(nrx, nly)
      ..lineTo(frx, fly)
      ..lineTo(flx, fly)
      ..close();
    _paint.color = const Color(0xFF120A26);
    canvas.drawPath(_path, _paint);

    // Scrolling cross lines.
    _stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF3A1E66);
    const spacing = 6.0;
    final offset = w.distance % spacing;
    for (var dz = -offset - spacing; dz < _viewFar; dz += spacing) {
      if (dz < -_camBack + 0.6) continue;
      _project(1 - halfRoad, dz, 0);
      final lx = _px, y = _py;
      _project(1 + halfRoad, dz, 0);
      canvas.drawLine(Offset(lx, y), Offset(_px, y), _stroke);
    }

    // Lane dividers (dashed) and glowing edges.
    _stroke.color = _cyan.withValues(alpha: 0.55);
    for (var k = 1; k < DodgeWorld.laneCount; k++) {
      final lane = k - 0.5;
      for (var dz = -offset - spacing; dz < _viewFar; dz += spacing) {
        final a = math.max(dz, -_camBack + 0.6);
        final b = dz + spacing * 0.5;
        if (b <= a) continue;
        _project(lane, a, 0);
        final ax = _px, ay = _py, s = _ps;
        _project(lane, b, 0);
        _stroke.strokeWidth = math.max(1, s * 0.08);
        canvas.drawLine(Offset(ax, ay), Offset(_px, _py), _stroke);
      }
    }
    for (final edge in [1 - halfRoad, 1 + halfRoad]) {
      _project(edge, -_camBack + 0.6, 0);
      final ax = _px, ay = _py;
      _project(edge, _viewFar, 0);
      _stroke
        ..strokeWidth = 6
        ..color = _accent.withValues(alpha: 0.25);
      canvas.drawLine(Offset(ax, ay), Offset(_px, _py), _stroke);
      _stroke
        ..strokeWidth = 2.5
        ..color = _accent;
      canvas.drawLine(Offset(ax, ay), Offset(_px, _py), _stroke);
    }
  }

  void _drawObjects(Canvas canvas, DodgeWorld w) {
    // Back to front: merge obstacles, coins and pickups by depth.
    final obs = w.obstacles;
    final coins = w.coinItems;
    final picks = w.pickups;
    var oi = obs.length - 1, ci = coins.length - 1, pi = picks.length - 1;
    // Obstacles are appended in z order per row; coins/pickups likewise. A
    // three-way merge from the far end keeps occlusion right without sorting.
    while (oi >= 0 || ci >= 0 || pi >= 0) {
      final oz = oi >= 0 ? obs[oi].z : double.negativeInfinity;
      final cz = ci >= 0 ? coins[ci].z : double.negativeInfinity;
      final pz = pi >= 0 ? picks[pi].z : double.negativeInfinity;
      if (oz >= cz && oz >= pz) {
        _drawObstacle(canvas, w, obs[oi--]);
      } else if (cz >= pz) {
        _drawCoin(canvas, w, coins[ci--]);
      } else {
        _drawPickup(canvas, w, picks[pi--]);
      }
    }
  }

  void _drawObstacle(Canvas canvas, DodgeWorld w, Obstacle o) {
    if (o.hit) return;
    final dz = o.z - w.distance;
    if (dz > _viewFar || dz < -_camBack + 1) return;
    final fade = dz > _viewFar - 15 ? ((_viewFar - dz) / 15).clamp(0.0, 1.0) : 1.0;
    const hw = 0.42;
    final double h0, h1;
    final Color color;
    switch (o.kind) {
      case Cell.block:
        h0 = 0;
        h1 = 2.2;
        color = o.mover ? _moverColor : _blockColor;
      case Cell.low:
        h0 = 0;
        h1 = 0.65;
        color = _lowColor;
      case Cell.high:
        h0 = 1.25;
        h1 = 1.9;
        color = _highColor;
      case Cell.empty:
        return;
    }
    // Telegraph: an arrow on the road toward the mover's destination.
    if (o.mover && o.telegraphed && o.x != o.lane) {
      final blink = (w.time * 8).floor().isEven ? 1.0 : 0.45;
      _project(o.x, dz - 1.5, 0.02);
      final ax = _px, ay = _py, s = _ps;
      _project(o.lane.toDouble(), dz - 1.5, 0.02);
      _stroke
        ..strokeWidth = math.max(2, s * 0.18)
        ..color = _moverColor.withValues(alpha: fade * blink);
      canvas.drawLine(Offset(ax, ay), Offset(_px, _py), _stroke);
      final dir = (_px - ax).sign;
      canvas.drawLine(Offset(_px, _py), Offset(_px - dir * s * 0.35, _py - s * 0.25), _stroke);
      canvas.drawLine(Offset(_px, _py), Offset(_px - dir * s * 0.35, _py + s * 0.25), _stroke);
    }
    final d0 = dz, d1 = dz + DodgeWorld.obstacleDepth;
    // Top face.
    if (!_project(o.x - hw, d1, h1)) return;
    final tlx = _px, tly = _py;
    _project(o.x + hw, d1, h1);
    final trx = _px;
    _project(o.x - hw, d0, h1);
    final flx = _px, fty = _py;
    _project(o.x + hw, d0, h1);
    final frx = _px;
    _path
      ..reset()
      ..moveTo(tlx, tly)
      ..lineTo(trx, tly)
      ..lineTo(frx, fty)
      ..lineTo(flx, fty)
      ..close();
    _paint.color = Color.lerp(color, Colors.white, 0.35)!.withValues(alpha: fade);
    canvas.drawPath(_path, _paint);
    // Front face.
    _project(o.x - hw, d0, h0);
    final fby = _py;
    final front = Rect.fromLTRB(flx, fty, frx, fby);
    _paint.color = Color.lerp(color, const Color(0xFF000000), 0.35)!.withValues(alpha: fade);
    canvas.drawRect(front, _paint);
    _stroke
      ..strokeWidth = math.max(1.5, _ps * 0.06)
      ..color = color.withValues(alpha: fade);
    canvas.drawRect(front, _stroke);
    if (o.kind == Cell.high) {
      // Posts holding the bar up.
      _project(o.x - hw, d0, 0);
      final postBottom = _py;
      _stroke.strokeWidth = math.max(1, _ps * 0.05);
      canvas.drawLine(Offset(flx, fby), Offset(flx, postBottom), _stroke);
      canvas.drawLine(Offset(frx, fby), Offset(frx, postBottom), _stroke);
    } else if (o.kind == Cell.low) {
      // Hazard stripes.
      _stroke.strokeWidth = math.max(1, _ps * 0.05);
      _stroke.color = const Color(0xFF1A1300).withValues(alpha: fade);
      final wdt = frx - flx;
      for (var i = 1; i < 5; i++) {
        final sx = flx + wdt * i / 5;
        canvas.drawLine(Offset(sx - wdt * 0.08, fby), Offset(sx + wdt * 0.08, fty), _stroke);
      }
    } else {
      // Glowing X on blocks.
      _stroke
        ..strokeWidth = math.max(1, _ps * 0.05)
        ..color = Colors.white.withValues(alpha: 0.5 * fade);
      final inset = front.deflate(front.width * 0.22);
      canvas.drawLine(inset.topLeft, inset.bottomRight, _stroke);
      canvas.drawLine(inset.topRight, inset.bottomLeft, _stroke);
    }
  }

  void _drawCoin(Canvas canvas, DodgeWorld w, Coin c) {
    final dz = c.z - w.distance;
    if (dz > _viewFar || !_project(c.x, dz, 0.8)) return;
    final r = _ps * 0.32;
    final spin = math.cos(w.time * 6 + c.z).abs() * 0.8 + 0.2;
    _paint.color = _coinColor;
    canvas.drawOval(Rect.fromCenter(center: Offset(_px, _py), width: r * 2 * spin, height: r * 2), _paint);
    _stroke
      ..strokeWidth = math.max(1, r * 0.2)
      ..color = const Color(0xFFFFF3C4);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(_px, _py), width: r * 1.2 * spin, height: r * 1.2),
      _stroke,
    );
  }

  void _drawPickup(Canvas canvas, DodgeWorld w, Pickup p) {
    final dz = p.z - w.distance;
    final bob = math.sin(w.time * 4) * 0.15;
    if (dz > _viewFar || !_project(p.x, dz, 1.0 + bob)) return;
    final r = _ps * 0.5;
    final color = _pickupColor(p.kind);
    _path
      ..reset()
      ..moveTo(_px, _py - r)
      ..lineTo(_px + r, _py)
      ..lineTo(_px, _py + r)
      ..lineTo(_px - r, _py)
      ..close();
    _paint.color = color.withValues(alpha: 0.3);
    canvas.drawCircle(Offset(_px, _py), r * 1.3, _paint);
    _paint.color = color;
    canvas.drawPath(_path, _paint);
    _label(canvas, _pickupLabel(p.kind), _px, _py, r / 22);
  }

  /// Text drawn at a fixed font size and scaled, so the text cache does not churn.
  void _label(Canvas canvas, String text, double x, double y, double scale) {
    if (scale < 0.12) return;
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(math.min(scale, 3));
    CanvasText.draw(
      canvas,
      text,
      Offset.zero,
      size: 20,
      align: Alignment.center,
      color: const Color(0xFF14102A),
      weight: FontWeight.w900,
    );
    canvas.restore();
  }

  void _drawCraft(Canvas canvas, DodgeWorld w) {
    // Hop height: smooth rise and fall, continuous across re-boosts.
    final rise = math.min(1.0, w.airElapsed / 0.15);
    final fall = math.min(1.0, w.airTime / 0.18);
    final h = w.airborne ? 1.7 * math.min(rise, fall) : 0.0;
    final crouch = w.ducking ? 0.45 : 1.0;
    // Shadow.
    _project(_visualX, 0, 0);
    final s = _ps;
    _paint.color = const Color(0x88000000);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(_px, _py), width: s * 0.9 * (1 - h * 0.15), height: s * 0.3),
      _paint,
    );
    if (w.isOver) return;
    _project(_visualX, 0, h + 0.25);
    final cx = _px, cy = _py;
    final hw = s * 0.42, len = s * 0.95 * crouch, tall = s * 0.55 * crouch;
    final tilt = (w.targetLane - w.x).clamp(-1.0, 1.0) * s * 0.12;
    // Glow.
    _paint.color = _accent.withValues(alpha: 0.25);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: hw * 2.8, height: tall * 1.6), _paint);
    // Hull: an arrowhead pointing up the road.
    _path
      ..reset()
      ..moveTo(cx + tilt, cy - len * 0.55)
      ..lineTo(cx + hw, cy + tall * 0.35)
      ..lineTo(cx + hw * 0.4, cy + tall * 0.5)
      ..lineTo(cx - hw * 0.4, cy + tall * 0.5)
      ..lineTo(cx - hw, cy + tall * 0.35)
      ..close();
    _paint.color = const Color(0xFF1C1236);
    canvas.drawPath(_path, _paint);
    _stroke
      ..strokeWidth = math.max(2, s * 0.06)
      ..color = _accent;
    canvas.drawPath(_path, _stroke);
    // Cockpit + thrusters.
    _paint.color = _cyan;
    canvas.drawCircle(Offset(cx + tilt * 0.5, cy - len * 0.05), s * 0.1, _paint);
    final flame = 0.6 + 0.4 * math.sin(w.time * 40);
    _paint.color = const Color(0xFFFFB13D);
    canvas.drawCircle(Offset(cx - hw * 0.3, cy + tall * 0.55), s * 0.06 * (1 + flame), _paint);
    canvas.drawCircle(Offset(cx + hw * 0.3, cy + tall * 0.55), s * 0.06 * (1 + flame), _paint);
    if (w.shield) {
      _stroke
        ..strokeWidth = 2
        ..color = _cyan.withValues(alpha: 0.6 + 0.3 * math.sin(w.time * 6));
      canvas.drawCircle(Offset(cx, cy), hw * 1.6, _stroke);
    }
    if (w.magnetTimer > 0) {
      _stroke
        ..strokeWidth = 1.5
        ..color = _pickupColor(PickupKind.magnet).withValues(alpha: 0.4);
      final pulse = (w.time * 2) % 1;
      canvas.drawCircle(Offset(cx, cy), hw * (1.6 + pulse * 2), _stroke);
    }
  }

  void _drawSpeedLines(Canvas canvas, DodgeWorld w) {
    final k = ((w.speed - 22) / 10).clamp(0.0, 1.0);
    _stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.18 * k);
    for (var i = 0; i < 10; i++) {
      final seedA = (i * 97 + (w.distance * 0.7).floor() * 31) % 360;
      final a = seedA * math.pi / 180;
      final r0 = size.x * 0.45, r1 = size.x * 0.75;
      final o = Offset(_cx, _horizon);
      final dir = Offset(math.cos(a), math.sin(a).abs() + 0.2);
      canvas.drawLine(o + dir * r0, o + dir * r1, _stroke);
    }
  }

  void _drawHud(Canvas canvas, DodgeWorld w) {
    final top = safePadding.top + 14;
    CanvasText.draw(
      canvas,
      '${w.distance.floor()} m',
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
      color: _coinColor,
      weight: FontWeight.w900,
    );
    final rowY = hudTop;
    _paint.color = _coinColor;
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
      color: _cyan,
    );
    // Power-up timers.
    var y = rowY + 26;
    void timer(PickupKind k, double t, double max, String label) {
      if (t <= 0) return;
      drawBar(canvas, Rect.fromLTWH(16, y, 90, 6), t / max, _pickupColor(k));
      CanvasText.draw(canvas, label, Offset(112, y - 4), size: 11, color: _pickupColor(k));
      y += 14;
    }

    timer(PickupKind.magnet, w.magnetTimer, DodgeWorld.magnetDuration, 'MAGNET');
    timer(PickupKind.slowmo, w.slowTimer, DodgeWorld.slowDuration, 'SLOW-MO');
    if (w.shield) {
      CanvasText.draw(canvas, 'SHIELD', Offset(16, y - 4), size: 11, color: _cyan, weight: FontWeight.w900);
    }
    if (w.time < 4 && !w.isOver) {
      CanvasText.draw(
        canvas,
        'Swipe sideways to switch lanes · up to jump · down to duck',
        Offset(size.x / 2, size.y - safePadding.bottom - 28),
        size: 14,
        align: Alignment.center,
        color: Colors.white70,
        maxWidth: size.x - 32,
      );
    }
    if (w.isOver) {
      CanvasText.draw(
        canvas,
        'CRASH!',
        Offset(size.x / 2, size.y * 0.42),
        size: 40,
        align: Alignment.center,
        color: const Color(0xFFFF6B8A),
        weight: FontWeight.w900,
      );
    }
  }
}
