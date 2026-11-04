import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/events.dart';
import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import 'pong_world.dart';

class QuadPongCartridge extends FlameCartridge<QuadPongGame> {
  const QuadPongCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'quad-pong',
    title: 'Quad Pong',
    tagline: 'Four walls, four paddles, one table.',
    description:
        'Paddle battle on a square court with a paddle on every edge. Play alone against three CPUs, '
        'or put the phone flat on a table and play with up to four friends, one edge each. Miss '
        'the ball and you lose a life; last paddle standing wins.',
    genre: 'Party paddle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFF9F1C),
    icon: Icons.crop_square_rounded,
    tags: ['party', 'paddle', 'local multiplayer', 'multiplayer-ready'],
    controls: ['Drag along your edge to move your paddle', 'Each player owns the edge nearest them'],
    mechanics: ['4-way pong', 'lives', 'CPU fill-ins', 'same-device multiplayer'],
    goal: 'Be the last paddle with lives left.',
    maxPlayers: 4,
    localMultiplayer: true,
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  QuadPongGame createGame(FlameCartridgeSession<QuadPongGame> session) => QuadPongGame(session);
}

class QuadPongGame extends AsobiFlameGame with MultiTouchDragDetector {
  QuadPongGame(super.session, {this.seed});

  final int? seed;
  PongWorld? court;
  int humans = 1;
  final Map<int, int> _pointerSeat = {};
  final List<PongAi> _ais = [];
  bool _reported = false;
  double _flash = 0;

  static const List<Color> seatColors = [
    Color(0xFF4EA8FF),
    Color(0xFFFF5A5F),
    Color(0xFF3DDC97),
    Color(0xFFFFC145),
  ];
  static const List<String> seatNames = ['Bottom', 'Top', 'Left', 'Right'];

  @override
  int get entityCount => court?.entityCount ?? 0;

  // ------------------------------------------------------------ layout
  Rect get courtRect {
    final side = math.min(size.x - 24, size.y - hudTop - safePadding.bottom - 120);
    return Rect.fromCenter(
      center: Offset(size.x / 2, (hudTop + size.y - safePadding.bottom) / 2 + 10),
      width: side,
      height: side,
    );
  }

  Rect menuButton(int i) {
    final w = math.min(300.0, size.x - 48);
    return Rect.fromCenter(center: Offset(size.x / 2, size.y * 0.42 + i * 70), width: w, height: 56);
  }

  /// Human seat order: 1 player = bottom; 2 = bottom/top; 3 adds left; 4 adds right.
  bool isHuman(int seat) => seat < humans;

  void start(int players) {
    humans = players;
    court = PongWorld(seats: 4, seed: seed ?? DateTime.now().millisecondsSinceEpoch);
    _ais
      ..clear()
      ..addAll([for (var s = humans; s < 4; s++) PongAi(s, skill: 0.55)]);
    audio.play(Sfx.tap);
  }

  /// Which edge a screen point belongs to (nearest edge of the court).
  int seatFor(Vector2 p) {
    final c = courtRect.center;
    final dx = p.x - c.dx, dy = p.y - c.dy;
    if (dy.abs() >= dx.abs()) return dy >= 0 ? 0 : 1;
    return dx < 0 ? 2 : 3;
  }

  double _along(int seat, Vector2 p) {
    final r = courtRect;
    return seat <= 1 ? ((p.x - r.left) / r.width) : ((p.y - r.top) / r.height);
  }

  @override
  void onPointerDown(Vector2 position) {
    if (court == null) {
      for (var i = 0; i < 3; i++) {
        if (menuButton(i).contains(Offset(position.x, position.y))) start(const [1, 2, 4][i]);
      }
    }
  }

  void touchStart(int pointer, Vector2 p) {
    final w = court;
    if (w == null) return;
    final seat = seatFor(p);
    if (!isHuman(seat)) return;
    _pointerSeat[pointer] = seat;
    w.setInput(seat, PongInput(_along(seat, p)));
  }

  void touchMove(int pointer, Vector2 p) {
    final seat = _pointerSeat[pointer];
    if (seat != null) court?.setInput(seat, PongInput(_along(seat, p)));
  }

  @override
  void onDragStart(int pointerId, DragStartInfo info) => touchStart(pointerId, info.eventPosition.widget);

  @override
  void onDragUpdate(int pointerId, DragUpdateInfo info) => touchMove(pointerId, info.eventPosition.widget);

  @override
  void onDragEnd(int pointerId, DragEndInfo info) => _pointerSeat.remove(pointerId);

  @override
  void onDragCancel(int pointerId) => _pointerSeat.remove(pointerId);

