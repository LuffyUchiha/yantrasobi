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
import 'gridlock_world.dart';

class GridlockCartridge extends FlameCartridge<GridlockGame> {
  const GridlockCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'gridlock',
    title: 'Gridlock',
    tagline: 'Read the lot. Clear the lanes. Three bumps and you are towed.',
    description:
        'A traffic-escape puzzle. Every car and truck on the lot points one way; tap it and '
        'it drives straight ahead. A clear road means it leaves the lot, anything in the way '
        'means a bump and a strike. Work out the order, empty the lot, and beat the clock. '
        'Two hints per run point out a car that can leave right now.',
    genre: 'Traffic-escape puzzle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFE63946),
    icon: Icons.directions_car_filled_rounded,
    tags: ['puzzle', 'traffic', 'logic', 'casual', 'levels'],
    controls: [
      'Tap a vehicle to drive it forward in the direction of its arrow',
      'Tap HINT to highlight a vehicle whose road is clear (2 per run)',
    ],
    mechanics: ['traffic escape', 'tap to move', 'strikes', 'hints', 'time bonus', 'levels'],
    goal: 'Drive every vehicle off the lot. Three bumps into another vehicle lose the level.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  GridlockGame createGame(FlameCartridgeSession<GridlockGame> session) => GridlockGame(session);
}

/// Body paints for the vehicles.
const List<Color> kGridlockPaints = [
  Color(0xFFE63946), // red
  Color(0xFF2A9D8F), // teal
  Color(0xFFF4A261), // orange
  Color(0xFF457B9D), // steel blue
  Color(0xFFFFC93C), // yellow
  Color(0xFF8E7DBE), // lavender
  Color(0xFF52B788), // green
  Color(0xFFEF6F9C), // pink
  Color(0xFFDDE1E6), // silver
];

class GridlockGame extends AsobiFlameGame {
  GridlockGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      lot = GridlockWorld(
        seed: seed ?? DateTime.now().microsecondsSinceEpoch,
        level: math.max(1, session.context.save.intData('level', 1)),
      );

  final int? seed;
  final int level;
  final GridlockWorld lot;
  final Sparks sparks = Sparks();

  bool _reported = false;
  double _endDelay = 1.0;
  double _clock = 0;

  /// Vehicles currently driving off the lot (renderer-only).
  final List<_Leaving> _leaving = [];

  /// Bump animations by vehicle id: the rules already put the car back.
  final Map<int, _Bump> _bumps = {};

  /// Blockers that were hit, with remaining shake time.
  final Map<int, double> _shake = {};
  final Map<int, double> _hintGlow = {};
  double _heartFlash = 0;

  @override
  int get entityCount => lot.entityCount + sparks.count + _leaving.length;

  @override
  Color backgroundColor() => const Color(0xFF14161F);

  // ---------------------------------------------------------------- layout
  double get _bottomInset => safePadding.bottom + 14;
  Rect get _hintRect {
    final w = math.min(180.0, size.x - 48);
    const h = 46.0;
    return Rect.fromLTWH((size.x - w) / 2, size.y - _bottomInset - h, w, h);
  }

  double get _boardTop => hudTop + 52;
  double get _boardBottom => _hintRect.top - 22;
  double get _unit => math.max(4, math.min((size.x - 40) / lot.cols, (_boardBottom - _boardTop) / lot.rows));
  Offset get _origin {
    final u = _unit;
    return Offset(
      (size.x - lot.cols * u) / 2,
      _boardTop + math.max(0, (_boardBottom - _boardTop - lot.rows * u) / 2),
    );
  }

  Rect get _boardRect {
    final o = _origin;
    return Rect.fromLTWH(o.dx, o.dy, lot.cols * _unit, lot.rows * _unit);
  }

  /// Screen rect of [v] parked in its own cells (widget-local).
  Rect vehicleRect(Vehicle v) {
    final u = _unit;
    final o = _origin;
    final w = v.horizontal ? v.length : 1;
    final h = v.horizontal ? 1 : v.length;
    return Rect.fromLTWH(o.dx + v.col * u, o.dy + v.row * u, w * u, h * u);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (lot.isOver || size.x <= 0) return;
    final p = Offset(position.x, position.y);
    if (_hintRect.inflate(6).contains(p)) {
      _useHint();
      return;
    }
    final v = vehicleAtPoint(p);
    if (v != null) _handleTap(v);
  }

