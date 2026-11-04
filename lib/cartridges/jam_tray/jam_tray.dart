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
import 'jam_world.dart';

class JamTrayCartridge extends FlameCartridge<JamTrayGame> {
  const JamTrayCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'jam-tray',
    title: 'Jam Tray',
    tagline: 'Pick three. Clear the stack. Mind the tray.',
    description:
        'A layered tile-matching puzzle. Tap uncovered tiles to drop them into a seven-slot '
        'tray; three of a kind pop for points. Peel the whole stack away before the tray '
        'jams. Two helpers per run: Undo and Shuffle.',
    genre: 'Tile-matching puzzle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFF7A45),
    icon: Icons.layers_rounded,
    tags: ['puzzle', 'match-3', 'tiles', 'casual', 'levels'],
    controls: [
      'Tap a bright (uncovered) tile to move it into the tray',
      'Tap UNDO to return the last tile, SHUFFLE to reshuffle the board',
    ],
    mechanics: ['layered tiles', 'match three', 'limited tray', 'undo', 'shuffle', 'levels'],
    goal: 'Clear every tile from the board. Three alike in the tray pop; a full tray of 7 loses.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  JamTrayGame createGame(FlameCartridgeSession<JamTrayGame> session) => JamTrayGame(session);
}

/// Colours of the tile glyphs, one per kind.
const List<Color> kJamKindColors = [
  Color(0xFFE8364F), // circle
  Color(0xFFF08A00), // triangle
  Color(0xFF2BA866), // square
  Color(0xFFD9A400), // star
  Color(0xFF1FA4C4), // diamond
  Color(0xFFE5508F), // heart
  Color(0xFF3A6EF0), // cross
  Color(0xFF8752F0), // hexagon
  Color(0xFF8B5A2B), // ring
  Color(0xFF3E4A66), // leaf
];

class JamTrayGame extends AsobiFlameGame {
  JamTrayGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      jam = JamWorld(
        seed: seed ?? DateTime.now().microsecondsSinceEpoch,
        level: math.max(1, session.context.save.intData('level', 1)),
      );

  final int? seed;
  final int level;
  final JamWorld jam;
  final Sparks sparks = Sparks();

  bool _reported = false;
  double _endDelay = 0.9;
  double _clock = 0;

  /// Displayed rect of each tray tile, eased toward its slot every frame.
  final Map<int, Rect> _trayPos = {};
  final List<_Ghost> _ghosts = [];
  final Map<int, double> _blockedFlash = {};

  @override
  int get entityCount => jam.entityCount + sparks.count + _ghosts.length;

  @override
  Color backgroundColor() => const Color(0xFF1C1226);

  // ---------------------------------------------------------------- layout
  double get _bottomInset => safePadding.bottom + 14;
  double get _slotSize => math.min((size.x - 32 - 6 * 5) / JamWorld.trayCapacity, 54.0);
  Rect get _trayRect {
    final w = JamWorld.trayCapacity * _slotSize + 6 * 5 + 20;
    final h = _slotSize + 20;
    return Rect.fromLTWH((size.x - w) / 2, size.y - _bottomInset - h, w, h);
  }

  Rect _slotRect(int i) {
    final t = _trayRect;
    return Rect.fromLTWH(t.left + 10 + i * (_slotSize + 5), t.top + 10, _slotSize, _slotSize);
  }

  Rect _buttonRect(int i) {
    final w = math.min(150.0, (size.x - 48) / 2);
    const h = 42.0;
    final top = _trayRect.top - 14 - h;
    final left = size.x / 2 + (i == 0 ? -w - 8 : 8);
    return Rect.fromLTWH(left, top, w, h);
  }

  double get _boardTop => hudTop + 34;
  double get _boardBottom => _buttonRect(0).top - 14;
  double get _unit => math.max(
    1,
    math.min((size.x - 24) / JamWorld.boardWidth, (_boardBottom - _boardTop) / JamWorld.boardHeight),
  );
  Offset get _boardOrigin {
    final u = _unit;
    final w = JamWorld.boardWidth * u;
    final h = JamWorld.boardHeight * u;
    return Offset((size.x - w) / 2, _boardTop + (_boardBottom - _boardTop - h) / 2);
  }

