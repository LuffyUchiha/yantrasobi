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
import 'kick_levels.dart';
import 'kick_world.dart';

class CurveKickCartridge extends FlameCartridge<CurveKickGame> {
  const CurveKickCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'curve-kick',
    title: 'Curve Kick',
    tagline: 'Draw the pass. Bend the shot. Win the moment.',
    description:
        'Football moments you play by drawing. Trace a path from the player on the ball: '
        'end it on a team-mate to pass, or curl it into the goal to shoot. Defenders cut out '
        'anything that comes too close, and the keeper reads straight shots, so bend it '
        'round them. Three attempts per moment.',
    genre: 'Football puzzle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF2ECC71),
    icon: Icons.sports_soccer_rounded,
    tags: ['sports', 'football', 'draw', 'puzzle'],
    controls: ['Drag from the player on the ball to draw the path', 'Release to kick'],
    mechanics: ['path drawing', 'passing chains', 'interceptions', 'keeper AI'],
    goal: 'Score within 3 attempts. End a path on a team-mate to pass first.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  CurveKickGame createGame(FlameCartridgeSession<CurveKickGame> session) => CurveKickGame(session);
}

class CurveKickGame extends AsobiFlameGame {
  CurveKickGame(super.session)
    : level = math.max(1, session.context.save.intData('level', 1)),
      match = KickWorld(levelNumber: math.max(1, session.context.save.intData('level', 1)));

  final int level;
  final KickWorld match;
  final Sparks sparks = Sparks();
  bool _reported = false;
  double _endDelay = 1.2;
  String? _banner;
  double _bannerTime = 0;
  final List<Offset> _trail = [];

  @override
  int get entityCount => match.entityCount + sparks.count;

  // ----------------------------------------------------------- layout
  double _scale = 10;
  Offset _origin = Offset.zero;
  static const double _viewTop = -3, _viewBottom = 50;

  void _layout() {
    final top = hudTop + 18;
    final bottom = safePadding.bottom + 40;
    final availH = size.y - top - bottom;
    _scale = math.min(size.x / kPitchWidth, availH / (_viewBottom - _viewTop));
    final w = kPitchWidth * _scale;
    _origin = Offset((size.x - w) / 2, top - _viewTop * _scale);
  }

  Offset toScreen(double x, double y) => _origin + Offset(x * _scale, y * _scale);
  (double, double) toPitch(Vector2 p) => ((p.x - _origin.dx) / _scale, (p.y - _origin.dy) / _scale);

