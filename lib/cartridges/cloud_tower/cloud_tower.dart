import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, HSLColor, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'tower_world.dart';

class CloudTowerCartridge extends FlameCartridge<CloudTowerGame> {
  const CloudTowerCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'cloud-tower',
    title: 'Cloud Tower',
    tagline: 'Drop. Slice. Climb past the clouds.',
    description:
        'Pastel slabs glide over the top of your tower, first along one side, then the other. '
        'Tap to drop: whatever hangs over the edge is sliced off and tumbles away, so every '
        'sloppy drop leaves you less room. Land it dead centre for a perfect snap, chain four '
        'in a row to grow the slab back, and ride the tower from blue sky through sunset and '
        'starry night into space.',
    genre: 'Stacking / timing',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFB59CFF),
    icon: Icons.view_in_ar_rounded,
    tags: ['endless', 'stacking', 'timing', 'one-tap', 'score-attack', 'pseudo-3d', 'pastel'],
    controls: ['Tap anywhere to drop the sliding slab'],
    mechanics: [
      'tap timing',
      'overhang slicing',
      'perfect snap',
      'streak regrow',
      'alternating axes',
      'speed ramp',
    ],
    goal:
        'Stack as high as you can. A drop that misses the tower ends the run. '
        'Score = floors + perfect-streak bonuses.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  CloudTowerGame createGame(FlameCartridgeSession<CloudTowerGame> session) => CloudTowerGame(session);
}