  /// The parked vehicle under screen point [p] (widget-local), or null.
  Vehicle? vehicleAtPoint(Offset p) {
    final o = _origin;
    final u = _unit;
    return lot.vehicleAt(((p.dx - o.dx) / u).floor(), ((p.dy - o.dy) / u).floor());
  }

  /// Screen rect of the HINT button.
  Rect get hintButtonRect => _hintRect;

  void _useHint() {
    final v = lot.hint();
    if (v == null) {
      audio.play(Sfx.thud);
      return;
    }
    _hintGlow[v.id] = 5;
    audio.play(Sfx.powerup);
    audio.haptic(HapticKind.selection);
  }

  void _handleTap(Vehicle v) {
    final from = vehicleRect(v);
    final r = lot.tap(v.id);
    switch (r.outcome) {
      case GridlockOutcome.invalid:
        return;
      case GridlockOutcome.blocked:
        _bumps[v.id] = _Bump(v.heading, r.travel);
        _shake[r.blockerId] = 0.3;
        _heartFlash = 0.6;
        audio.play(Sfx.thud);
        audio.haptic(HapticKind.medium);
        if (lot.lost) {
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
        }
      case GridlockOutcome.exited:
        _bumps.remove(v.id);
        _hintGlow.remove(v.id);
        final distance = (r.travel + v.length + 1.5) * _unit;
        _leaving.add(_Leaving(v, from, distance));
        audio.play(Sfx.whoosh);
        audio.haptic(HapticKind.selection);
        if (lot.won) {
          audio.play(Sfx.win);
          final c = _boardRect.center;
          sparks.burst(
            c.dx,
            c.dy,
            ctx.settings.reducedEffects ? 12 : 60,
            const Color(0xFFFFD166),
            speed: 320,
          );
        }
    }
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    lot.update(dt);
    sparks.update(dt);
    for (final l in _leaving) {
      final before = l.t;
      l.t += dt / l.duration;
      // Puff of exhaust as the car crosses the lot edge.
      if (before < 0.45 && l.t >= 0.45 && !ctx.settings.reducedEffects) {
        final c = _edgePoint(l);
        sparks.burst(c.dx, c.dy, 8, const Color(0xFFBFC6D4), speed: 90, life: 0.4);
      }
    }
    _leaving.removeWhere((l) => l.t >= 1);
    for (final id in _bumps.keys.toList()) {
      final b = _bumps[id]!;
      b.t += dt / b.duration;
      if (b.t >= 1) _bumps.remove(id);
    }
    _tick(_shake, dt);
    _tick(_hintGlow, dt);
    _heartFlash = math.max(0, _heartFlash - dt);
    if (lot.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  static void _tick(Map<int, double> m, double dt) {
    for (final id in m.keys.toList()) {
      final v = m[id]! - dt;
      if (v <= 0) {
        m.remove(id);
      } else {
        m[id] = v;
      }
    }
  }

  Offset _edgePoint(_Leaving l) {
    final b = _boardRect;
    final c = l.from.center;
    return switch (l.v.heading) {
      Heading.up => Offset(c.dx, b.top),
      Heading.down => Offset(c.dx, b.bottom),
      Heading.left => Offset(b.left, c.dy),
      Heading.right => Offset(b.right, c.dy),
    };
  }

  void _report() {
    _reported = true;
    final won = lot.won;
    if (won) {
      session.context.save.data['level'] = level + 1;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: lot.score,
        won: won,
        headline: won ? 'Lot $level cleared! Level ${level + 1} unlocked.' : 'Gridlocked on level $level.',
        details: {
          'Level': '$level',
          'Vehicles out': '${lot.exitedCount}/${lot.vehicles.length}',
          'Bumps': '${lot.strikes}',
          if (won && lot.perfectBonus > 0) 'No-bump bonus': '${lot.perfectBonus}',
          if (won) 'Time bonus': '${lot.timeBonus}',
          'Time': '${lot.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    _drawLot(canvas);
    final u = _unit;
    for (final v in lot.parked) {
      var r = vehicleRect(v);
      final b = _bumps[v.id];
      if (b != null) r = r.shift(Offset(v.heading.dx.toDouble(), v.heading.dy.toDouble()) * (b.offset * u));
      final s = _shake[v.id];
      if (s != null) r = r.shift(Offset(math.sin(_clock * 70) * 3 * s / 0.3, 0));
      final glow = _hintGlow[v.id];
      if (glow != null) {
        final pulse = 0.5 + 0.5 * math.sin(_clock * 9);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r.deflate(u * 0.02), Radius.circular(u * 0.22)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 + 2 * pulse
            ..color = const Color(0xFF7CFFB2).withValues(alpha: math.min(1, glow) * (0.55 + 0.45 * pulse)),
        );
      }
      drawGridlockVehicle(canvas, v, r, u, hit: s != null);
    }
    // Leaving vehicles drive past the lot edge; clip to the play area.
    canvas.save();
    final b = _boardRect;
    canvas.clipRect(Rect.fromLTRB(0, b.top - 14, size.x, b.bottom + 14));
    for (final l in _leaving) {
      final e = l.t * l.t; // accelerate away
      final d = Offset(l.v.heading.dx.toDouble(), l.v.heading.dy.toDouble()) * (l.distance * e);
      final r = l.from.shift(d);
      final fade = l.t < 0.7 ? 1.0 : (1 - (l.t - 0.7) / 0.3);
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, fade.clamp(0.0, 1.0)));
      drawGridlockVehicle(canvas, l.v, r, u);
      canvas.restore();
    }
    canvas.restore();
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _drawLot(Canvas canvas) {
    final b = _boardRect;
    final u = _unit;
    // Kerb, then asphalt.
    canvas.drawRRect(
      RRect.fromRectAndRadius(b.inflate(10), const Radius.circular(16)),
      Paint()..color = const Color(0xFF2B2F3D),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(b.inflate(4), const Radius.circular(10)),
      Paint()..color = const Color(0xFF3A3F50),
    );
    // Parking-bay markings: short ticks at each cell corner.
    final tick = Paint()
      ..color = const Color(0x30FFFFFF)
      ..strokeWidth = 1.5;
    final len = u * 0.14;
    for (var r = 0; r <= lot.rows; r++) {
      for (var c = 0; c <= lot.cols; c++) {
        final p = Offset(b.left + c * u, b.top + r * u);
        canvas.drawLine(p - Offset(len, 0), p + Offset(len, 0), tick);
        canvas.drawLine(p - Offset(0, len), p + Offset(0, len), tick);
      }
    }
    // Exit gaps in the kerb: dashed yellow edge line.
    final edge = Paint()
      ..color = const Color(0x66FFD166)
      ..strokeWidth = 2;
    final rr = b.inflate(7);
    for (var x = rr.left; x < rr.right; x += 14) {
      canvas.drawLine(Offset(x, rr.top), Offset(math.min(x + 7, rr.right), rr.top), edge);
      canvas.drawLine(Offset(x, rr.bottom), Offset(math.min(x + 7, rr.right), rr.bottom), edge);
    }
    for (var y = rr.top; y < rr.bottom; y += 14) {
      canvas.drawLine(Offset(rr.left, y), Offset(rr.left, math.min(y + 7, rr.bottom)), edge);
      canvas.drawLine(Offset(rr.right, y), Offset(rr.right, math.min(y + 7, rr.bottom)), edge);
    }
  }

  void _drawHud(Canvas canvas) {
    CanvasText.draw(canvas, 'LEVEL $level', Offset(16, hudTop), size: 18, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      '${lot.score}',
      Offset(size.x - 16, hudTop),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '${lot.carsLeft} left',
      Offset(size.x / 2, hudTop + 4),
      size: 14,
      align: Alignment.topCenter,
      color: Colors.white70,
      weight: FontWeight.w800,
    );
    // Strikes as hearts: full = bumps still allowed.
    for (var i = 0; i < GridlockWorld.maxStrikes; i++) {
      final full = i < lot.strikesLeft;
      final lostNow = i == lot.strikesLeft && _heartFlash > 0;
      final c = Offset(26 + i * 26.0, hudTop + 38);
      final color = full
          ? const Color(0xFFFF4D6D)
          : lostNow
          ? Color.lerp(const Color(0xFF4A4F60), Colors.white, _heartFlash / 0.6)!
          : const Color(0xFF4A4F60);
      _drawHeart(canvas, c, 9, color);
    }
    CanvasText.draw(
      canvas,
      '${lot.time.toStringAsFixed(0)}s',
      Offset(size.x - 16, hudTop + 30),
      size: 14,
      align: Alignment.topRight,
      color: Colors.white54,
    );
    // Hint button.
    final hr = _hintRect;
    final enabled = lot.canHint;
    canvas.drawRRect(
      RRect.fromRectAndRadius(hr, const Radius.circular(23)),
      Paint()..color = enabled ? const Color(0xFFE63946) : const Color(0xFF353A4A),
    );
    CanvasText.draw(
      canvas,
      'HINT  ${lot.hintsLeft}',
      hr.center,
      size: 16,
      align: Alignment.center,
      weight: FontWeight.w900,
      color: enabled ? Colors.white : Colors.white38,
    );
    if (!lot.isOver && lot.moves == 0 && _clock < 7) {
      CanvasText.draw(
        canvas,
        'Tap a vehicle to drive it the way its arrow points',
        Offset(size.x / 2, hr.top - 8),
        size: 13,
        align: Alignment.bottomCenter,
        color: Colors.white70,
      );
    }
    if (lot.isOver) {
      CanvasText.draw(
        canvas,
        lot.won ? 'LOT CLEARED!' : 'GRIDLOCKED',
        Offset(size.x / 2, size.y * 0.42),
        size: 34,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: lot.won ? const Color(0xFFFFD166) : const Color(0xFFFF4D6D),
      );
    }
  }

  void _drawHeart(Canvas canvas, Offset c, double r, Color color) {
    final p = Path()
      ..moveTo(c.dx, c.dy + r * 0.95)
      ..cubicTo(c.dx - r * 1.5, c.dy - r * 0.1, c.dx - r * 0.7, c.dy - r * 1.2, c.dx, c.dy - r * 0.45)
      ..cubicTo(c.dx + r * 0.7, c.dy - r * 1.2, c.dx + r * 1.5, c.dy - r * 0.1, c.dx, c.dy + r * 0.95)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }
}

class _Leaving {
  _Leaving(this.v, this.from, this.distance) : duration = 0.35 + distance / 2400;
  final Vehicle v;
  final Rect from;
  final double distance;
  final double duration;
  double t = 0;
}

class _Bump {
  _Bump(this.heading, this.travel) : duration = 0.28 + travel * 0.06;
  final Heading heading;
  final int travel;
  final double duration;
  double t = 0;

  /// Cells of forward displacement: roll out to the obstacle, nudge it, roll back.
  double get offset {
    final reach = travel + 0.18;
    if (t < 0.45) {
      final k = t / 0.45;
      return reach * k * k;
    }
    final k = (t - 0.45) / 0.55;
    return reach * (1 - k) * (1 - k);
  }
}

final Paint _vp = Paint();

/// Draws a top-down vehicle filling [cellRect] (its cells), nose towards its heading.
void drawGridlockVehicle(Canvas canvas, Vehicle v, Rect cellRect, double u, {bool hit = false}) {
  final paint = kGridlockPaints[v.kind % kGridlockPaints.length];
  final len = v.length * u - u * 0.16;
  final wid = u * 0.78;
  canvas.save();
  canvas.translate(cellRect.center.dx, cellRect.center.dy);
  canvas.rotate(switch (v.heading) {
    Heading.right => 0,
    Heading.down => math.pi / 2,
    Heading.left => math.pi,
    Heading.up => -math.pi / 2,
  });
  // Local frame: nose at +x.
  final body = Rect.fromCenter(center: Offset.zero, width: len, height: wid);
  final rad = Radius.circular(u * 0.2);
  _vp
    ..style = PaintingStyle.fill
    ..color = const Color(0x66000000);
  canvas.drawRRect(RRect.fromRectAndRadius(body.shift(Offset(u * 0.04, u * 0.07)), rad), _vp);
  // Wheels peeking out.
  _vp.color = const Color(0xFF15161C);
  final wheelW = u * 0.22, wheelH = u * 0.1;
  for (final x in [body.left + u * 0.32, body.right - u * 0.32]) {
    for (final y in [body.top, body.bottom]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, y), width: wheelW, height: wheelH * 2),
          Radius.circular(wheelH * 0.6),
        ),
        _vp,
      );
    }
  }
  if (v.length >= 3) {
    // Truck: cargo box behind a cab at the front.
    final cabLen = u * 0.95;
    final cab = Rect.fromLTRB(body.right - cabLen, body.top + u * 0.02, body.right, body.bottom - u * 0.02);
    final box = Rect.fromLTRB(body.left, body.top, cab.left - u * 0.06, body.bottom);
    _vp.color = const Color(0xFFE9ECF2);
    canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(u * 0.1)), _vp);
    _vp.color = const Color(0x22000000);
    for (var i = 1; i < 4; i++) {
      final x = box.left + box.width * i / 4;
      canvas.drawRect(Rect.fromLTWH(x - 1, box.top + u * 0.08, 2, box.height - u * 0.16), _vp);
    }
    _vp.color = paint;
    canvas.drawRRect(RRect.fromRectAndRadius(cab, rad), _vp);
    _vp.color = const Color(0xFF1E2A3A);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(cab.right - u * 0.4, cab.top + u * 0.1, cab.right - u * 0.16, cab.bottom - u * 0.1),
        Radius.circular(u * 0.06),
      ),
      _vp,
    );
    _vp.color = paint;
    canvas.drawRRect(RRect.fromRectAndRadius(box.deflate(u * 0.16), Radius.circular(u * 0.06)), _vp);
  } else {
    _vp.color = paint;
    canvas.drawRRect(RRect.fromRectAndRadius(body, rad), _vp);
    // Roof highlight.
    _vp.color = const Color(0x33FFFFFF);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          body.left + u * 0.5,
          body.top + u * 0.14,
          body.right - u * 0.55,
          body.bottom - u * 0.14,
        ),
        Radius.circular(u * 0.1),
      ),
      _vp,
    );
    // Windscreen (front) and rear window.
    _vp.color = const Color(0xFF1E2A3A);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(body.right - u * 0.55, body.top + u * 0.1, body.right - u * 0.3, body.bottom - u * 0.1),
        Radius.circular(u * 0.06),
      ),
      _vp,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(body.left + u * 0.22, body.top + u * 0.14, body.left + u * 0.4, body.bottom - u * 0.14),
        Radius.circular(u * 0.05),
      ),
      _vp,
    );
  }
  // Headlights at the nose, tail lights at the back.
  _vp.color = const Color(0xFFFFF3B0);
  canvas.drawCircle(Offset(body.right - u * 0.06, body.top + u * 0.14), u * 0.06, _vp);
  canvas.drawCircle(Offset(body.right - u * 0.06, body.bottom - u * 0.14), u * 0.06, _vp);
  _vp.color = const Color(0xFFB0002A);
  canvas.drawRect(Rect.fromLTWH(body.left, body.top + u * 0.08, u * 0.05, u * 0.14), _vp);
  canvas.drawRect(Rect.fromLTWH(body.left, body.bottom - u * 0.22, u * 0.05, u * 0.14), _vp);
  // Direction arrow on the roof / box.
  final ax = v.length >= 3 ? -u * 0.45 : -u * 0.05;
  final a = u * 0.2;
  final arrow = Path()
    ..moveTo(ax + a, 0)
    ..lineTo(ax - a * 0.6, -a * 0.9)
    ..lineTo(ax - a * 0.25, 0)
    ..lineTo(ax - a * 0.6, a * 0.9)
    ..close();
  _vp.color = const Color(0xF2FFFFFF);
  canvas.drawPath(arrow, _vp);
  _vp
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = const Color(0x66000000);
  canvas.drawPath(arrow, _vp);
  if (hit) {
    _vp
      ..strokeWidth = 3
      ..color = const Color(0xFFFF4D6D);
    canvas.drawRRect(RRect.fromRectAndRadius(body.inflate(1), rad), _vp);
  }
  _vp.style = PaintingStyle.fill;
  canvas.restore();
}