  /// On-screen rect of a board tile, including a small lift per layer.
  Rect _tileRect(JamTile t) {
    final u = _unit;
    final o = _boardOrigin;
    final lift = t.layer * u * 0.06;
    return Rect.fromLTWH(o.dx + t.x * u - lift, o.dy + t.y * u - lift, u, u).deflate(u * 0.03);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (jam.isOver || size.x <= 0) return;
    final p = Offset(position.x, position.y);
    if (_buttonRect(0).contains(p)) {
      final t = jam.undo();
      if (t != null) {
        _trayPos.remove(t.id);
        audio.play(Sfx.whoosh);
        audio.haptic(HapticKind.selection);
      } else {
        audio.play(Sfx.thud);
      }
      return;
    }
    if (_buttonRect(1).contains(p)) {
      if (jam.shuffle()) {
        audio.play(Sfx.powerup);
        audio.haptic(HapticKind.medium);
        if (!ctx.settings.reducedEffects) {
          for (final t in jam.tiles.where((t) => t.onBoard)) {
            final r = _tileRect(t);
            sparks.burst(r.center.dx, r.center.dy, 2, const Color(0xFFFFE3B3), speed: 90, life: 0.35);
          }
        }
      } else {
        audio.play(Sfx.thud);
      }
      return;
    }
    final order = jam.drawOrder();
    for (var i = order.length - 1; i >= 0; i--) {
      final t = order[i];
      final from = _tileRect(t);
      if (!from.contains(p)) continue;
      _handleTap(t, from);
      return;
    }
  }

