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
import 'gulp_world.dart';

class GulpHoleCartridge extends FlameCartridge<GulpHoleGame> {
  const GulpHoleCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'gulp-hole',
    title: 'Gulp Hole',
    tagline: 'Swallow the city, one pebble at a time.',
    description:
        'Steer a hungry hole through a sprawling city block. Anything smaller than you '
        'drops in: pebbles, cones, benches, cars, kiosks, trees and finally whole houses. '
        'Three rival holes are feeding too. Outgrow them, gulp them, and finish the '
        '90-second round as the biggest hole in town.',
    genre: 'Hyper-casual arena',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF9B5DE5),
    icon: Icons.blur_circular_rounded,
    tags: ['casual', 'arena', 'growth', 'io'],
    controls: ['Drag anywhere: virtual joystick to steer the hole'],
    mechanics: ['swallow to grow', 'size tiers', 'rival holes', 'round timer'],
    goal:
        'Be the biggest hole when the 90 s timer ends, or swallow 60% of the city. '
        'Holes 20% smaller than you can be gulped - so can you.',
    multiplayer: MultiplayerSpec(
      sync: SyncModel.parallel,
      maxPlayers: 8,
      summary: 'Same city for everyone; highest score wins',
    ),
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  GulpHoleGame createGame(FlameCartridgeSession<GulpHoleGame> session) =>
      GulpHoleGame(session, seed: session.context.matchSeed);
}

class GulpHoleGame extends AsobiFlameGame {
  GulpHoleGame(super.session, {this.seed});

  final int? seed;
  GulpWorld? _world;
  final Sparks sparks = Sparks();
  Vector2? _stickOrigin;
  Vector2? _stickKnob;

  // Camera (world-space centre and zoom).
  double _camX = 0;
  double _camY = 0;
  double _zoom = 1;
  bool _camReady = false;

  double _shake = 0;
  double _banner = 0;
  String _bannerText = '';
  double _endDelay = 0.9;
  bool _reported = false;

  // Reused paints to keep per-frame allocations low.
  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  static const Color kAccent = Color(0xFF9B5DE5);
  static const List<Color> _rivalColors = [Color(0xFFE36BAE), Color(0xFFFFB627), Color(0xFF2EC4B6)];

  GulpWorld get world0 => _world!;

  @override
  int get entityCount => (_world?.entityCount ?? 0) + sparks.count;

  @override
  int get liveScore => _world?.score ?? 0;

  static Color holeColor(Hole h) => h.isPlayer ? kAccent : _rivalColors[(h.id - 1) % _rivalColors.length];

