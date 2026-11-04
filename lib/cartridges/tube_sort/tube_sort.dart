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
import 'sort_world.dart';

class TubeSortCartridge extends FlameCartridge<TubeSortGame> {
  const TubeSortCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'tube-sort',
    title: 'Tube Sort',
    tagline: 'Pour, stack, sort. One colour per tube.',
    description:
        'A calm colour-sorting puzzle. Tap a tube to lift its top balls, then tap another tube '
        'to pour them in. You can only pour onto a matching colour or into an empty tube. Fill '
        'every tube with a single colour to clear the level. Every deal is checked by a solver, '
        'so a solution always exists.',
    genre: 'Sorting puzzle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF7BDFF2),
    icon: Icons.science_rounded,
    tags: ['puzzle', 'sort', 'relaxing', 'colour'],
    controls: ['Tap a tube to pick it up', 'Tap another tube to pour', 'Undo / +Tube buttons'],
    mechanics: ['colour sorting', 'stack pouring', 'undo', 'solver-checked levels'],
    goal: 'Make every tube hold four balls of one colour.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  TubeSortGame createGame(FlameCartridgeSession<TubeSortGame> session) => TubeSortGame(session);
}

class TubeSortGame extends AsobiFlameGame {
  TubeSortGame(super.session, {int? seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      puzzle = SortWorld(
        level: math.max(1, session.context.save.intData('level', 1)),
        seed: seed ?? DateTime.now().millisecondsSinceEpoch,
      );

  final int level;
  final SortWorld puzzle;
  final Sparks sparks = Sparks();
  int? selected;
  double _shake = 0;
  int? _shakeTube;
  double _endTimer = -1;
  bool _reported = false;

  static const List<Color> ballColors = [
    Color(0xFFFF5A5F),
    Color(0xFF3DDC97),
    Color(0xFF4EA8FF),
    Color(0xFFFFC145),
    Color(0xFFB57BFF),
    Color(0xFFFF8A3D),
    Color(0xFF7BDFF2),
    Color(0xFFF15BB5),
    Color(0xFF9BE564),
    Color(0xFFE9ECF8),
  ];

  @override
  int get entityCount => puzzle.entityCount + sparks.count;

  // ------------------------------------------------------------ layout
  int get _perRow => puzzle.t.length <= 6 ? puzzle.t.length : (puzzle.t.length / 2).ceil();

  Rect tubeRect(int i) {
    final n = puzzle.t.length;
    final rowsCount = n <= 6 ? 1 : 2;
    final row = i ~/ _perRow, col = i % _perRow;
    final inRow = row == rowsCount - 1 ? n - _perRow * (rowsCount - 1) : _perRow;
    final top = hudTop + 50;
    final bottom = size.y - safePadding.bottom - 110;
    final rowH = (bottom - top) / rowsCount;
    final tubeW = math.min(58.0, (size.x - 24) / _perRow - 14);
    final tubeH = math.min(rowH - 40, tubeW * 3.9);
    final gap = (size.x - inRow * tubeW) / (inRow + 1);
    final x = gap + col * (tubeW + gap);
    final y = top + row * rowH + (rowH - tubeH) / 2 + 10;
    return Rect.fromLTWH(x, y, tubeW, tubeH);
  }

  Rect get undoButton => Rect.fromLTWH(size.x / 2 - 150, size.y - safePadding.bottom - 80, 140, 52);
  Rect get tubeButton => Rect.fromLTWH(size.x / 2 + 10, size.y - safePadding.bottom - 80, 140, 52);

  // ------------------------------------------------------------ input
  @override
  void onPointerDown(Vector2 position) {
    if (puzzle.isOver) return;
    final p = Offset(position.x, position.y);
    if (undoButton.contains(p)) {
      if (puzzle.undo()) {
        audio.play(Sfx.whoosh);
        selected = null;
      }
      return;
    }
    if (tubeButton.contains(p)) {
      if (puzzle.addTube()) {
        audio.play(Sfx.powerup);
        selected = null;
      }
      return;
    }
    for (var i = 0; i < puzzle.t.length; i++) {
      if (!tubeRect(i).inflate(8).contains(p)) continue;
      _tapTube(i);
      return;
    }
    selected = null;
  }

  void _tapTube(int i) {
    final sel = selected;
    if (sel == null) {
      if (puzzle.t[i].isEmpty) return;
      selected = i;
      audio.play(Sfx.tap);
      return;
    }
    if (sel == i) {
      selected = null;
      return;
    }
    final completedBefore = puzzle.completedTubes;
    if (puzzle.pour(sel, i) == PourOutcome.poured) {
      audio.play(Sfx.pop);
      if (puzzle.completedTubes > completedBefore) {
        final r = tubeRect(i);
        sparks.burst(r.center.dx, r.top, ctx.settings.reducedEffects ? 8 : 24, ballColors[puzzle.t[i].last]);
        audio.play(Sfx.coin);
        audio.haptic(HapticKind.medium);
      }
      selected = null;
    } else {
      // Invalid pour: wiggle the target, or switch selection to it.
      if (puzzle.t[i].isNotEmpty && puzzle.pourCount(i) > 0) {
        selected = i;
      } else {
        _shake = 0.3;
        _shakeTube = i;
        audio.play(Sfx.thud);
        selected = null;
      }
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    puzzle.update(dt);
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (puzzle.isOver && !_reported) {
      if (_endTimer < 0) _endTimer = 0.9;
      _endTimer -= dt;
      if (_endTimer <= 0) {
        _reported = true;
        final won = puzzle.phase == SortPhase.won;
        if (won) {
          ctx.save.data['level'] = level + 1;
          ctx.commitSave();
        }
        finish(
          RunResult(
            score: puzzle.score,
            won: won,
            headline: won ? 'Sorted in ${puzzle.moves} moves! Level ${level + 1} unlocked.' : 'Out of moves.',
            details: {
              'Level': '$level',
              'Moves': '${puzzle.moves}',
              'Time': '${puzzle.time.toStringAsFixed(0)}s',
            },
          ),
        );
      }
    }
  }

  // ------------------------------------------------------------ render
  final Paint _paint = Paint();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    for (var i = 0; i < puzzle.t.length; i++) {
      _drawTube(canvas, i);
    }
    sparks.render(canvas);
    _drawHud(canvas);
  }

  void _drawTube(Canvas canvas, int i) {
    var r = tubeRect(i);
    if (_shake > 0 && _shakeTube == i) r = r.shift(Offset(math.sin(_shake * 60) * 5, 0));
    final tube = puzzle.t[i];
    final complete = tube.length == puzzle.capacity && tube.toSet().length == 1;
    final glass = RRect.fromRectAndCorners(
      r,
      bottomLeft: Radius.circular(r.width / 2),
      bottomRight: Radius.circular(r.width / 2),
      topLeft: const Radius.circular(6),
      topRight: const Radius.circular(6),
    );
    canvas.drawRRect(glass, _paint..color = const Color(0x22FFFFFF));
    canvas.drawRRect(
      glass,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = complete
            ? ballColors[tube.first].withValues(alpha: 0.9)
            : (selected == i ? Colors.white : const Color(0x88FFFFFF)),
    );
    final ballR = r.width * 0.38;
    final slot = (r.height - 10) / puzzle.capacity;
    for (var k = 0; k < tube.length; k++) {
      var cy = r.bottom - 5 - slot * (k + 0.5);
      // Lift the selected run above the tube.
      if (selected == i && k >= tube.length - _runLength(tube)) cy -= slot * 1.2 + 6;
      final c = Offset(r.center.dx, cy);
      final color = ballColors[tube[k] % ballColors.length];
      canvas.drawCircle(c, ballR, _paint..color = color);
      canvas.drawCircle(
        c + Offset(-ballR * 0.3, -ballR * 0.35),
        ballR * 0.3,
        _paint..color = const Color(0x55FFFFFF),
      );
      _drawGlyph(canvas, c, ballR * 0.42, tube[k]);
    }
  }

  static int _runLength(List<int> tube) {
    var n = 0;
    for (var i = tube.length - 1; i >= 0 && tube[i] == tube.last; i--) {
      n++;
    }
    return n;
  }

  /// Small shape marks so colours are distinguishable without colour vision.
  void _drawGlyph(Canvas canvas, Offset c, double s, int color) {
    final p = Paint()..color = const Color(0x66000000);
    switch (color % 5) {
      case 0:
        canvas.drawCircle(c, s * 0.45, p);
      case 1:
        canvas.drawRect(Rect.fromCenter(center: c, width: s * 0.9, height: s * 0.9), p);
      case 2:
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - s * 0.6)
            ..lineTo(c.dx + s * 0.55, c.dy + s * 0.45)
            ..lineTo(c.dx - s * 0.55, c.dy + s * 0.45)
            ..close(),
          p,
        );
      case 3:
        canvas.drawRect(Rect.fromCenter(center: c, width: s * 1.1, height: s * 0.35), p);
      default:
        canvas.drawRect(Rect.fromCenter(center: c, width: s * 0.35, height: s * 1.1), p);
    }
    if (color >= 5) canvas.drawCircle(c, s * 0.18, Paint()..color = const Color(0x99FFFFFF));
  }