  void _handleTap(JamTile t, Rect from) {
    final r = jam.tap(t.id);
    switch (r.outcome) {
      case JamOutcome.ignored:
        return;
      case JamOutcome.blocked:
        _blockedFlash[t.id] = 0.35;
        audio.play(Sfx.thud);
        audio.haptic(HapticKind.light);
        return;
      case JamOutcome.moved:
      case JamOutcome.triple:
      case JamOutcome.won:
      case JamOutcome.lost:
        break;
    }
    if (r.cleared) {
      // The three tiles leave the tray at once; show them popping.
      final target = _slotRect(r.clearedSlot + 1);
      for (final id in _trayPos.keys.toList()) {
        if (!jam.tray.any((e) => e.id == id)) {
          _ghosts.add(_Ghost(r.clearedKind, _trayPos.remove(id)!, target));
        }
      }
      _ghosts.add(_Ghost(r.clearedKind, from, target));
      final reduced = ctx.settings.reducedEffects;
      sparks.burst(
        target.center.dx,
        target.center.dy,
        reduced ? 6 : 22,
        kJamKindColors[r.clearedKind % kJamKindColors.length],
        speed: 200,
      );
      audio.play(Sfx.merge);
      audio.haptic(HapticKind.medium);
    } else {
      _trayPos[t.id] = from;
      audio.play(Sfx.tap);
      audio.haptic(HapticKind.selection);
    }
    if (r.outcome == JamOutcome.won) {
      audio.play(Sfx.win);
      final c = _boardOrigin + Offset(JamWorld.boardWidth * _unit / 2, JamWorld.boardHeight * _unit / 2);
      sparks.burst(c.dx, c.dy, ctx.settings.reducedEffects ? 12 : 60, const Color(0xFFFFD166), speed: 320);
    } else if (r.outcome == JamOutcome.lost) {
      audio.play(Sfx.lose);
      audio.haptic(HapticKind.heavy);
    }
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    jam.update(dt);
    sparks.update(dt);
    // Ease tray tiles toward their slots.
    final k = 1 - math.exp(-dt * 16);
    for (var i = 0; i < jam.tray.length; i++) {
      final id = jam.tray[i].id;
      final target = _slotRect(i);
      final cur = _trayPos[id];
      _trayPos[id] = cur == null ? target : Rect.lerp(cur, target, k)!;
    }
    _trayPos.removeWhere((id, _) => !jam.tray.any((e) => e.id == id));
    for (final g in _ghosts) {
      g.t += dt / 0.28;
    }
    _ghosts.removeWhere((g) => g.t >= 1);
    for (final id in _blockedFlash.keys.toList()) {
      final v = _blockedFlash[id]! - dt;
      if (v <= 0) {
        _blockedFlash.remove(id);
      } else {
        _blockedFlash[id] = v;
      }
    }
    if (jam.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _report() {
    _reported = true;
    final won = jam.won;
    if (won) {
      session.context.save.data['level'] = level + 1;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: jam.score,
        won: won,
        headline: won
            ? 'Stack $level cleared! Level ${level + 1} unlocked.'
            : 'The tray jammed on level $level.',
        details: {
          'Level': '$level',
          'Triples': '${jam.triples}',
          'Tiles left': '${jam.boardCount + jam.tray.length}',
          if (won) 'Time bonus': '${jam.timeBonus}',
          'Time': '${jam.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    _drawBoardBackdrop(canvas);
    for (final t in jam.drawOrder()) {
      _drawTile(canvas, t.kind, _tileRect(t), dim: !jam.isFree(t), flash: _blockedFlash[t.id]);
    }
    _drawTray(canvas);
    _drawButtons(canvas);
    for (final g in _ghosts) {
      final e = _easeOut(g.t);
      final r = Rect.lerp(g.from, g.to, e)!;
      final s = 1 - g.t * 0.8;
      _drawTile(canvas, g.kind, Rect.fromCenter(center: r.center, width: r.width * s, height: r.height * s));
    }
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _drawBoardBackdrop(Canvas canvas) {
    final o = _boardOrigin;
    final u = _unit;
    final r = Rect.fromLTWH(o.dx, o.dy, JamWorld.boardWidth * u, JamWorld.boardHeight * u).inflate(10);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(18)),
      Paint()..color = const Color(0xFF261A33),
    );
  }

  final Paint _paint = Paint();

  void _drawTile(Canvas canvas, int kind, Rect r, {bool dim = false, double? flash}) {
    final rad = Radius.circular(r.width * 0.18);
    final depth = r.height * 0.08;
    _paint
      ..style = PaintingStyle.fill
      ..color = const Color(0x66000000);
    canvas.drawRRect(RRect.fromRectAndRadius(r.shift(Offset(0, depth * 1.6)), rad), _paint);
    _paint.color = const Color(0xFFCDB89A);
    canvas.drawRRect(RRect.fromRectAndRadius(r.shift(Offset(0, depth)), rad), _paint);
    _paint.color = const Color(0xFFFFF4E0);
    canvas.drawRRect(RRect.fromRectAndRadius(r, rad), _paint);
    final color = kJamKindColors[kind % kJamKindColors.length];
    _paint.color = color.withValues(alpha: 0.14);
    canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(r.width * 0.08), rad), _paint);
    drawJamGlyph(canvas, kind, r.center, r.width * 0.3, color);
    if (dim) {
      _paint.color = const Color(0xA8160D20);
      canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(0.5), rad), _paint);
    }
    if (flash != null) {
      _paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFFF4D6D).withValues(alpha: (flash / 0.35).clamp(0.0, 1.0));
      canvas.drawRRect(RRect.fromRectAndRadius(r, rad), _paint);
      _paint.style = PaintingStyle.fill;
    }
  }

  void _drawTray(Canvas canvas) {
    final tr = _trayRect;
    final danger = jam.tray.length >= JamWorld.trayCapacity - 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(tr, const Radius.circular(16)),
      Paint()..color = const Color(0xFF3A2547),
    );
    final pulse = 0.5 + 0.5 * math.sin(_clock * 8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tr, const Radius.circular(16)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = danger ? 3 : 2
        ..color = danger
            ? Color.lerp(const Color(0xFFFF4D6D), const Color(0xFFFFB3C0), pulse)!
            : const Color(0xFF5E3F73),
    );
    for (var i = 0; i < JamWorld.trayCapacity; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(_slotRect(i), Radius.circular(_slotSize * 0.18)),
        Paint()..color = const Color(0xFF24172F),
      );
    }
    for (var i = 0; i < jam.tray.length; i++) {
      final t = jam.tray[i];
      _drawTile(canvas, t.kind, _trayPos[t.id] ?? _slotRect(i));
    }
  }

  void _drawButtons(Canvas canvas) {
    final labels = ['UNDO', 'SHUFFLE'];
    final left = [jam.undosLeft, jam.shufflesLeft];
    final enabled = [jam.canUndo, jam.canShuffle];
    for (var i = 0; i < 2; i++) {
      final r = _buttonRect(i);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(21));
      canvas.drawRRect(rr, Paint()..color = enabled[i] ? const Color(0xFFFF7A45) : const Color(0xFF3A2C44));
      CanvasText.draw(
        canvas,
        '${labels[i]}  ${left[i]}',
        r.center,
        size: 15,
        align: Alignment.center,
        weight: FontWeight.w800,
        color: enabled[i] ? Colors.white : Colors.white38,
      );
    }
  }

  void _drawHud(Canvas canvas) {
    CanvasText.draw(canvas, 'LEVEL $level', Offset(16, hudTop), size: 18, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      '${jam.score}',
      Offset(size.x - 16, hudTop),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '${jam.boardCount} tiles',
      Offset(size.x / 2, hudTop + 4),
      size: 13,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
    if (!jam.isOver && jam.moves == 0 && _clock < 6) {
      CanvasText.draw(
        canvas,
        'Tap bright tiles · three alike in the tray pop',
        Offset(size.x / 2, _buttonRect(0).top - 12),
        size: 13,
        align: Alignment.bottomCenter,
        color: Colors.white70,
      );
    }
    if (jam.isOver) {
      CanvasText.draw(
        canvas,
        jam.won ? 'BOARD CLEARED!' : 'TRAY JAMMED',
        Offset(size.x / 2, size.y * 0.42),
        size: 34,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: jam.won ? const Color(0xFFFFD166) : const Color(0xFFFF4D6D),
      );
    }
  }
}

