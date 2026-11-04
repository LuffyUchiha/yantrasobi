import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/events.dart';
import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'puck_world.dart';

class PuckDuelCartridge extends FlameCartridge<PuckDuelGame> {
  const PuckDuelCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'puck-duel',
    title: 'Puck Duel',
    tagline: 'Neon table. One puck. First to seven.',
    description:
        'A fast table-puck duel on a glowing portrait table. Slide your mallet around your '
        'half, smack the puck off the rails and slot it into the opposite goal. Play the '
        'CPU on three difficulties, or share one device with a friend sitting opposite.',
    genre: 'Table sports duel',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFC6FF3D),
    icon: Icons.sports_hockey_rounded,
    tags: ['sports', 'versus', 'physics', 'arcade', 'multiplayer-ready', 'local-multiplayer'],
    controls: [
      'Drag anywhere to steer your mallet; it chases your finger within your half',
      'Shoot within 7 seconds or the puck goes to your opponent',
      'Two players: each person drags on their own half of the screen',
    ],
    mechanics: ['puck physics', 'rail bounces', 'mallet strikes', 'CPU difficulty', 'same-device duel'],
    goal: 'Score 7 goals before your opponent does.',
    maxPlayers: 2,
    localMultiplayer: true,
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  PuckDuelGame createGame(FlameCartridgeSession<PuckDuelGame> session) => PuckDuelGame(session);
}

const Color kP1Color = Color(0xFF2EF2FF);
const Color kP2Color = Color(0xFFFF3DCB);
const Color kPuckColor = Color(0xFFC6FF3D);

/// A menu button on the start overlay.
class _MenuOption {
  const _MenuOption(this.label, this.twoPlayer, this.level);
  final String label;
  final bool twoPlayer;
  final CpuLevel level;
}

const List<_MenuOption> _menu = [
  _MenuOption('VS CPU · EASY', false, CpuLevel.easy),
  _MenuOption('VS CPU · NORMAL', false, CpuLevel.normal),
  _MenuOption('VS CPU · HARD', false, CpuLevel.hard),
  _MenuOption('2 PLAYERS · SAME DEVICE', true, CpuLevel.normal),
];