  void _drawHud(Canvas canvas) {
    final top = safePadding.top + 14;
    CanvasText.draw(canvas, 'LEVEL $level', Offset(size.x / 2, top), size: 18, align: Alignment.topCenter);
    CanvasText.draw(
      canvas,
      '${puzzle.moves} moves',
      Offset(size.x - 16, top + 2),
      size: 16,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
    );
    final done = puzzle.completedTubes, total = puzzle.colorCount;
    drawBar(canvas, Rect.fromLTWH(16, hudTop, size.x - 32, 10), done / total, const Color(0xFF7BDFF2));
    CanvasText.draw(
      canvas,
      '$done / $total sorted',
      Offset(size.x / 2, hudTop + 14),
      size: 11,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
    _button(
      canvas,
      undoButton,
      'UNDO ${puzzle.undosLeft}',
      puzzle.undosLeft > 0 && puzzle.history.isNotEmpty,
    );
    _button(canvas, tubeButton, '+TUBE ${puzzle.extraTubesLeft}', puzzle.extraTubesLeft > 0);
    if (puzzle.stuck) {
      CanvasText.draw(
        canvas,
        'No moves left: undo or add a tube',
        Offset(size.x / 2, undoButton.top - 18),
        size: 14,
        align: Alignment.center,
        color: const Color(0xFFFF8A8A),
      );
    } else if (puzzle.moves == 0) {
      CanvasText.draw(
        canvas,
        'Tap a tube, then tap where to pour',
        Offset(size.x / 2, undoButton.top - 18),
        size: 14,
        align: Alignment.center,
        color: Colors.white70,
      );
    }
    if (puzzle.phase == SortPhase.won) {
      CanvasText.draw(
        canvas,
        'SORTED!',
        Offset(size.x / 2, size.y * 0.45),
        size: 40,
        align: Alignment.center,
        color: const Color(0xFFFFD166),
        weight: FontWeight.w900,
      );
    }
  }

  void _button(Canvas canvas, Rect r, String label, bool enabled) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(26)),
      _paint..color = enabled ? const Color(0xFF2B6F80) : const Color(0x332B6F80),
    );
    CanvasText.draw(
      canvas,
      label,
      r.center,
      size: 15,
      align: Alignment.center,
      color: enabled ? Colors.white : Colors.white38,
      weight: FontWeight.w800,
    );
  }
}

extension on SortWorld {
  /// Whether the tube at [i] has any legal pour target (used to switch selection).
  int pourCount(int i) {
    for (var j = 0; j < t.length; j++) {
      if (SortWorld.pourCount(t, i, j, capacity) > 0) return 1;
    }
    return 0;
  }
}
