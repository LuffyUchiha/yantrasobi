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
import 'claim_world.dart';

class InkClaimCartridge extends FlameCartridge<InkClaimGame> {
  const InkClaimCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'ink-claim',
    title: 'Ink Claim',
    tagline: 'Leave home. Draw a loop. Own the map.',
    description:
        'A territory-painting duel. Slip out of your colour, trace a loop and return home to '
        'claim everything inside. Your trail is fragile: if anyone crosses it you are out, '
        'and if you cut a rival\'s trail they are out. Paint half the board to win.',
    genre: 'Territory capture',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF35D0BA),
    icon: Icons.format_paint_rounded,
    tags: ['io', 'territory', 'paint', 'arena'],
    controls: ['Swipe up/down/left/right to turn', 'You keep moving on your own'],
    mechanics: ['territory capture', 'trail cutting', 'flood fill', 'rival painters'],
    goal: 'Own 50% of the board. Crossing your own trail or getting cut ends the run.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  InkClaimGame createGame(FlameCartridgeSession<InkClaimGame> session) => InkClaimGame(session);
}

class InkClaimGame extends AsobiFlameGame {
  InkClaimGame(super.session, {int? seed})
    : world0 = ClaimWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch);

  final ClaimWorld world0;
  final Sparks sparks = Sparks();
  Vector2? _swipeOrigin;
  bool _reported = false;
  double _hint = 4;

  static const List<Color> palette = [
    Color(0xFF35D0BA), // player
    Color(0xFFFF6B6B),
    Color(0xFFB57BFF),
    Color(0xFFFFC145),
    Color(0xFF4EA8FF),
  ];

  @override
  int get entityCount => world0.entityCount + sparks.count;

  // Board layout in screen space.
  double _cell = 10;
  Offset _origin = Offset.zero;

  void _layout() {
    final top = hudTop + 26;
    final bottom = safePadding.bottom + 16;
    final availH = size.y - top - bottom;
    _cell = math.min(size.x / world0.cols, availH / world0.rows);
    final w = _cell * world0.cols, h = _cell * world0.rows;
    _origin = Offset((size.x - w) / 2, top + (availH - h) / 2);
  }

  Offset _cellCenter(double x, double y) => _origin + Offset((x + 0.5) * _cell, (y + 0.5) * _cell);

  @override
  void onPointerDown(Vector2 position) {
    _swipeOrigin = position.clone();
    _hint = 0;
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final o = _swipeOrigin;
    if (o == null) return;
    final d = position - o;
    const threshold = 18.0;
    if (d.length < threshold) return;
    final dir = d.x.abs() > d.y.abs() ? (d.x > 0 ? Dir.right : Dir.left) : (d.y > 0 ? Dir.down : Dir.up);
    world0.steer(dir);
    _swipeOrigin = position.clone();
  }

  @override
  void onPointerUp(Vector2 position) => _swipeOrigin = null;

  @override
  void update(double dt) {
    super.update(dt);
    final w = world0;
    w.update(dt);
    if (_hint > 0) _hint -= dt;
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      final c = _cellCenter(e.x.toDouble(), e.y.toDouble());
      switch (e.kind) {
        case ClaimEventKind.capture:
          if (e.painter == 1) {
            audio.play(e.amount > 20 ? Sfx.powerup : Sfx.coin);
            audio.haptic(HapticKind.light);
            sparks.burst(c.dx, c.dy, reduced ? 6 : 18, palette[0]);
          }
        case ClaimEventKind.eliminate:
          audio.play(Sfx.pop);
          sparks.burst(c.dx, c.dy, reduced ? 8 : 30, palette[(e.painter - 1) % palette.length]);
        case ClaimEventKind.playerDied:
          audio.haptic(HapticKind.heavy);
          sparks.burst(c.dx, c.dy, 30, palette[0]);
        case ClaimEventKind.respawn:
          break;
      }
    }
    sparks.update(dt);
    if (w.isOver && !_reported) {
      _reported = true;
      final pct = (w.playerShare * 100).toStringAsFixed(1);
      finish(
        RunResult(
          score: w.score,
          won: w.phase == ClaimPhase.won,
          headline: w.phase == ClaimPhase.won
              ? 'You painted $pct% of the board!'
              : 'Trail cut at $pct% coverage.',
          details: {
            'Coverage': '$pct%',
            'Rivals cut': '${w.player.kills}',
            'Loops closed': '${w.captures}',
            'Time': '${w.time.toStringAsFixed(0)}s',
          },
        ),
      );
    }
  }

  final Paint _paint = Paint();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    _layout();
    final w = world0;
    // Board background.
    final board = Rect.fromLTWH(_origin.dx, _origin.dy, _cell * w.cols, _cell * w.rows);
    canvas.drawRRect(
      RRect.fromRectAndRadius(board.inflate(4), const Radius.circular(8)),
      _paint..color = const Color(0xFF1B1D33),
    );
    // Territory: merge horizontal runs of the same owner into one rect.
    for (var y = 0; y < w.rows; y++) {
      var x = 0;
      while (x < w.cols) {
        final o = w.owner[w.idx(x, y)];
        var end = x + 1;
        while (end < w.cols && w.owner[w.idx(end, y)] == o) {
          end++;
        }
        if (o != 0) {
          _paint.color = palette[(o - 1) % palette.length].withValues(alpha: 0.55);
          canvas.drawRect(
            Rect.fromLTWH(_origin.dx + x * _cell, _origin.dy + y * _cell, (end - x) * _cell, _cell),
            _paint,
          );
        }
        x = end;
      }
    }
    // Trails.
    for (final p in w.painters) {
      if (!p.alive) continue;
      _paint.color = palette[(p.id - 1) % palette.length].withValues(alpha: 0.95);
      for (final c in p.trail) {
        final cx = c % w.cols, cy = c ~/ w.cols;
        canvas.drawRect(
          Rect.fromLTWH(
            _origin.dx + cx * _cell + _cell * 0.18,
            _origin.dy + cy * _cell + _cell * 0.18,
            _cell * 0.64,
            _cell * 0.64,
          ),
          _paint,
        );
      }
    }
    // Heads, interpolated toward the next cell for smooth motion.
    for (final p in w.painters) {
      if (!p.alive) continue;
      final t = p.progress.clamp(0.0, 1.0);
      final nx = (p.x + p.dir.dx * t).clamp(0.0, w.cols - 1.0);
      final ny = (p.y + p.dir.dy * t).clamp(0.0, w.rows - 1.0);
      final c = _cellCenter(nx, ny);
      final r = _cell * (p.isPlayer ? 0.95 : 0.8);
      canvas.drawCircle(c, r + 2, _paint..color = Colors.white);
      canvas.drawCircle(c, r, _paint..color = palette[(p.id - 1) % palette.length]);
      if (p.isPlayer) {
        final eye = c + Offset(p.dir.dx * r * 0.4, p.dir.dy * r * 0.4);
        canvas.drawCircle(eye, r * 0.3, _paint..color = const Color(0xFF14152A));
      }
    }
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _drawHud(Canvas canvas) {
    final w = world0;
    final top = safePadding.top + 14;
    final pct = w.playerShare * 100;
    CanvasText.draw(
      canvas,
      '${pct.toStringAsFixed(1)}%',
      Offset(size.x / 2, top),
      size: 22,
      align: Alignment.topCenter,
    );
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(size.x - 16, top),
      size: 20,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
    );
    final barRect = Rect.fromLTWH(16, hudTop, size.x - 32, 10);
    drawBar(canvas, barRect, w.playerShare / w.winShare, palette[0]);
    CanvasText.draw(
      canvas,
      'GOAL ${(w.winShare * 100).round()}%',
      Offset(size.x - 16, hudTop + 12),
      size: 11,
      align: Alignment.topRight,
      color: Colors.white54,
    );
    // Rival shares.
    var x = 16.0;
    for (final p in w.painters.skip(1)) {
      final s = (w.shareOf(p.id) * 100).toStringAsFixed(0);
      final sz = CanvasText.draw(
        canvas,
        p.alive ? '$s%' : 'out',
        Offset(x, hudTop + 12),
        size: 11,
        color: palette[(p.id - 1) % palette.length],
      );
      x += sz.width + 10;
    }
    if (_hint > 0) {
      CanvasText.draw(
        canvas,
        'Swipe to turn · loop back home to claim',
        Offset(size.x / 2, size.y - safePadding.bottom - 30),
        size: 14,
        align: Alignment.center,
        color: Colors.white,
      );
    }
  }
}