  // ------------------------------------------------------------ update
  @override
  void update(double dt) {
    super.update(dt);
    final w = court;
    if (w == null) return;
    if (_flash > 0) _flash -= dt;
    for (final ai in _ais) {
      w.setInput(ai.seat, ai.think(w));
    }
    final rally = w.rally;
    final lives = [for (final p in w.paddles) p.lives];
    w.update(dt);
    if (w.rally > rally) audio.play(Sfx.tap);
    for (var i = 0; i < 4; i++) {
      if (w.paddles[i].lives < lives[i]) {
        audio.play(Sfx.hit);
        _flash = 0.3;
      }
    }
    if (w.isOver && !_reported) {
      _reported = true;
      final winner = w.winner ?? 0;
      final solo = humans == 1;
      finish(
        RunResult(
          score: w.paddles[0].lives * 100 + w.tick ~/ 120,
          won: solo ? winner == 0 : null,
          headline: solo
              ? (winner == 0 ? 'Last paddle standing!' : '${seatNames[winner]} CPU took the table.')
              : '${seatNames[winner]} player wins!',
          details: {'Players': '$humans human, ${4 - humans} CPU', 'Rally ticks': '${w.tick}'},
        ),
      );
    }
  }

  // ------------------------------------------------------------ render
  final Paint _p = Paint();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final w = court;
    if (w == null) {
      _drawMenu(canvas);
      return;
    }
    final r = courtRect;
    double sx(double x) => r.left + x / PongWorld.size * r.width;
    double sy(double y) => r.top + y / PongWorld.size * r.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(r.inflate(6), const Radius.circular(10)),
      _p..color = const Color(0xFF151833),
    );
    canvas.drawLine(r.topLeft, r.bottomRight, Paint()..color = const Color(0x22FFFFFF));
    canvas.drawLine(r.topRight, r.bottomLeft, Paint()..color = const Color(0x22FFFFFF));
    const thick = 2.2;
    for (final p in w.paddles) {
      final c = seatColors[p.seat];
      final paint = Paint()
        ..color = p.out ? const Color(0x33FFFFFF) : c
        ..strokeWidth = p.out ? 3 : 8
        ..strokeCap = StrokeCap.round;
      final half = PongWorld.paddleLen / 2;
      final a = p.pos * PongWorld.size;
      switch (p.seat) {
        case 0:
          p.out
              ? canvas.drawLine(r.bottomLeft, r.bottomRight, paint)
              : canvas.drawLine(
                  Offset(sx(a - half), sy(PongWorld.size - thick)),
                  Offset(sx(a + half), sy(PongWorld.size - thick)),
                  paint,
                );
        case 1:
          p.out
              ? canvas.drawLine(r.topLeft, r.topRight, paint)
              : canvas.drawLine(Offset(sx(a - half), sy(thick)), Offset(sx(a + half), sy(thick)), paint);
        case 2:
          p.out
              ? canvas.drawLine(r.topLeft, r.bottomLeft, paint)
              : canvas.drawLine(Offset(sx(thick), sy(a - half)), Offset(sx(thick), sy(a + half)), paint);
        default:
          p.out
              ? canvas.drawLine(r.topRight, r.bottomRight, paint)
              : canvas.drawLine(
                  Offset(sx(PongWorld.size - thick), sy(a - half)),
                  Offset(sx(PongWorld.size - thick), sy(a + half)),
                  paint,
                );
      }
    }
    canvas.drawCircle(
      Offset(sx(w.ball.x), sy(w.ball.y)),
      PongWorld.ballRadius / PongWorld.size * r.width,
      _p..color = Colors.white,
    );
    // Lives next to each edge (rotated so each player reads their own).
    for (final p in w.paddles) {
      final label = '${isHuman(p.seat) ? 'P${p.seat + 1}' : 'CPU'}  ${'o' * math.max(0, p.lives)}';
      final (Offset at, double rot) = switch (p.seat) {
        0 => (Offset(r.center.dx, r.bottom + 22), 0.0),
        1 => (Offset(r.center.dx, r.top - 22), math.pi),
        2 => (Offset(r.left + 14, r.center.dy), math.pi / 2),
        _ => (Offset(r.right - 14, r.center.dy), -math.pi / 2),
      };
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(rot);
      CanvasText.draw(
        canvas,
        label,
        Offset.zero,
        size: 13,
        align: Alignment.center,
        color: seatColors[p.seat],
      );
      canvas.restore();
    }
    if (_flash > 0) {
      canvas.drawRect(
        Offset.zero & Size(size.x, size.y),
        Paint()..color = Colors.white.withValues(alpha: _flash * 0.25),
      );
    }
  }

  void _drawMenu(Canvas canvas) {
    CanvasText.draw(
      canvas,
      'QUAD PONG',
      Offset(size.x / 2, size.y * 0.24),
      size: 34,
      align: Alignment.center,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      'Lay the phone flat. Each player takes an edge.',
      Offset(size.x / 2, size.y * 0.24 + 40),
      size: 13,
      align: Alignment.center,
      color: Colors.white70,
    );
    const labels = ['1 player vs 3 CPU', '2 players (bottom/top) + 2 CPU', '4 players, one per edge'];
    for (var i = 0; i < 3; i++) {
      final b = menuButton(i);
      canvas.drawRRect(
        RRect.fromRectAndRadius(b, const Radius.circular(28)),
        _p..color = i == 0 ? const Color(0xFFFF9F1C) : const Color(0xFF2A2F55),
      );
      CanvasText.draw(
        canvas,
        labels[i],
        b.center,
        size: 16,
        align: Alignment.center,
        color: i == 0 ? Colors.black : Colors.white,
        weight: FontWeight.w800,
      );
    }
  }
}