class _Ghost {
  _Ghost(this.kind, this.from, this.to);
  final int kind;
  final Rect from;
  final Rect to;
  double t = 0;
}

double _easeOut(double t) => 1 - (1 - t) * (1 - t);

/// Draws the procedural glyph for [kind] centred at [c] with radius [r].
void drawJamGlyph(Canvas canvas, int kind, Offset c, double r, Color color) {
  final paint = Paint()..color = color;
  Path poly(int n, double radius, double rot) {
    final p = Path();
    for (var i = 0; i < n; i++) {
      final a = rot + i * math.pi * 2 / n;
      final pt = c + Offset(math.cos(a), math.sin(a)) * radius;
      if (i == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    return p..close();
  }

  switch (kind % 10) {
    case 0: // circle
      canvas.drawCircle(c, r * 0.9, paint);
    case 1: // triangle
      canvas.drawPath(poly(3, r * 1.05, -math.pi / 2).shift(Offset(0, r * 0.12)), paint);
    case 2: // square
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: r * 1.6, height: r * 1.6),
          Radius.circular(r * 0.2),
        ),
        paint,
      );
    case 3: // star
      final p = Path();
      for (var i = 0; i < 10; i++) {
        final a = -math.pi / 2 + i * math.pi / 5;
        final rr = i.isEven ? r * 1.05 : r * 0.45;
        final pt = c + Offset(math.cos(a), math.sin(a)) * rr;
        if (i == 0) {
          p.moveTo(pt.dx, pt.dy);
        } else {
          p.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(p..close(), paint);
    case 4: // diamond
      canvas.drawPath(poly(4, r * 1.05, -math.pi / 2), paint);
    case 5: // heart
      final p = Path()
        ..moveTo(c.dx, c.dy + r * 0.95)
        ..cubicTo(c.dx - r * 1.5, c.dy - r * 0.1, c.dx - r * 0.7, c.dy - r * 1.2, c.dx, c.dy - r * 0.45)
        ..cubicTo(c.dx + r * 0.7, c.dy - r * 1.2, c.dx + r * 1.5, c.dy - r * 0.1, c.dx, c.dy + r * 0.95)
        ..close();
      canvas.drawPath(p, paint);
    case 6: // cross
      final w = r * 0.55;
      canvas.drawRect(Rect.fromCenter(center: c, width: w, height: r * 1.8), paint);
      canvas.drawRect(Rect.fromCenter(center: c, width: r * 1.8, height: w), paint);
    case 7: // hexagon
      canvas.drawPath(poly(6, r, 0), paint);
    case 8: // ring
      canvas.drawCircle(
        c,
        r * 0.7,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.42,
      );
    case 9: // leaf
      final p = Path()
        ..moveTo(c.dx - r, c.dy + r * 0.8)
        ..quadraticBezierTo(c.dx - r * 0.9, c.dy - r * 0.9, c.dx + r, c.dy - r * 0.8)
        ..quadraticBezierTo(c.dx + r * 0.9, c.dy + r * 0.9, c.dx - r, c.dy + r * 0.8)
        ..close();
      canvas.drawPath(p, paint);
  }
}