  // ----------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    _layout();
    final (x, y) = toPitch(position);
    if (match.beginPath(x, y)) audio.play(Sfx.tap);
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final (x, y) = toPitch(position);
    match.extendPath(x, y);
  }

  @override
  void onPointerUp(Vector2 position) {
    final wasDrawing = match.drawing;
    match.releasePath();
    if (wasDrawing && match.phase == KickPhase.flying) {
      audio.play(Sfx.whoosh);
      _trail.clear();
    }
  }

  // ----------------------------------------------------------- update
  void _show(String text) {
    _banner = text;
    _bannerTime = 1.3;
  }

  @override
  void update(double dt) {
    super.update(dt);
    match.update(dt);
    sparks.update(dt);
    if (_bannerTime > 0) _bannerTime -= dt;
    if (match.phase == KickPhase.flying) {
      _trail.add(Offset(match.ball.x, match.ball.y));
      if (_trail.length > 24) _trail.removeAt(0);
    }
    for (final e in match.events) {
      final c = toScreen(e.x, e.y);
      switch (e.kind) {
        case KickEventKind.pass:
          audio.play(Sfx.pop);
          _show('Nice pass!');
          _trail.clear();
        case KickEventKind.intercepted:
          audio.play(Sfx.thud);
          _show('Intercepted!');
        case KickEventKind.saved:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.medium);
          _show('Saved by the keeper!');
        case KickEventKind.wide:
          _show('Wide of the post!');
        case KickEventKind.loose:
          _show('Nobody there!');
        case KickEventKind.goal:
          audio.play(Sfx.win);
          audio.haptic(HapticKind.heavy);
          _show('GOAL!');
          sparks.burst(
            c.dx,
            c.dy,
            ctx.settings.reducedEffects ? 20 : 70,
            const Color(0xFFFFD166),
            speed: 320,
          );
        case KickEventKind.attemptLost:
          _trail.clear();
      }
    }
    if (match.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) {
        _reported = true;
        final won = match.phase == KickPhase.won;
        if (won) {
          ctx.save.data['level'] = level + 1;
          ctx.commitSave();
        }
        finish(
          RunResult(
            score: match.score,
            won: won,
            headline: won
                ? '"${match.def.name}" won! Next moment unlocked.'
                : 'Out of attempts on "${match.def.name}".',
            details: {
              'Moment': '$level',
              'Passes': '${match.passes}',
              'Attempts left': '${math.max(0, match.attemptsLeft)}',
            },
          ),
        );
      }
    }
  }

  // ----------------------------------------------------------- render
  final Paint _p = Paint();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    _layout();
    _drawPitch(canvas);
    // Path preview / flight path.
    if (match.path.length > 1) {
      final path = Path();
      final first = toScreen(match.path.first.x, match.path.first.y);
      path.moveTo(first.dx, first.dy);
      for (final pt in match.path.skip(1)) {
        final o = toScreen(pt.x, pt.y);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: match.drawing ? 0.9 : 0.35),
      );
    }
    // Defenders.
    for (var i = 0; i < match.def.defenders.length; i++) {
      final d = match.defenderAt(i);
      _player(canvas, toScreen(d.x, d.y), const Color(0xFFFF5A5F), '${i + 2}');
    }
    // Team-mates and the holder.
    final ms = match.mates;
    for (var i = 0; i < ms.length; i++) {
      _player(
        canvas,
        toScreen(ms[i].x, ms[i].y),
        const Color(0xFF4EA8FF),
        '${7 + i}',
        ring: i == match.holderIndex,
      );
    }
    _player(
      canvas,
      toScreen(match.def.holder.$1, match.def.holder.$2),
      const Color(0xFF4EA8FF),
      '10',
      ring: match.holderIndex < 0,
    );
    // Keeper.
    _player(canvas, toScreen(match.keeperX, 0.8), const Color(0xFFFFC145), '1');
    // Ball + trail.
    for (var i = 0; i < _trail.length; i++) {
      final t = _trail[i];
      _p.color = Colors.white.withValues(alpha: i / _trail.length * 0.4);
      canvas.drawCircle(toScreen(t.dx, t.dy), _scale * 0.35, _p);
    }
    final b = toScreen(match.ball.x, match.ball.y);
    canvas.drawCircle(b, _scale * 0.5, _p..color = Colors.white);
    canvas.drawCircle(b, _scale * 0.2, _p..color = const Color(0xFF14152A));
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _player(Canvas canvas, Offset c, Color color, String number, {bool ring = false}) {
    final r = _scale * 1.0;
    if (ring) {
      canvas.drawCircle(
        c,
        r + 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );
    }
    canvas.drawCircle(c + const Offset(0, 2), r, _p..color = const Color(0x44000000));
    canvas.drawCircle(c, r, _p..color = color);
    CanvasText.draw(
      canvas,
      number,
      c,
      size: math.max(9, r * 0.9),
      align: Alignment.center,
      color: Colors.white,
    );
  }

  void _drawPitch(Canvas canvas) {
    final topLeft = toScreen(0, _viewTop);
    final bottomRight = toScreen(kPitchWidth, _viewBottom);
    final field = Rect.fromPoints(topLeft, bottomRight);
    for (var i = 0; i < 10; i++) {
      final y0 = _viewTop + i * (_viewBottom - _viewTop) / 10;
      final y1 = y0 + (_viewBottom - _viewTop) / 10;
      _p.color = i.isEven ? const Color(0xFF2E8B57) : const Color(0xFF34975F);
      canvas.drawRect(Rect.fromPoints(toScreen(0, y0), toScreen(kPitchWidth, y1)), _p);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white70;
    canvas.drawLine(toScreen(0, 0), toScreen(kPitchWidth, 0), line);
    canvas.drawRect(Rect.fromPoints(toScreen(8, 0), toScreen(32, 16.5)), line);
    canvas.drawRect(Rect.fromPoints(toScreen(14.5, 0), toScreen(25.5, 5.5)), line);
    canvas.drawCircle(toScreen(20, 11), 2, _p..color = Colors.white70);
    canvas.drawArc(
      Rect.fromCircle(center: toScreen(20, 11), radius: 9.15 * _scale),
      math.pi * 0.2,
      math.pi * 0.6,
      false,
      line,
    );
    // Goal and net.
    final g0 = toScreen(kPitchWidth / 2 - kGoalWidth / 2, -2.2),
        g1 = toScreen(kPitchWidth / 2 + kGoalWidth / 2, 0);
    canvas.drawRect(Rect.fromPoints(g0, g1), _p..color = const Color(0x55FFFFFF));
    final net = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (var x = g0.dx; x < g1.dx; x += 6) {
      canvas.drawLine(Offset(x, g0.dy), Offset(x, g1.dy), net);
    }
    canvas.drawRect(Rect.fromPoints(g0, g1), line..color = Colors.white);
    canvas.drawRect(field, line..color = Colors.white24);
  }

  void _drawHud(Canvas canvas) {
    final top = safePadding.top + 14;
    CanvasText.draw(canvas, 'MOMENT $level', Offset(size.x / 2, top), size: 18, align: Alignment.topCenter);
    CanvasText.draw(
      canvas,
      match.def.name,
      Offset(size.x / 2, top + 24),
      size: 13,
      align: Alignment.topCenter,
      color: Colors.white70,
    );
    for (var i = 0; i < match.def.attempts; i++) {
      canvas.drawCircle(
        Offset(size.x - 22 - i * 20.0, top + 12),
        7,
        _p..color = i < match.attemptsLeft ? Colors.white : const Color(0x33FFFFFF),
      );
    }
    if (match.drawing) {
      drawBar(
        canvas,
        Rect.fromLTWH(40, size.y - safePadding.bottom - 26, size.x - 80, 8),
        1 - match.pathLength / KickWorld.maxPathLength,
        Colors.white,
      );
    } else if (match.phase == KickPhase.aiming) {
      CanvasText.draw(
        canvas,
        match.passes == 0 ? 'Drag from #10 to draw the ball path' : 'Your ball now: draw the next path',
        Offset(size.x / 2, size.y - safePadding.bottom - 24),
        size: 14,
        align: Alignment.center,
        color: Colors.white,
      );
    }
    final banner = _banner;
    if (banner != null && _bannerTime > 0) {
      CanvasText.draw(
        canvas,
        banner,
        Offset(size.x / 2, size.y * 0.45),
        size: banner == 'GOAL!' ? 48 : 28,
        align: Alignment.center,
        color: banner == 'GOAL!' ? const Color(0xFFFFD166) : Colors.white,
        weight: FontWeight.w900,
      );
    }
  }
}