class CloudTowerGame extends AsobiFlameGame {
  CloudTowerGame(super.session, {this.seed})
    : tower = TowerWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff),
      best = session.context.save.bestScore;

  final int? seed;

  /// The rules object (FlameGame already owns `world`).
  final TowerWorld tower;
  final int best;
  final Sparks sparks = Sparks(capacity: 200);

  static const Color _accent = Color(0xFFB59CFF);
  static const double _cos30 = 0.8660254;
  static const double _sin30 = 0.5;
  static const double _sh = TowerWorld.slabHeight;

  final Paint _paint = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  final Paint _sky = Paint();
  final Path _path = Path();

  // Per-floor colour cache: top, left face, right face, rim.
  final List<Color> _colors = [];

  // Camera.
  double _scale = 10;
  double _baseScale = 10;
  double _camY = 0;
  double _camX = 0;
  double _anchorY = 400;
  double _cx = 200;
  double _skyKey = -1;

  /// Altitude (floors) driving the sky; holds its peak while the camera pulls back.
  double _alt = 0;

  // Last projection.
  double _px = 0, _py = 0;

  double _banner = 0;
  int _bannerFloor = 0;
  double _perfectFx = 0;
  int _perfectLevel = 0;
  double _popTimer = 0;
  String _popText = '';
  double _endTimer = 0;
  bool _reported = false;

  @override
  int get entityCount => tower.entityCount + sparks.count;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _cx = size.x / 2;
    _anchorY = math.max(hudTop + 150, size.y * 0.46);
    // A full-size slab spans ~48% of the width.
    _baseScale = size.x * 0.48 / (2 * TowerWorld.baseSize * _cos30);
    if (!tower.isOver) _scale = _baseScale;
    _skyKey = -1;
  }

  void _proj(double x, double y, double z) {
    _px = _cx + ((x - z) * _cos30 - _camX) * _scale;
    _py = _anchorY - (y - _camY) * _scale + (x + z) * _sin30 * _scale;
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (tower.isOver) return;
    tower.drop();
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    final w = tower;
    w.update(dt);
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      switch (e.kind) {
        case TowerEventKind.place:
          if (e.streak == 0) {
            audio.play(Sfx.thud);
            audio.haptic();
          }
        case TowerEventKind.perfect:
          audio.play(Sfx.pop);
          audio.haptic(HapticKind.medium);
          _perfectFx = 0.6;
          _perfectLevel = e.level;
          _popText = e.streak > 1 ? 'PERFECT ×${e.streak}' : 'PERFECT';
          _popTimer = 0.9;
          if (!reduced && size.x > 0) {
            final t = w.top.level == e.level ? w.top : null;
            if (t != null) {
              _proj(t.x, t.topY, t.z);
              sparks.burst(_px, _py, 14, Colors.white, speed: 200);
            }
          }
        case TowerEventKind.regrow:
          audio.play(Sfx.powerup);
          _popText = 'GROW!';
          _popTimer = 1.1;
        case TowerEventKind.milestone:
          audio.play(Sfx.coin);
          audio.haptic(HapticKind.heavy);
          _banner = 2.2;
          _bannerFloor = e.level;
        case TowerEventKind.miss:
          audio.play(Sfx.hit);
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
      }
    }
    w.events.clear();
    sparks.update(dt);

    // Camera follows the top of the tower; after the run it pulls back to show it all.
    final k = 1 - math.exp(-dt * 4);
    final t = w.top;
    var targetY = t.topY + _sh * 0.5;
    var targetX = (t.x - t.z) * _cos30;
    var targetScale = _baseScale;
    if (w.isOver) {
      final h = t.topY + 6;
      final fit = size.y * 0.62 / h;
      targetScale = math.min(_baseScale, fit);
      targetY = math.min(targetY, h * 0.5);
      targetX = 0;
      _endTimer += dt;
      if (_endTimer >= 1.6 && !_reported) _report(w);
    }
    _camY += (targetY - _camY) * k;
    _camX += (targetX * 0.6 - _camX) * k;
    _scale += (targetScale - _scale) * k;
    if (!w.isOver) _alt = math.max(0.0, _camY / _sh);
    if (_banner > 0) _banner -= dt;
    if (_perfectFx > 0) _perfectFx -= dt;
    if (_popTimer > 0) _popTimer -= dt;
  }

  void _report(TowerWorld w) {
    _reported = true;
    final newBest = w.score > best && best > 0;
    finish(
      RunResult(
        score: w.score,
        headline: newBest
            ? 'New best! ${w.floors} floors high'
            : 'The tower topped out at ${w.floors} floors',
        details: {
          'Floors': '${w.floors}',
          'Perfect drops': '${w.perfects}',
          'Best streak': '${w.bestStreak}',
          'Perfect bonus': '${w.bonus}',
          'Regrows': '${w.regrows}',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- colour
  Color _color(int level, int face) {
    while (_colors.length <= level * 4 + 3) {
      final l = _colors.length ~/ 4;
      final hue = (tower.hueBase + l * 6.5) % 360;
      final sat = 0.5 + 0.12 * math.sin(l * 0.21);
      _colors
        ..add(HSLColor.fromAHSL(1, hue, sat, 0.80).toColor())
        ..add(HSLColor.fromAHSL(1, (hue + 8) % 360, sat, 0.66).toColor())
        ..add(HSLColor.fromAHSL(1, (hue + 16) % 360, sat * 0.9, 0.55).toColor())
        ..add(HSLColor.fromAHSL(1, hue, sat, 0.90).toColor());
    }
    return _colors[level * 4 + face];
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    final w = tower;
    _drawSky(canvas);
    _drawGround(canvas);
    // Debris behind the tower (smaller x + z) first.
    final t = w.top;
    final towerDepth = t.x + t.z;
    for (final b in w.debris) {
      if (b.x + b.z < towerDepth) _drawDebris(canvas, b);
    }
    _drawTower(canvas, w);
    final m = w.moving;
    if (m != null) {
      _drawSlab(canvas, m.x, m.z, m.w, m.d, m.topY, m.topY - _sh, m.level, 1);
    }
    for (final b in w.debris) {
      if (b.x + b.z >= towerDepth) _drawDebris(canvas, b);
    }
    if (_perfectFx > 0 && _perfectLevel < w.slabs.length) _drawPerfectRing(canvas, w.slabs[_perfectLevel]);
    sparks.render(canvas);
    _drawHud(canvas, w);
  }

  static double _smooth(double a, double b, double v) {
    final t = ((v - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static const List<double> _skyStops = [0, 30, 60, 95, 140];
  static const List<Color> _skyTop = [
    Color(0xFF7FB8F5),
    Color(0xFF6A6FC4),
    Color(0xFF3B2C6E),
    Color(0xFF0B1033),
    Color(0xFF020208),
  ];
  static const List<Color> _skyBottom = [
    Color(0xFFDDF0FF),
    Color(0xFFFFC7A1),
    Color(0xFFF07E86),
    Color(0xFF26306A),
    Color(0xFF0B0B22),
  ];

  Color _skyAt(List<Color> stops, double alt) {
    for (var i = 0; i < _skyStops.length - 1; i++) {
      if (alt <= _skyStops[i + 1]) {
        final f = ((alt - _skyStops[i]) / (_skyStops[i + 1] - _skyStops[i])).clamp(0.0, 1.0);
        return Color.lerp(stops[i], stops[i + 1], f)!;
      }
    }
    return stops.last;
  }

  void _drawSky(Canvas canvas) {
    final alt = _alt;
    final key = (alt * 2).floorToDouble();
    if (key != _skyKey) {
      _skyKey = key;
      _sky.shader = Gradient.linear(Offset.zero, Offset(0, size.y), [
        _skyAt(_skyTop, alt),
        _skyAt(_skyBottom, alt),
      ]);
    }
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _sky);
    final time = tower.time;

    // Stars fade in at night and stay in space.
    final stars = _smooth(55, 85, alt);
    if (stars > 0) {
      final drift = _camY * _scale * 0.08;
      for (var i = 0; i < 70; i++) {
        final hx = _hash(i * 3 + 1), hy = _hash(i * 3 + 2), hs = _hash(i * 3 + 3);
        final x = hx * size.x;
        final y = (hy * size.y + drift) % size.y;
        final tw = ctx.settings.reducedEffects ? 1.0 : 0.6 + 0.4 * math.sin(time * (1 + hs * 3) + i);
        _paint.color = Colors.white.withValues(alpha: stars * tw * (0.4 + 0.6 * hs));
        canvas.drawCircle(Offset(x, y), 0.6 + hs * 1.4, _paint);
      }
    }

    // A pale moon at night, a ringed planet in space.
    final moon = _smooth(60, 90, alt) * (1 - _smooth(120, 150, alt));
    if (moon > 0) {
      final c = Offset(size.x * 0.78, hudTop + 90);
      _paint.color = const Color(0xFFFFF4D6).withValues(alpha: 0.18 * moon);
      canvas.drawCircle(c, 34, _paint);
      _paint.color = const Color(0xFFFFF4D6).withValues(alpha: 0.9 * moon);
      canvas.drawCircle(c, 20, _paint);
    }
    final planet = _smooth(125, 160, alt);
    if (planet > 0) {
      final c = Offset(size.x * 0.24, hudTop + 120);
      _paint.color = const Color(0xFFB59CFF).withValues(alpha: planet);
      canvas.drawCircle(c, 28, _paint);
      _stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFFFD6F2).withValues(alpha: planet * 0.8);
      canvas.drawOval(Rect.fromCenter(center: c, width: 92, height: 20), _stroke);
    }

    // Soft clouds in daylight, scrolling past as the tower climbs.
    final clouds = 1 - _smooth(35, 70, alt);
    if (clouds > 0) {
      final scroll = _camY * _scale * 0.35;
      for (var i = 0; i < 6; i++) {
        final hx = _hash(i * 7 + 11), hy = _hash(i * 7 + 12), hs = _hash(i * 7 + 13);
        final span = size.y * 1.6;
        final y = (hy * span + scroll) % span - size.y * 0.3;
        final x = (hx * (size.x + 200) + time * (6 + hs * 10)) % (size.x + 200) - 100;
        final r = 18 + hs * 18;
        _paint.color = Colors.white.withValues(alpha: 0.55 * clouds);
        canvas.drawCircle(Offset(x, y), r, _paint);
        canvas.drawCircle(Offset(x + r * 0.9, y + r * 0.2), r * 0.75, _paint);
        canvas.drawCircle(Offset(x - r * 0.9, y + r * 0.25), r * 0.65, _paint);
        canvas.drawRect(Rect.fromLTRB(x - r * 1.5, y + r * 0.1, x + r * 1.5, y + r * 0.85), _paint);
      }
    }
  }

  static double _hash(int i) {
    final v = math.sin(i * 12.9898 + 78.233) * 43758.5453;
    return v - v.floorToDouble();
  }

  void _drawGround(Canvas canvas) {
    // Floating island the tower stands on: a wide grassy slab with a deep earth body.
    const g = 15.0;
    _proj(-g, -_sh * 6, -g);
    if (_py > size.y) return;
    _faces(
      canvas,
      -g,
      g,
      -g,
      g,
      -_sh * 6,
      -_sh * 14,
      const Color(0xFF9ED9A0),
      const Color(0xFFB59078),
      const Color(0xFF8E6E5C),
      const Color(0xFFC7EFC4),
    );
  }

  void _drawTower(Canvas canvas, TowerWorld w) {
    final slabs = w.slabs;
    // Lowest floor still on screen.
    final below = (_anchorY - 40 - size.y) / _scale + _camY - TowerWorld.baseSize;
    var start = math.max(0, below.floor());
    if (start >= slabs.length) start = slabs.length - 1;
    for (var i = start; i < slabs.length; i++) {
      final s = slabs[i];
      final bottom = s.level == 0 ? -_sh * 6 : s.topY - _sh;
      _drawSlab(canvas, s.x, s.z, s.w, s.d, s.topY, bottom, s.level, 1);
    }
  }

  void _drawSlab(
    Canvas canvas,
    double x,
    double z,
    double w,
    double d,
    double top,
    double bottom,
    int level,
    double alpha,
  ) {
    Color c(int face) => alpha >= 1 ? _color(level, face) : _color(level, face).withValues(alpha: alpha);
    _faces(canvas, x - w / 2, x + w / 2, z - d / 2, z + d / 2, top, bottom, c(0), c(1), c(2), c(3));
  }

  /// Draws a box's top and two visible side faces (+z face on the left, +x face on the right).
  void _faces(
    Canvas canvas,
    double x0,
    double x1,
    double z0,
    double z1,
    double top,
    double bottom,
    Color topColor,
    Color leftColor,
    Color rightColor,
    Color rim,
  ) {
    // Corners.
    _proj(x0, top, z0);
    final ax = _px, ay = _py;
    _proj(x1, top, z0);
    final bx = _px, by = _py;
    _proj(x1, top, z1);
    final cx = _px, cy = _py;
    _proj(x0, top, z1);
    final dx = _px, dy = _py;
    final drop = (top - bottom) * _scale;

    // Left face (+z): d -> c -> down.
    _path
      ..reset()
      ..moveTo(dx, dy)
      ..lineTo(cx, cy)
      ..lineTo(cx, cy + drop)
      ..lineTo(dx, dy + drop)
      ..close();
    _paint.color = leftColor;
    canvas.drawPath(_path, _paint);
    // Right face (+x): c -> b -> down.
    _path
      ..reset()
      ..moveTo(cx, cy)
      ..lineTo(bx, by)
      ..lineTo(bx, by + drop)
      ..lineTo(cx, cy + drop)
      ..close();
    _paint.color = rightColor;
    canvas.drawPath(_path, _paint);
    // Soft shading band along the bottom of both side faces (a cheap vertical gradient).
    final band = math.min(drop * 0.35, 6.0);
    if (band > 1) {
      _paint.color = const Color(0x22000000);
      _path
        ..reset()
        ..moveTo(dx, dy + drop - band)
        ..lineTo(cx, cy + drop - band)
        ..lineTo(bx, by + drop - band)
        ..lineTo(bx, by + drop)
        ..lineTo(cx, cy + drop)
        ..lineTo(dx, dy + drop)
        ..close();
      canvas.drawPath(_path, _paint);
    }
    // Top face.
    _path
      ..reset()
      ..moveTo(ax, ay)
      ..lineTo(bx, by)
      ..lineTo(cx, cy)
      ..lineTo(dx, dy)
      ..close();
    _paint.color = topColor;
    canvas.drawPath(_path, _paint);
    // Rim light on the front edges.
    _stroke
      ..strokeWidth = 1.2
      ..color = rim;
    _path
      ..reset()
      ..moveTo(dx, dy)
      ..lineTo(cx, cy)
      ..lineTo(bx, by);
    canvas.drawPath(_path, _stroke);
  }

  void _drawDebris(Canvas canvas, Debris b) {
    final fade = (1 - b.age / TowerWorld.debrisLife).clamp(0.0, 1.0);
    if (fade <= 0) return;
    _proj(b.x, b.y - _sh / 2, b.z);
    if (_py > size.y + 200) return;
    final pcx = _px, pcy = _py;
    canvas.save();
    if (!ctx.settings.reducedEffects) {
      canvas.translate(pcx, pcy);
      canvas.rotate(b.rot);
      canvas.translate(-pcx, -pcy);
    }
    _drawSlab(canvas, b.x, b.z, b.w, b.d, b.y, b.y - _sh, b.level, fade);
    canvas.restore();
  }

  void _drawPerfectRing(Canvas canvas, Slab s) {
    final f = (_perfectFx / 0.6).clamp(0.0, 1.0);
    final grow = 1 + (1 - f) * 0.35;
    final hw = s.w / 2 * grow, hd = s.d / 2 * grow;
    _proj(s.x - hw, s.topY, s.z - hd);
    _path
      ..reset()
      ..moveTo(_px, _py);
    _proj(s.x + hw, s.topY, s.z - hd);
    _path.lineTo(_px, _py);
    _proj(s.x + hw, s.topY, s.z + hd);
    _path.lineTo(_px, _py);
    _proj(s.x - hw, s.topY, s.z + hd);
    _path
      ..lineTo(_px, _py)
      ..close();
    _stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: f * 0.9);
    canvas.drawPath(_path, _stroke);
  }

  void _drawHud(Canvas canvas, TowerWorld w) {
    final top = hudTop;
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(size.x / 2, top),
      size: 46,
      align: Alignment.topCenter,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      'FLOOR ${w.floors}',
      Offset(size.x / 2, top + 56),
      size: 14,
      align: Alignment.topCenter,
      color: Colors.white.withValues(alpha: 0.85),
    );
    CanvasText.draw(
      canvas,
      'BEST ${math.max(best, w.isOver ? w.score : 0)}',
      Offset(size.x - 16, top + 4),
      size: 13,
      align: Alignment.topRight,
      color: Colors.white70,
    );
    // Streak pips: progress toward the next regrow.
    if (w.streak > 0) {
      final filled = w.streak % TowerWorld.regrowEvery == 0 ? TowerWorld.regrowEvery : w.streak % 4;
      for (var i = 0; i < TowerWorld.regrowEvery; i++) {
        final x = size.x / 2 + (i - 1.5) * 18;
        final y = top + 84.0;
        _path
          ..reset()
          ..moveTo(x, y - 6)
          ..lineTo(x + 6, y)
          ..lineTo(x, y + 6)
          ..lineTo(x - 6, y)
          ..close();
        _paint.color = i < filled ? Colors.white : Colors.white24;
        canvas.drawPath(_path, _paint);
      }
    }
    if (_popTimer > 0 && _popText.isNotEmpty) {
      final a = _popTimer.clamp(0.0, 0.5) * 2;
      CanvasText.draw(
        canvas,
        _popText,
        Offset(size.x / 2, _anchorY - 70 - (1 - a) * 16),
        size: 24,
        align: Alignment.center,
        color: Colors.white.withValues(alpha: a),
        weight: FontWeight.w900,
      );
    }
    if (_banner > 0) {
      final a = (_banner.clamp(0.0, 0.4) / 0.4) * (1 - ((_banner - 1.9) / 0.3).clamp(0.0, 1.0));
      final y = hudTop + 135;
      _paint.color = _accent.withValues(alpha: 0.85 * a);
      canvas.drawRect(Rect.fromLTWH(0, y - 24, size.x, 48), _paint);
      CanvasText.draw(
        canvas,
        'FLOOR $_bannerFloor!',
        Offset(size.x / 2, y),
        size: 26,
        align: Alignment.center,
        color: Colors.white.withValues(alpha: a),
        weight: FontWeight.w900,
      );
    }
    if (w.floors < 2 && !w.isOver) {
      CanvasText.draw(
        canvas,
        'Tap to drop the slab · line it up perfectly to keep it whole',
        Offset(size.x / 2, size.y - safePadding.bottom - 36),
        size: 14,
        align: Alignment.center,
        color: Colors.white,
        maxWidth: size.x - 32,
      );
    }
    if (w.isOver) {
      CanvasText.draw(
        canvas,
        'TOPPLED!',
        Offset(size.x / 2, size.y - safePadding.bottom - 70),
        size: 36,
        align: Alignment.center,
        color: const Color(0xFFFFD6F2),
        weight: FontWeight.w900,
      );
    }
  }
}