  @override
  Color backgroundColor() => const Color(0xFF14151F);

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _world ??= GulpWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch);
  }

  static const double _stickRadius = 56;

  @override
  void onPointerDown(Vector2 position) {
    if (_world == null) return;
    _stickOrigin = position.clone();
    _stickKnob = position.clone();
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final o = _stickOrigin;
    if (o == null) return;
    final d = position - o;
    if (d.length > _stickRadius) d.scaleTo(_stickRadius);
    _stickKnob = o + d;
    _world?.input.setValues(d.x / _stickRadius, d.y / _stickRadius);
  }

  @override
  void onPointerUp(Vector2 position) {
    _stickOrigin = null;
    _stickKnob = null;
    _world?.input.setZero();
  }

  @override
  void update(double dt) {
    super.update(dt);
    final w = _world;
    if (w == null) return;
    w.update(dt);
    _handleEvents(w);
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (_banner > 0) _banner -= dt;
    _updateCamera(w, dt);
    if (w.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) {
        _reported = true;
        finish(_result(w));
      }
    }
  }

  void _handleEvents(GulpWorld w) {
    final reduced = ctx.settings.reducedEffects;
    var swallowSound = false;
    for (final e in w.events) {
      switch (e.kind) {
        case GulpEventKind.swallow:
          final tier = e.tier!;
          if (!reduced || e.byPlayer) {
            sparks.burst(
              e.x,
              e.y,
              reduced ? 3 : 4 + tier.index * 2,
              _tierColor(tier),
              speed: 90 + tier.radius * 2,
            );
          }
          if (e.byPlayer && !swallowSound) {
            swallowSound = true;
            audio.play(tier.index >= ObjTier.kiosk.index ? Sfx.thud : Sfx.pop);
            if (tier.index >= ObjTier.kiosk.index) audio.haptic(HapticKind.medium);
          }
        case GulpEventKind.levelUp:
          if (e.byPlayer) {
            audio.play(Sfx.powerup);
            audio.haptic(HapticKind.light);
            _bannerText = 'BIGGER! Lv ${w.player.level}';
            _banner = 1.1;
            sparks.burst(e.x, e.y, reduced ? 8 : 24, kAccent, speed: 260);
          }
        case GulpEventKind.eatHole:
          final victim = w.holes[e.holeId];
          sparks.burst(e.x, e.y, reduced ? 10 : 40, holeColor(victim), speed: 300);
          if (e.byPlayer) {
            audio.play(Sfx.merge);
            audio.haptic(HapticKind.heavy);
            _bannerText = 'GULPED ${victim.name.toUpperCase()}!';
            _banner = 1.4;
            if (!reduced) _shake = 0.3;
          } else if (!victim.isPlayer) {
            audio.play(Sfx.whoosh);
          }
        case GulpEventKind.playerEaten:
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
          if (!reduced) _shake = 0.5;
        case GulpEventKind.respawn:
          break;
        case GulpEventKind.timeUp:
        case GulpEventKind.cityCleared:
          audio.play(w.phase == GulpPhase.won ? Sfx.win : Sfx.lose);
          _bannerText = w.phase == GulpPhase.won ? 'BIGGEST HOLE!' : 'TIME UP';
          _banner = 2;
      }
    }
  }

  RunResult _result(GulpWorld w) {
    final won = w.phase == GulpPhase.won;
    final String headline;
    if (won) {
      headline = w.endedByCity ? 'You swallowed most of the city!' : 'Biggest hole in town!';
    } else if (w.eatenBy != null) {
      headline = 'Gulped by ${w.eatenBy!.name}';
    } else {
      headline = 'Finished #${w.playerRank} of ${w.holes.length}';
    }
    return RunResult(
      score: w.score,
      won: won,
      headline: headline,
      details: {
        'Size': 'Lv ${w.player.level}',
        'Swallowed': '${w.player.swallowed}',
        'Rivals gulped': '${w.player.holesEaten}',
        'City eaten': '${(w.cityShare * 100).round()}%',
        'Time': '${w.time.toStringAsFixed(0)}s',
      },
    );
  }

  void _updateCamera(GulpWorld w, double dt) {
    final p = w.player;
    final screenScale = (size.x / 420).clamp(0.8, 1.4);
    final targetZoom = screenScale * (46 / (p.radius + 24)).clamp(0.5, 1.0);
    final k = _camReady ? math.min(1.0, dt * 4) : 1.0;
    _zoom += (targetZoom - _zoom) * k;
    final vw = size.x / _zoom, vh = size.y / _zoom;
    final tx = vw >= w.width ? w.width / 2 : p.pos.x.clamp(vw / 2, w.width - vw / 2);
    final ty = vh >= w.height ? w.height / 2 : p.pos.y.clamp(vh / 2, w.height - vh / 2);
    final kc = _camReady ? math.min(1.0, dt * 8) : 1.0;
    _camX += (tx - _camX) * kc;
    _camY += (ty - _camY) * kc;
    _camReady = true;
  }

  static Color _tierColor(ObjTier t) => switch (t) {
    ObjTier.pebble => const Color(0xFFB8B8C8),
    ObjTier.cone => const Color(0xFFFF8C42),
    ObjTier.bench => const Color(0xFFC08552),
    ObjTier.car => const Color(0xFF5DADE2),
    ObjTier.kiosk => const Color(0xFFFFD166),
    ObjTier.tree => const Color(0xFF52B788),
    ObjTier.house => const Color(0xFFE07A5F),
  };

  static const List<Color> _carColors = [
    Color(0xFF5DADE2),
    Color(0xFFEF476F),
    Color(0xFFF4F1DE),
    Color(0xFF06D6A0),
  ];
  static const List<Color> _roofColors = [
    Color(0xFFE07A5F),
    Color(0xFF9C6644),
    Color(0xFF6D597A),
    Color(0xFF3D5A80),
  ];

  // --- Rendering -----------------------------------------------------------

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final w = _world;
    if (w == null || !_camReady) return;
    final reduced = ctx.settings.reducedEffects;
    final vw = size.x / _zoom, vh = size.y / _zoom;
    final view = Rect.fromLTWH(_camX - vw / 2, _camY - vh / 2, vw, vh);
    canvas.save();
    canvas.translate(size.x / 2, size.y / 2);
    if (_shake > 0) {
      final m = _shake * 12;
      canvas.translate(math.sin(w.time * 90) * m, math.cos(w.time * 77) * m);
    }
    canvas.scale(_zoom);
    canvas.translate(-_camX, -_camY);
    _drawGround(canvas, w, view);
    for (final h in w.holes) {
      if (h.alive) _drawHole(canvas, w, h, reduced);
    }
    _drawSinking(canvas, w, view);
    final cull = view.inflate(90);
    for (final o in w.objects) {
      if (!o.alive || !cull.contains(Offset(o.pos.x, o.pos.y))) continue;
      _drawObject(canvas, o, reduced);
    }
    sparks.render(canvas);
    canvas.restore();
    _drawLabels(canvas, w);
    _drawStick(canvas);
    _drawHud(canvas, w);
  }

  void _drawGround(Canvas canvas, GulpWorld w, Rect view) {
    // Asphalt everywhere, then pavement + grass blocks on top.
    _fill.color = const Color(0xFF262838);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.width, w.height), _fill);
    const half = GulpWorld.roadWidth / 2;
    final bw = w.blockW, bh = w.blockH;
    for (var bx = 0; bx < GulpWorld.blocksX; bx++) {
      for (var by = 0; by < GulpWorld.blocksY; by++) {
        final r = Rect.fromLTRB(bx * bw + half, by * bh + half, (bx + 1) * bw - half, (by + 1) * bh - half);
        if (!r.overlaps(view)) continue;
        _fill.color = const Color(0xFF3B3F54);
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(14)), _fill);
        _fill.color = const Color(0xFF2E5240);
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(12), const Radius.circular(8)), _fill);
      }
    }
    // Lane dashes on interior streets.
    _stroke
      ..color = const Color(0x88FFE08A)
      ..strokeWidth = 3;
    const dash = 22.0, gap = 26.0;
    for (var k = 1; k < GulpWorld.blocksX; k++) {
      final x = k * bw;
      if (x < view.left - 4 || x > view.right + 4) continue;
      var y = ((view.top / (dash + gap)).floor()) * (dash + gap);
      for (; y < view.bottom; y += dash + gap) {
        canvas.drawLine(Offset(x, y), Offset(x, y + dash), _stroke);
      }
    }
    for (var k = 1; k < GulpWorld.blocksY; k++) {
      final y = k * bh;
      if (y < view.top - 4 || y > view.bottom + 4) continue;
      var x = ((view.left / (dash + gap)).floor()) * (dash + gap);
      for (; x < view.right; x += dash + gap) {
        canvas.drawLine(Offset(x, y), Offset(x + dash, y), _stroke);
      }
    }
    // Arena border.
    _stroke
      ..color = const Color(0xFFFF5C8A)
      ..strokeWidth = 6;
    canvas.drawRect(Rect.fromLTWH(0, 0, w.width, w.height), _stroke);
  }

  void _drawHole(Canvas canvas, GulpWorld w, Hole h, bool reduced) {
    final c = Offset(h.pos.x, h.pos.y);
    final r = h.radius;
    final color = holeColor(h);
    if (h.isPlayer && h.shield > 0) {
      // Start-of-round grace: a soft cyan "safe" ring that flickers out at the end.
      final ending = h.shield < 3 && (w.time * 8).floor().isOdd;
      if (!ending) {
        final pulse = reduced ? 0.0 : math.sin(w.time * 4) * 2;
        _fill.color = const Color(0x1A7AE7FF);
        canvas.drawCircle(c, r + 10 + pulse, _fill);
        _stroke
          ..color = const Color(0x997AE7FF)
          ..strokeWidth = 2;
        canvas.drawCircle(c, r + 10 + pulse, _stroke);
      }
    } else if (h.shield > 0 && (w.time * 12).floor().isEven) {
      _stroke
        ..color = const Color(0xAAFFFFFF)
        ..strokeWidth = 3;
      canvas.drawCircle(c, r + 8, _stroke);
    }
    _fill.color = color.withValues(alpha: 0.55);
    canvas.drawCircle(c, r + 4, _fill);
    _fill.color = const Color(0xFF07070D);
    canvas.drawCircle(c, r, _fill);
    _fill.color = const Color(0xFF000000);
    canvas.drawCircle(c, r * 0.7, _fill);
    if (!reduced) {
      // A slow swirl inside the hole.
      _stroke
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = math.max(2, r * 0.08);
      final spin = w.time * (h.isPlayer ? 2.2 : 1.6);
      final rr = Rect.fromCircle(center: c, radius: r * 0.55);
      canvas.drawArc(rr, spin, 1.6, false, _stroke);
      canvas.drawArc(rr, spin + math.pi, 1.6, false, _stroke);
    }
    _stroke
      ..color = color
      ..strokeWidth = 3;
    canvas.drawCircle(c, r + 2, _stroke);
  }

  void _drawSinking(Canvas canvas, GulpWorld w, Rect view) {
    for (final o in w.objects) {
      if (o.alive || o.sink <= 0) continue;
      if (!view.inflate(90).contains(Offset(o.pos.x, o.pos.y))) continue;
      final t = (o.sink / 0.35).clamp(0.0, 1.0);
      canvas.save();
      canvas.translate(o.pos.x, o.pos.y);
      canvas.rotate((1 - t) * 1.5);
      canvas.scale(0.2 + 0.8 * t);
      canvas.translate(-o.pos.x, -o.pos.y);
      _drawObject(canvas, o, true);
      canvas.restore();
    }
  }

  void _drawObject(Canvas canvas, CityObject o, bool flat) {
    final x = o.pos.x, y = o.pos.y, r = o.radius;
    final c = Offset(x, y);
    if (!flat) {
      _fill.color = const Color(0x40000000);
      canvas.drawCircle(c + const Offset(4, 5), r * 0.9, _fill);
    }
    switch (o.tier) {
      case ObjTier.pebble:
        _fill.color = o.variant.isEven ? const Color(0xFFB8B8C8) : const Color(0xFF8E8EA0);
        canvas.drawCircle(c, r, _fill);
        _fill.color = const Color(0x55FFFFFF);
        canvas.drawCircle(c - Offset(r * 0.3, r * 0.3), r * 0.35, _fill);
      case ObjTier.cone:
        _fill.color = const Color(0xFFFF8C42);
        canvas.drawCircle(c, r, _fill);
        _fill.color = const Color(0xFFFFFFFF);
        canvas.drawCircle(c, r * 0.6, _fill);
        _fill.color = const Color(0xFFFF8C42);
        canvas.drawCircle(c, r * 0.35, _fill);
      case ObjTier.bench:
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(o.angle + (o.variant.isEven ? 0 : math.pi / 2));
        _fill.color = const Color(0xFF7F5539);
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: r * 1.9, height: r * 0.9), _fill);
        _stroke
          ..color = const Color(0xFFC08552)
          ..strokeWidth = 2;
        for (var i = -1; i <= 1; i++) {
          canvas.drawLine(Offset(-r * 0.9, i * r * 0.28), Offset(r * 0.9, i * r * 0.28), _stroke);
        }
        canvas.restore();
      case ObjTier.car:
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(o.angle);
        _fill.color = _carColors[o.variant % _carColors.length];
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: r * 1.9, height: r * 1.0),
            Radius.circular(r * 0.3),
          ),
          _fill,
        );
        _fill.color = const Color(0xCC1B263B);
        canvas.drawRect(
          Rect.fromCenter(center: Offset(r * 0.15, 0), width: r * 0.8, height: r * 0.75),
          _fill,
        );
        _fill.color = const Color(0xFFFFF3B0);
        canvas.drawCircle(Offset(r * 0.88, -r * 0.3), r * 0.1, _fill);
        canvas.drawCircle(Offset(r * 0.88, r * 0.3), r * 0.1, _fill);
        canvas.restore();
      case ObjTier.kiosk:
        final rect = Rect.fromCenter(center: c, width: r * 1.5, height: r * 1.5);
        _fill.color = const Color(0xFFF4F1DE);
        canvas.drawRect(rect, _fill);
        _fill.color = o.variant.isEven ? const Color(0xFFEF476F) : const Color(0xFF118AB2);
        final sw = rect.width / 6;
        for (var i = 0; i < 6; i += 2) {
          canvas.drawRect(Rect.fromLTWH(rect.left + i * sw, rect.top, sw, rect.height), _fill);
        }
        _fill.color = const Color(0xFFFFD166);
        canvas.drawCircle(c, r * 0.18, _fill);
      case ObjTier.tree:
        _fill.color = const Color(0xFF2D6A4F);
        canvas.drawCircle(c, r, _fill);
        _fill.color = o.variant.isEven ? const Color(0xFF52B788) : const Color(0xFF40916C);
        canvas.drawCircle(c + Offset(-r * 0.25, -r * 0.2), r * 0.62, _fill);
        canvas.drawCircle(c + Offset(r * 0.3, r * 0.15), r * 0.5, _fill);
        _fill.color = const Color(0x3395D5B2);
        canvas.drawCircle(c + Offset(-r * 0.35, -r * 0.35), r * 0.28, _fill);
      case ObjTier.house:
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(o.angle);
        final half = r * 0.72;
        final roof = Rect.fromLTRB(-half, -half, half, half);
        _fill.color = _roofColors[o.variant % _roofColors.length];
        canvas.drawRect(roof, _fill);
        // Darker half suggests a pitched roof lit from the top-left.
        _fill.color = const Color(0x33000000);
        canvas.drawRect(Rect.fromLTRB(0, -half, half, half), _fill);
        _stroke
          ..color = const Color(0x66000000)
          ..strokeWidth = 3;
        canvas.drawLine(Offset(0, -half), Offset(0, half), _stroke);
        canvas.drawRect(roof, _stroke);
        _fill.color = const Color(0xFF6C584C);
        canvas.drawRect(Rect.fromLTWH(half * 0.35, -half * 0.75, half * 0.3, half * 0.3), _fill);
        canvas.restore();
    }
  }

  void _drawLabels(Canvas canvas, GulpWorld w) {
    for (final h in w.holes) {
      if (!h.alive) continue;
      final sx = (h.pos.x - _camX) * _zoom + size.x / 2;
      final sy = (h.pos.y - h.radius - 8 - _camY) * _zoom + size.y / 2;
      if (sx < -60 || sx > size.x + 60 || sy < -20 || sy > size.y + 20) continue;
      CanvasText.draw(
        canvas,
        '${h.name} · ${h.level}',
        Offset(sx, sy),
        size: 12,
        align: Alignment.bottomCenter,
        color: holeColor(h),
      );
    }
  }

  void _drawStick(Canvas canvas) {
    final o = _stickOrigin;
    final k = _stickKnob;
    if (o == null || k == null) return;
    _fill.color = const Color(0x22FFFFFF);
    canvas.drawCircle(Offset(o.x, o.y), _stickRadius, _fill);
    _fill.color = const Color(0x66FFFFFF);
    canvas.drawCircle(Offset(k.x, k.y), 24, _fill);
  }

  void _drawHud(Canvas canvas, GulpWorld w) {
    final top = safePadding.top + 14;
    final secs = w.timeLeft.ceil();
    CanvasText.draw(
      canvas,
      '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
      Offset(size.x / 2, top),
      size: 22,
      align: Alignment.topCenter,
      color: secs <= 10 ? const Color(0xFFFF5C8A) : Colors.white,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(size.x - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
    );
    // Progress toward the next size level.
    final p = w.player;
    final lo = GulpWorld.xpForLevel(p.level), hi = GulpWorld.xpForLevel(p.level + 1);
    const mapW = 72.0;
    drawBar(canvas, Rect.fromLTWH(16, hudTop, size.x - 32 - mapW - 12, 10), (p.xp - lo) / (hi - lo), kAccent);
    CanvasText.draw(
      canvas,
      'Rank #${w.playerRank}/${w.holes.length}   Lv ${p.level}   City ${(w.cityShare * 100).round()}%'
      '${p.shield > 0 ? '   Safe ${p.shield.ceil()}s' : ''}',
      Offset(16, hudTop + 14),
      size: 12,
      color: Colors.white70,
    );
    _drawMinimap(canvas, w, Rect.fromLTWH(size.x - 16 - mapW, hudTop, mapW, mapW * w.height / w.width));
    if (_banner > 0 && _bannerText.isNotEmpty) {
      CanvasText.draw(
        canvas,
        _bannerText,
        Offset(size.x / 2, size.y * 0.3),
        size: 30,
        align: Alignment.center,
        color: const Color(0xFFFFD166),
        weight: FontWeight.w900,
      );
    }
    if (w.time < 4 && !w.isOver) {
      CanvasText.draw(
        canvas,
        'Drag to steer · swallow anything smaller',
        Offset(size.x / 2, size.y - safePadding.bottom - 40),
        size: 14,
        align: Alignment.center,
        color: Colors.white70,
      );
    }
  }

  void _drawMinimap(Canvas canvas, GulpWorld w, Rect r) {
    _fill.color = const Color(0x99000000);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), _fill);
    final sx = r.width / w.width, sy = r.height / w.height;
    final vw = size.x / _zoom, vh = size.y / _zoom;
    _stroke
      ..color = const Color(0x88FFFFFF)
      ..strokeWidth = 1;
    canvas.drawRect(
      Rect.fromLTWH(r.left + (_camX - vw / 2) * sx, r.top + (_camY - vh / 2) * sy, vw * sx, vh * sy),
      _stroke,
    );
    for (final h in w.holes) {
      if (!h.alive) continue;
      _fill.color = holeColor(h);
      canvas.drawCircle(
        Offset(r.left + h.pos.x * sx, r.top + h.pos.y * sy),
        math.max(2.5, h.radius * sx * 1.6),
        _fill,
      );
    }
  }
}