class PuckDuelGame extends AsobiFlameGame with MultiTouchDragDetector {
  PuckDuelGame(super.session, {this.seed})
    : duel = PuckWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x3fffffff);

  final int? seed;
  final PuckWorld duel;
  final Sparks sparks = Sparks(capacity: 260);

  bool started = false;
  bool twoPlayer = false;
  CpuLevel level = CpuLevel.normal;
  AiController? ai;
  List<AiController> _ais = const [];

  /// Which player each active multi-touch pointer steers (2-player mode).
  final Map<int, int> _pointerOwner = {};

  bool _reported = false;
  double _endDelay = 1.4;
  double _clock = 0;
  double _hintTime = 3.5;

  int _seenHits = 0, _seenWalls = 0, _seenGoals = 0, _seenTurnovers = 0;
  double _goalFlash = 0;
  int _flashScorer = 0;

  static const int _trailLen = 14;
  final Float64List _trail = Float64List(_trailLen * 2);
  int _trailHead = 0, _trailCount = 0;

  @override
  int get entityCount => duel.entityCount + sparks.count + _trailCount;

  @override
  Color backgroundColor() => const Color(0xFF060914);

  // ---------------------------------------------------------------- setup
  /// Starts the match from the overlay (also used directly by tests).
  void startMatch({required bool twoPlayer, CpuLevel level = CpuLevel.normal}) {
    if (started) return;
    started = true;
    this.twoPlayer = twoPlayer;
    this.level = level;
    if (!twoPlayer) {
      ai = AiController(player: 1, level: level, seed: duel.tick + (seed ?? 0));
      _ais = [ai!];
    }
    audio.play(Sfx.powerup);
  }

  // ---------------------------------------------------------------- layout
  Rect get _tableRect {
    final top = hudTop + 30;
    final bottom = size.y - safePadding.bottom - 14;
    final availH = math.max(1.0, bottom - top);
    final availW = math.max(1.0, size.x - 24);
    final s = math.min(availW / PuckWorld.width, availH / PuckWorld.height);
    final w = PuckWorld.width * s, h = PuckWorld.height * s;
    return Rect.fromLTWH((size.x - w) / 2, top + (availH - h) / 2, w, h);
  }

  double get _scale => _tableRect.width / PuckWorld.width;

  Offset _toScreen(double x, double y) {
    final r = _tableRect;
    final s = _scale;
    return Offset(r.left + x * s, r.top + y * s);
  }

  /// Converts a widget-local point into table units.
  PuckInput toTable(Vector2 p) {
    final r = _tableRect;
    final s = _scale;
    return PuckInput((p.x - r.left) / s, (p.y - r.top) / s);
  }

  double get midlineY => _tableRect.center.dy;

  Rect _menuButton(int i) {
    final w = math.min(320.0, size.x - 48);
    const h = 50.0;
    final top = size.y * 0.42 + i * (h + 14);
    return Rect.fromLTWH((size.x - w) / 2, top, w, h);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (size.x <= 0) return;
    if (!started) {
      for (var i = 0; i < _menu.length; i++) {
        if (_menuButton(i).contains(Offset(position.x, position.y))) {
          startMatch(twoPlayer: _menu[i].twoPlayer, level: _menu[i].level);
          return;
        }
      }
      return;
    }
    if (twoPlayer || duel.isOver) return;
    duel.setInput(0, toTable(position));
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (!started || twoPlayer || duel.isOver) return;
    duel.setInput(0, toTable(position));
  }

  /// Same-device mode: every finger steers the mallet of the half it landed on.
  void touchStart(int pointer, Vector2 position) {
    if (!started || !twoPlayer || duel.isOver || size.x <= 0) return;
    final owner = position.y >= midlineY ? 0 : 1;
    _pointerOwner[pointer] = owner;
    duel.setInput(owner, toTable(position));
  }

  void touchMove(int pointer, Vector2 position) {
    final owner = _pointerOwner[pointer];
    if (owner == null || duel.isOver) return;
    duel.setInput(owner, toTable(position));
  }

  void touchEnd(int pointer) => _pointerOwner.remove(pointer);

  @override
  void onDragStart(int pointerId, DragStartInfo info) => touchStart(pointerId, info.eventPosition.widget);

  @override
  void onDragUpdate(int pointerId, DragUpdateInfo info) => touchMove(pointerId, info.eventPosition.widget);

  @override
  void onDragEnd(int pointerId, DragEndInfo info) => touchEnd(pointerId);

  @override
  void onDragCancel(int pointerId) => touchEnd(pointerId);

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    sparks.update(dt);
    if (_goalFlash > 0) _goalFlash = math.max(0, _goalFlash - dt);
    if (!started) return;
    if (_hintTime > 0) _hintTime -= dt;
    duel.update(dt, _ais);
    _pollEvents();
    if (duel.serveTimer > 0) {
      _trailCount = 0;
    } else {
      _trail[_trailHead * 2] = duel.puckX;
      _trail[_trailHead * 2 + 1] = duel.puckY;
      _trailHead = (_trailHead + 1) % _trailLen;
      if (_trailCount < _trailLen) _trailCount++;
    }
    if (duel.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _pollEvents() {
    final reduced = ctx.settings.reducedEffects;
    if (size.x <= 0) {
      _seenHits = duel.malletHits;
      _seenWalls = duel.wallHits;
      _seenGoals = duel.goals;
      _seenTurnovers = duel.turnovers;
      return;
    }
    if (duel.turnovers != _seenTurnovers) {
      _seenTurnovers = duel.turnovers;
      _trailCount = 0;
      audio.play(Sfx.whoosh);
    }
    final at = _toScreen(duel.puckX, duel.puckY);
    if (duel.malletHits != _seenHits) {
      _seenHits = duel.malletHits;
      audio.play(Sfx.pop);
      audio.haptic(HapticKind.light);
      sparks.burst(at.dx, at.dy, reduced ? 3 : 10, kPuckColor, speed: 160, life: 0.35);
    }
    if (duel.wallHits != _seenWalls) {
      _seenWalls = duel.wallHits;
      audio.play(Sfx.tap);
      if (!reduced) sparks.burst(at.dx, at.dy, 4, const Color(0xFF9FA8FF), speed: 90, life: 0.25);
    }
    if (duel.goals != _seenGoals) {
      _seenGoals = duel.goals;
      _flashScorer = duel.lastScorer;
      _goalFlash = 0.9;
      _trailCount = 0;
      final mouth = _toScreen(PuckWorld.width / 2, _flashScorer == 0 ? 0 : PuckWorld.height);
      final color = _flashScorer == 0 ? kP1Color : kP2Color;
      sparks.burst(mouth.dx, mouth.dy, reduced ? 10 : 40, color, speed: 260, life: 0.7);
      if (duel.isOver) {
        audio.play(twoPlayer || duel.won ? Sfx.win : Sfx.lose);
        audio.haptic(HapticKind.heavy);
      } else {
        audio.play(_flashScorer == 0 || twoPlayer ? Sfx.coin : Sfx.thud);
        audio.haptic(HapticKind.medium);
      }
    }
  }

  void _report() {
    _reported = true;
    final a = duel.scores[0], b = duel.scores[1];
    final secs = (duel.tick * PuckWorld.stepDt).round();
    final levelName = level.name.toUpperCase();
    if (twoPlayer) {
      final w = (duel.winner ?? 0) + 1;
      finish(
        RunResult(
          score: math.max(a, b) * 100,
          won: null,
          headline: 'Player $w wins ${math.max(a, b)}-${math.min(a, b)}!',
          details: {'Mode': '2 players', 'Player 1': '$a', 'Player 2': '$b', 'Time': '${secs}s'},
        ),
      );
      return;
    }
    final won = duel.won;
    finish(
      RunResult(
        score: a * 100 + (won ? 300 + (PuckWorld.defaultWinScore - b) * 50 : 0),
        won: won,
        headline: won ? 'You beat the $levelName CPU $a-$b!' : 'The $levelName CPU wins $b-$a.',
        details: {
          'Mode': 'vs CPU ($levelName)',
          'Score': '$a - $b',
          'Strikes': '${duel.malletHits}',
          'Time': '${secs}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _glow = Paint()
    ..style = PaintingStyle.stroke
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
  final Paint _glowFill = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    _drawTable(canvas);
    if (started) {
      _drawScores(canvas);
      _drawTrail(canvas);
      _drawPuck(canvas);
    }
    _drawMallet(canvas, 0, kP1Color);
    _drawMallet(canvas, 1, kP2Color);
    sparks.render(canvas);
    _drawHud(canvas);
    if (!started) _drawMenu(canvas);
  }

  void _drawTable(Canvas canvas) {
    final r = _tableRect;
    final s = _scale;
    final rr = RRect.fromRectAndRadius(r, Radius.circular(s * 0.9));
    _fill.color = const Color(0xFF0B1230);
    canvas.drawRRect(rr, _fill);
    // Faint air-hole grid.
    _fill.color = const Color(0x1F8FA6FF);
    for (var gy = 1; gy < PuckWorld.height; gy++) {
      for (var gx = 1; gx < PuckWorld.width; gx++) {
        canvas.drawCircle(_toScreen(gx.toDouble(), gy.toDouble()), 1.2, _fill);
      }
    }
    // Goal flash tint over the half that conceded.
    if (_goalFlash > 0) {
      final c = _flashScorer == 0 ? kP1Color : kP2Color;
      _fill.color = c.withValues(alpha: 0.18 * (_goalFlash / 0.9));
      final half = _flashScorer == 0
          ? Rect.fromLTRB(r.left, r.top, r.right, r.center.dy)
          : Rect.fromLTRB(r.left, r.center.dy, r.right, r.bottom);
      canvas.drawRect(half, _fill);
    }
    // Centre line, circle and goal creases.
    _stroke
      ..strokeWidth = 2
      ..color = const Color(0x667C8CFF);
    canvas.drawLine(Offset(r.left, r.center.dy), Offset(r.right, r.center.dy), _stroke);
    canvas.drawCircle(r.center, s * 1.6, _stroke);
    canvas.drawArc(
      Rect.fromCircle(center: _toScreen(PuckWorld.width / 2, 0), radius: s * 2.6),
      0,
      math.pi,
      false,
      _stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: _toScreen(PuckWorld.width / 2, PuckWorld.height), radius: s * 2.6),
      math.pi,
      math.pi,
      false,
      _stroke,
    );
    // Neon rail.
    _glow
      ..strokeWidth = 6
      ..color = const Color(0x997C8CFF);
    canvas.drawRRect(rr, _glow);
    _stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFFB8C2FF);
    canvas.drawRRect(rr, _stroke);
    // Goal mouths (each player's own colour marks the goal they defend).
    _drawGoal(canvas, 0, kP2Color, _flashScorer == 0 ? _goalFlash : 0);
    _drawGoal(canvas, PuckWorld.height, kP1Color, _flashScorer == 1 ? _goalFlash : 0);
  }

  void _drawGoal(Canvas canvas, double y, Color color, double flash) {
    final a = _toScreen(PuckWorld.goalLeft, y);
    final b = _toScreen(PuckWorld.goalRight, y);
    _fill.color = const Color(0xFF060914);
    canvas.drawRect(Rect.fromLTRB(a.dx, a.dy - 5, b.dx, a.dy + 5), _fill);
    _glow
      ..strokeWidth = 8 + 14 * flash
      ..color = color.withValues(alpha: 0.55 + 0.45 * (flash / 0.9).clamp(0.0, 1.0));
    canvas.drawLine(a, b, _glow);
    _stroke
      ..strokeWidth = 3
      ..color = color;
    canvas.drawLine(a, b, _stroke);
  }

  void _drawTrail(Canvas canvas) {
    if (ctx.settings.reducedEffects || _trailCount < 2) return;
    final s = _scale;
    for (var i = 0; i < _trailCount; i++) {
      final idx = (_trailHead - _trailCount + i + _trailLen) % _trailLen;
      final t = (i + 1) / _trailCount;
      _fill.color = kPuckColor.withValues(alpha: 0.28 * t);
      canvas.drawCircle(
        _toScreen(_trail[idx * 2], _trail[idx * 2 + 1]),
        PuckWorld.puckRadius * s * (0.4 + 0.5 * t),
        _fill,
      );
    }
  }

  void _drawPuck(Canvas canvas) {
    final s = _scale;
    final c = _toScreen(duel.puckX, duel.puckY);
    final r = PuckWorld.puckRadius * s;
    _glowFill.color = kPuckColor.withValues(alpha: 0.45);
    canvas.drawCircle(c, r * 1.4, _glowFill);
    _fill.color = const Color(0xFF1A2205);
    canvas.drawCircle(c, r, _fill);
    _stroke
      ..strokeWidth = math.max(2, r * 0.22)
      ..color = kPuckColor;
    canvas.drawCircle(c, r * 0.85, _stroke);
    if (duel.serveTimer > 0) {
      final t = duel.serveTimer / PuckWorld.serveTicks;
      _stroke
        ..strokeWidth = 2
        ..color = kPuckColor.withValues(alpha: 0.7);
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 1.9),
        -math.pi / 2,
        math.pi * 2 * t,
        false,
        _stroke,
      );
    }
  }

  void _drawMallet(Canvas canvas, int p, Color color) {
    final m = duel.mallets[p];
    final s = _scale;
    final c = _toScreen(m.x, m.y);
    final r = PuckWorld.malletRadius * s;
    _glowFill.color = color.withValues(alpha: 0.35);
    canvas.drawCircle(c, r * 1.25, _glowFill);
    _fill.color = const Color(0xFF0A0E22);
    canvas.drawCircle(c, r, _fill);
    _stroke
      ..strokeWidth = math.max(2.5, r * 0.16)
      ..color = color;
    canvas.drawCircle(c, r * 0.9, _stroke);
    _fill.color = color.withValues(alpha: 0.85);
    canvas.drawCircle(c, r * 0.36, _fill);
    _fill.color = const Color(0xCCFFFFFF);
    canvas.drawCircle(c + Offset(-r * 0.1, -r * 0.1), r * 0.12, _fill);
  }

  /// Draws [text] centred on [at], upside down when [flip] (for the far player).
  void _text(Canvas canvas, String text, Offset at, double size, Color color, {bool flip = false}) {
    if (!flip) {
      CanvasText.draw(
        canvas,
        text,
        at,
        size: size,
        color: color,
        align: Alignment.center,
        weight: FontWeight.w900,
      );
      return;
    }
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(math.pi);
    CanvasText.draw(
      canvas,
      text,
      Offset.zero,
      size: size,
      color: color,
      align: Alignment.center,
      weight: FontWeight.w900,
    );
    canvas.restore();
  }

  void _drawScores(Canvas canvas) {
    final s = _scale;
    final a = duel.scores[0], b = duel.scores[1];
    final big = s * 2.0;
    // Each half shows the score from its owner's point of view.
    _text(canvas, '$a', _toScreen(1.6, PuckWorld.height / 2 + 1.5), big, kP1Color.withValues(alpha: 0.35));
    _text(
      canvas,
      '$b',
      _toScreen(1.6, PuckWorld.height / 2 + 3.2),
      big * 0.55,
      kP2Color.withValues(alpha: 0.3),
    );
    _text(
      canvas,
      '$b',
      _toScreen(PuckWorld.width - 1.6, PuckWorld.height / 2 - 1.5),
      big,
      kP2Color.withValues(alpha: 0.35),
      flip: twoPlayer,
    );
    _text(
      canvas,
      '$a',
      _toScreen(PuckWorld.width - 1.6, PuckWorld.height / 2 - 3.2),
      big * 0.55,
      kP1Color.withValues(alpha: 0.3),
      flip: twoPlayer,
    );
    final left = duel.shotClockLeft;
    if (!duel.isOver && duel.serveTimer == 0 && left < 3) {
      // Shot clock: the puck is about to be handed over.
      final side = duel.lingerSide;
      final at = _toScreen(
        PuckWorld.width / 2,
        side == 0 ? PuckWorld.height * 0.62 : PuckWorld.height * 0.38,
      );
      final pulse = 0.6 + 0.4 * math.sin(_clock * 12);
      _text(
        canvas,
        'SHOOT! ${left.ceil()}',
        at,
        s * 0.8,
        kPuckColor.withValues(alpha: pulse),
        flip: side == 1 && twoPlayer,
      );
    }
    if (_goalFlash > 0) {
      final alpha = (_goalFlash / 0.5).clamp(0.0, 1.0);
      final c = (_flashScorer == 0 ? kP1Color : kP2Color).withValues(alpha: alpha);
      final label = duel.isOver ? 'MATCH' : 'GOAL';
      _text(canvas, label, _toScreen(PuckWorld.width / 2, PuckWorld.height * 0.62), s * 1.3, c);
      if (twoPlayer) {
        _text(canvas, label, _toScreen(PuckWorld.width / 2, PuckWorld.height * 0.38), s * 1.3, c, flip: true);
      }
    }
    if (duel.isOver) {
      final w = duel.winner ?? 0;
      final String bottom, top;
      if (twoPlayer) {
        bottom = w == 0 ? 'YOU WIN' : 'PLAYER 2 WINS';
        top = w == 1 ? 'YOU WIN' : 'PLAYER 1 WINS';
      } else {
        bottom = w == 0 ? 'YOU WIN' : 'CPU WINS';
        top = '';
      }
      _text(canvas, bottom, _toScreen(PuckWorld.width / 2, PuckWorld.height * 0.7), s * 1.0, kPuckColor);
      if (top.isNotEmpty) {
        _text(
          canvas,
          top,
          _toScreen(PuckWorld.width / 2, PuckWorld.height * 0.3),
          s * 1.0,
          kPuckColor,
          flip: true,
        );
      }
    }
  }

  void _drawHud(Canvas canvas) {
    final r = _tableRect;
    final y = r.top - 15;
    if (!started) return;
    if (twoPlayer) {
      _text(
        canvas,
        'PLAYER 2 · FIRST TO ${duel.winScore}',
        Offset(size.x / 2 + 20, y),
        13,
        kP2Color,
        flip: true,
      );
    } else {
      CanvasText.draw(
        canvas,
        'CPU · ${level.name.toUpperCase()}',
        Offset(size.x - 16, y),
        size: 13,
        color: kP2Color,
        align: Alignment.centerRight,
        weight: FontWeight.w900,
      );
      CanvasText.draw(
        canvas,
        'FIRST TO ${duel.winScore}',
        Offset(r.left + 4, y),
        size: 13,
        color: const Color(0xFFB8C2FF),
        align: Alignment.centerLeft,
        weight: FontWeight.w800,
      );
    }
    if (_hintTime > 0) {
      final a = (_hintTime / 1.0).clamp(0.0, 1.0);
      final c = const Color(0xFFFFFFFF).withValues(alpha: 0.8 * a);
      _text(
        canvas,
        'DRAG TO MOVE YOUR MALLET',
        _toScreen(PuckWorld.width / 2, PuckWorld.height * 0.66),
        14,
        c,
      );
      if (twoPlayer) {
        _text(
          canvas,
          'DRAG TO MOVE YOUR MALLET',
          _toScreen(PuckWorld.width / 2, PuckWorld.height * 0.34),
          14,
          c,
          flip: true,
        );
      }
    }
  }

  void _drawMenu(Canvas canvas) {
    _fill.color = const Color(0xC4060914);
    canvas.drawRect(Offset.zero & Size(size.x, size.y), _fill);
    final pulse = 0.5 + 0.5 * math.sin(_clock * 3);
    _text(canvas, 'PUCK DUEL', Offset(size.x / 2, size.y * 0.24), 40, kPuckColor);
    _text(
      canvas,
      'FIRST TO ${duel.winScore} GOALS',
      Offset(size.x / 2, size.y * 0.24 + 40),
      15,
      const Color(0xFFB8C2FF),
    );
    for (var i = 0; i < _menu.length; i++) {
      final b = _menuButton(i);
      final o = _menu[i];
      final color = o.twoPlayer ? kP2Color : kP1Color;
      final rr = RRect.fromRectAndRadius(b, const Radius.circular(25));
      _fill.color = color.withValues(alpha: 0.14);
      canvas.drawRRect(rr, _fill);
      _glow
        ..strokeWidth = 5
        ..color = color.withValues(alpha: 0.25 + 0.25 * pulse);
      canvas.drawRRect(rr, _glow);
      _stroke
        ..strokeWidth = 2
        ..color = color;
      canvas.drawRRect(rr, _stroke);
      _text(canvas, o.label, b.center, 15, const Color(0xFFFFFFFF));
    }
    final last = _menuButton(_menu.length - 1);
    _text(
      canvas,
      '2 players: each drags on their own half',
      Offset(size.x / 2, last.bottom + 26),
      12,
      const Color(0xAAB8C2FF),
    );
  }
}
