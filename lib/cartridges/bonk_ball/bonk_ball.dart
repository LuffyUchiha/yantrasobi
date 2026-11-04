import 'dart:math' as math;
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
import 'bonk_world.dart';

class BonkBallCartridge extends FlameCartridge<BonkBallGame> {
  const BonkBallCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'bonk-ball',
    title: 'Bonk Ball',
    tagline: 'Big heads. Tiny boots. Sixty seconds.',
    description:
        'A side-view one-on-one football scramble between two round-headed athletes. Run, '
        'jump, head the ball and swing your boot to smash it past the other keeper. Sixty '
        'seconds or first to five. Play the CPU on three difficulties, or share one device '
        'with a friend sitting opposite.',
    genre: 'Head-to-head football',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF6A8CFF),
    icon: Icons.face_rounded,
    tags: ['sports', 'football', 'versus', 'physics', 'arcade', 'multiplayer-ready', 'local-multiplayer'],
    controls: [
      'Hold the arrow buttons to run left or right',
      'JUMP to leap and head the ball, KICK to swing your boot',
      'Two players: each person uses the buttons in their own corners',
    ],
    mechanics: ['ball physics', 'headers', 'kicks', 'crossbars', 'CPU difficulty', 'same-device duel'],
    goal: 'Score more goals than your opponent in 60 seconds, or be first to 5.',
    maxPlayers: 2,
    localMultiplayer: true,
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  BonkBallGame createGame(FlameCartridgeSession<BonkBallGame> session) => BonkBallGame(session);
}

const Color kBonkP1 = Color(0xFF3EC1FF);
const Color kBonkP2 = Color(0xFFFF5D6C);
const Color kBonkGold = Color(0xFFFFD166);

/// Kinds of on-screen control buttons.
enum BonkButton { left, right, jump, kick }

/// A control button in screen space. [worldDir] is the world x direction the
/// button runs (for arrow buttons), so arrows always point the way you move.
class BonkButtonRect {
  const BonkButtonRect(this.player, this.kind, this.rect, {this.flip = false});
  final int player;
  final BonkButton kind;
  final Rect rect;

  /// Drawn upside down for the player sitting opposite.
  final bool flip;

  double get worldDir => switch (kind) {
    BonkButton.left => -1,
    BonkButton.right => 1,
    _ => 0,
  };
}

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

/// Procedural look of one athlete.
class _Look {
  _Look(math.Random rng, this.kit)
    : skin = _skins[rng.nextInt(_skins.length)],
      hair = _hairs[rng.nextInt(_hairs.length)],
      style = rng.nextInt(3),
      brow = 0.6 + rng.nextDouble() * 0.6;

  static const List<Color> _skins = [
    Color(0xFFF2C9A0),
    Color(0xFFD9A06B),
    Color(0xFFA8714A),
    Color(0xFF7A4E31),
    Color(0xFFFFDDBE),
  ];
  static const List<Color> _hairs = [
    Color(0xFF2B1B12),
    Color(0xFF5A3A1E),
    Color(0xFFE8B83C),
    Color(0xFFB0472C),
    Color(0xFF1E1E2A),
  ];

  final Color kit;
  final Color skin;
  final Color hair;
  final int style;
  final double brow;
}

class BonkBallGame extends AsobiFlameGame with MultiTouchDragDetector {
  BonkBallGame(super.session, {this.seed})
    : _seedBase = seed ?? DateTime.now().microsecondsSinceEpoch & 0x3fffffff {
    bonk = BonkWorld(seed: _seedBase);
    final rng = math.Random(_seedBase * 31 + 7);
    _looks = [_Look(rng, kBonkP1), _Look(rng, kBonkP2)];
    for (var i = 0; i < _crowd.length; i++) {
      _crowd[i] = rng.nextInt(_crowdColors.length) | (rng.nextInt(1000) << 4);
    }
  }

  final int? seed;
  final int _seedBase;
  late BonkWorld bonk;
  late final List<_Look> _looks;
  final Sparks sparks = Sparks(capacity: 260);

  bool started = false;
  bool twoPlayer = false;
  CpuLevel level = CpuLevel.normal;
  List<AiController> _ais = const [];

  /// Which button each active pointer holds (null = none), and its owner.
  final Map<int, BonkButtonRect?> _held = {};
  final Map<int, int> _owner = {};

  bool _reported = false;
  double _endDelay = 1.4;
  double _clock = 0;
  double _hintTime = 4;
  double _ballSpin = 0;

  int _seenHead = 0, _seenKickHits = 0, _seenKicks = 0, _seenBounce = 0, _seenBar = 0, _seenGoals = 0;
  double _goalFlash = 0;
  int _flashScorer = 0;
  bool _flashOwn = false;
  bool _sawEnd = false;

  static const List<Color> _crowdColors = [
    Color(0xFF3EC1FF),
    Color(0xFFFF5D6C),
    Color(0xFFFFD166),
    Color(0xFFEDEDED),
    Color(0xFF8E7DFF),
    Color(0xFF6BE39A),
  ];
  final List<int> _crowd = List<int>.filled(84, 0);

  List<BonkButtonRect> _buttons = const [];
  Size _buttonsFor = Size.zero;
  bool _buttonsTwoPlayer = false;

  @override
  int get entityCount => bonk.entityCount + sparks.count;

  @override
  Color backgroundColor() => const Color(0xFF101528);

  // ---------------------------------------------------------------- setup
  /// Starts the match from the overlay (also used directly by tests).
  void startMatch({required bool twoPlayer, CpuLevel level = CpuLevel.normal}) {
    if (started) return;
    started = true;
    this.twoPlayer = twoPlayer;
    this.level = level;
    bonk = BonkWorld(seed: _seedBase, goldenGoal: twoPlayer);
    _ais = twoPlayer ? const [] : [AiController(player: 1, level: level, seed: _seedBase + 1)];
    _held.clear();
    _owner.clear();
    audio.play(Sfx.powerup);
  }

  // ---------------------------------------------------------------- layout
  double get _bottomInset => safePadding.bottom + 14;
  double get _buttonSize => twoPlayer ? math.min(62.0, (size.x - 60) / 4) : math.min(78.0, (size.x - 66) / 4);

  /// Top and bottom of the band the pitch is centred in.
  (double, double) get _band {
    final b = _buttonSize;
    if (started && twoPlayer) {
      return (hudTop + b + 50, size.y - _bottomInset - b - 50);
    }
    return (hudTop + 70, size.y - _bottomInset - b - 40);
  }

  Rect get pitchRect {
    final (top, bottom) = _band;
    final availH = math.max(1.0, bottom - top);
    final availW = math.max(1.0, size.x - 16);
    final s = math.min(availW / BonkWorld.width, availH / BonkWorld.height);
    final w = BonkWorld.width * s, h = BonkWorld.height * s;
    return Rect.fromLTWH((size.x - w) / 2, top + (availH - h) / 2, w, h);
  }

  double get _scale => pitchRect.width / BonkWorld.width;

  Offset toScreen(double x, double y) {
    final r = pitchRect;
    final s = _scale;
    return Offset(r.left + x * s, r.bottom - y * s);
  }

  /// On-screen control buttons for the current mode and screen size.
  List<BonkButtonRect> get buttons {
    final sz = Size(size.x, size.y);
    if (sz == _buttonsFor && _buttonsTwoPlayer == twoPlayer && _buttons.isNotEmpty) return _buttons;
    _buttonsFor = sz;
    _buttonsTwoPlayer = twoPlayer;
    final b = _buttonSize;
    const gap = 12.0, edge = 14.0;
    final y = size.y - _bottomInset - b;
    final p1 = [
      BonkButtonRect(0, BonkButton.left, Rect.fromLTWH(edge, y, b, b)),
      BonkButtonRect(0, BonkButton.right, Rect.fromLTWH(edge + b + gap, y, b, b)),
      BonkButtonRect(0, BonkButton.jump, Rect.fromLTWH(size.x - edge - 2 * b - gap, y, b, b)),
      BonkButtonRect(0, BonkButton.kick, Rect.fromLTWH(size.x - edge - b, y, b, b)),
    ];
    if (!twoPlayer) return _buttons = p1;
    // Player 2 sits opposite: their cluster is player 1's rotated by 180°, so
    // their own left-hand arrows land at the top right. The arrow that points
    // to *their* left points to screen right, i.e. world +x.
    final top = hudTop;
    Rect mirror(Rect r) => Rect.fromLTWH(size.x - r.right, top, r.width, r.height);
    return _buttons = [
      ...p1,
      BonkButtonRect(1, BonkButton.right, mirror(p1[0].rect), flip: true),
      BonkButtonRect(1, BonkButton.left, mirror(p1[1].rect), flip: true),
      BonkButtonRect(1, BonkButton.jump, mirror(p1[2].rect), flip: true),
      BonkButtonRect(1, BonkButton.kick, mirror(p1[3].rect), flip: true),
    ];
  }

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
    // The adapter's primary pointer; the multi-touch detector below reports
    // the same finger too, which is harmless (both hold the same button).
    touchStart(-1, position);
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) => touchMove(-1, position);

  @override
  void onPointerUp(Vector2 position) => touchEnd(-1);

  @override
  void onDragStart(int pointerId, DragStartInfo info) => touchStart(pointerId, info.eventPosition.widget);

  @override
  void onDragUpdate(int pointerId, DragUpdateInfo info) => touchMove(pointerId, info.eventPosition.widget);

  @override
  void onDragEnd(int pointerId, DragEndInfo info) => touchEnd(pointerId);

  @override
  void onDragCancel(int pointerId) => touchEnd(pointerId);

  /// A finger landed: it belongs to the player whose half it touched.
  void touchStart(int pointer, Vector2 position) {
    if (!started || bonk.isOver || size.x <= 0) return;
    final owner = twoPlayer && position.y < size.y / 2 ? 1 : 0;
    _owner[pointer] = owner;
    _held[pointer] = _buttonAt(owner, position);
    _syncInputs();
  }

  /// Sliding a finger between buttons switches which one it holds.
  void touchMove(int pointer, Vector2 position) {
    final owner = _owner[pointer];
    if (owner == null) return;
    _held[pointer] = _buttonAt(owner, position);
    _syncInputs();
  }

  void touchEnd(int pointer) {
    if (_owner.remove(pointer) == null) return;
    _held.remove(pointer);
    _syncInputs();
  }

  BonkButtonRect? _buttonAt(int owner, Vector2 p) {
    final o = Offset(p.x, p.y);
    BonkButtonRect? best;
    var bestD = double.infinity;
    for (final b in buttons) {
      if (b.player != owner || !b.rect.inflate(10).contains(o)) continue;
      final d = (b.rect.center - o).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = b;
      }
    }
    return best;
  }

  /// Whether [player] currently holds a [kind] button.
  bool isHeld(int player, BonkButton kind) {
    for (final b in _held.values) {
      if (b != null && b.player == player && b.kind == kind) return true;
    }
    return false;
  }

  /// Turns held buttons into each human player's [BonkInput].
  void _syncInputs() {
    if (!started) return;
    final humans = twoPlayer ? 2 : 1;
    for (var p = 0; p < humans; p++) {
      var move = 0.0;
      if (isHeld(p, BonkButton.left)) move -= 1;
      if (isHeld(p, BonkButton.right)) move += 1;
      bonk.setInput(
        p,
        BonkInput(move: move, jump: isHeld(p, BonkButton.jump), kick: isHeld(p, BonkButton.kick)),
      );
    }
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    sparks.update(dt);
    if (_goalFlash > 0) _goalFlash = math.max(0, _goalFlash - dt);
    if (!started) return;
    if (_hintTime > 0) _hintTime -= dt;
    bonk.update(dt, _ais);
    _ballSpin -= bonk.ballVx * dt / BonkWorld.ballRadius;
    _pollEvents();
    if (bonk.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _pollEvents() {
    final reduced = ctx.settings.reducedEffects;
    final at = toScreen(bonk.ballX, bonk.ballY);
    if (bonk.kicks != _seenKicks) {
      _seenKicks = bonk.kicks;
      audio.play(Sfx.whoosh);
    }
    if (bonk.kickHits != _seenKickHits) {
      _seenKickHits = bonk.kickHits;
      audio.play(Sfx.hit);
      audio.haptic(HapticKind.medium);
      if (size.x > 0) sparks.burst(at.dx, at.dy, reduced ? 4 : 14, kBonkGold, speed: 200, life: 0.35);
    }
    if (bonk.headHits != _seenHead) {
      _seenHead = bonk.headHits;
      audio.play(Sfx.pop);
      audio.haptic(HapticKind.light);
      if (size.x > 0 && !reduced) {
        sparks.burst(at.dx, at.dy, 6, const Color(0xFFFFFFFF), speed: 120, life: 0.3);
      }
    }
    if (bonk.bounces != _seenBounce) {
      _seenBounce = bonk.bounces;
      audio.play(Sfx.tap);
    }
    if (bonk.crossbarHits != _seenBar) {
      _seenBar = bonk.crossbarHits;
      audio.play(Sfx.thud);
      audio.haptic(HapticKind.light);
    }
    if (bonk.goals != _seenGoals) {
      _seenGoals = bonk.goals;
      _flashScorer = bonk.lastScorer;
      _flashOwn = bonk.lastWasOwnGoal;
      _goalFlash = 1.4;
      final color = _flashScorer == 0 ? kBonkP1 : kBonkP2;
      if (size.x > 0) sparks.burst(at.dx, at.dy, reduced ? 10 : 46, color, speed: 260, life: 0.7);
      if (bonk.isOver) {
        audio.play(twoPlayer || bonk.won ? Sfx.win : Sfx.lose);
        audio.haptic(HapticKind.heavy);
      } else {
        audio.play(_flashScorer == 0 || twoPlayer ? Sfx.coin : Sfx.thud);
        audio.haptic(HapticKind.medium);
      }
    } else if (bonk.isOver && !_sawEnd) {
      // Full time without a deciding goal.
      audio.play(bonk.isDraw ? Sfx.lose : (twoPlayer || bonk.won ? Sfx.win : Sfx.lose));
    }
    if (bonk.isOver) _sawEnd = true;
  }

  void _report() {
    _reported = true;
    final a = bonk.scores[0], b = bonk.scores[1];
    final secs = (bonk.tick * BonkWorld.stepDt).round();
    final golden = bonk.goldenGoalActive;
    if (twoPlayer) {
      final w = (bonk.winner ?? 0) + 1;
      finish(
        RunResult(
          score: math.max(a, b) * 100,
          won: null,
          headline: golden
              ? 'Player $w wins on a golden goal, ${math.max(a, b)}-${math.min(a, b)}!'
              : 'Player $w wins ${math.max(a, b)}-${math.min(a, b)}!',
          details: {'Mode': '2 players', 'Player 1': '$a', 'Player 2': '$b', 'Time': '${secs}s'},
        ),
      );
      return;
    }
    final levelName = level.name.toUpperCase();
    final won = bonk.won;
    final String headline;
    if (bonk.isDraw) {
      headline = 'Full time: a $a-$b draw with the $levelName CPU.';
    } else if (won) {
      headline = 'You beat the $levelName CPU $a-$b!';
    } else {
      headline = 'The $levelName CPU wins $b-$a.';
    }
    finish(
      RunResult(
        score: a * 100 + (won ? 300 + (level.index * 200) + (bonk.secondsLeft.round() * 5) : 0),
        won: won,
        headline: headline,
        details: {
          'Mode': 'vs CPU ($levelName)',
          'Score': '$a - $b',
          'Kicks landed': '${bonk.kickHits}',
          'Time': '${secs}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Path _path = Path();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    _drawStadium(canvas);
    _drawGoalNet(canvas, 0);
    _drawGoalNet(canvas, 1);
    for (var p = 0; p < 2; p++) {
      _drawPlayer(canvas, p);
    }
    if (started) _drawBall(canvas);
    _drawGoalFrame(canvas, 0);
    _drawGoalFrame(canvas, 1);
    sparks.render(canvas);
    if (started) {
      _drawButtons(canvas);
      _drawHud(canvas);
    } else {
      _drawMenu(canvas);
    }
  }

  void _drawStadium(Canvas canvas) {
    final r = pitchRect;
    final s = _scale;
    // Sky.
    _fill.shader = Gradient.linear(r.topLeft, r.bottomLeft, const [Color(0xFF1C2A5C), Color(0xFF3B5BA8)]);
    canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(s * 0.4)), _fill);
    _fill.shader = null;
    // Stands with a dotted crowd.
    final standTop = r.top + r.height * 0.12;
    final standBottom = r.bottom - BonkWorld.goalHeight * s * 0.55;
    _fill.color = const Color(0xFF26305A);
    canvas.drawRect(Rect.fromLTRB(r.left, standTop, r.right, standBottom), _fill);
    const rows = 4, cols = 21;
    final dx = r.width / cols, dy = (standBottom - standTop) / rows;
    final bob = ctx.settings.reducedEffects ? 0.0 : 1.0;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final v = _crowd[(row * cols + col) % _crowd.length];
        _fill.color = _crowdColors[v & 15].withValues(alpha: 0.75);
        final jig = bob * math.sin(_clock * 6 + (v >> 4)) * (_goalFlash > 0 ? 3 : 0.8);
        canvas.drawCircle(
          Offset(r.left + (col + 0.5 + (row.isOdd ? 0.25 : -0.25)) * dx, standTop + (row + 0.6) * dy + jig),
          math.max(1.5, dx * 0.26),
          _fill,
        );
      }
    }
    // Advertising board.
    _fill.color = const Color(0xFF151B33);
    canvas.drawRect(Rect.fromLTRB(r.left, standBottom, r.right, standBottom + s * 0.35), _fill);
    // Grass with mowing stripes.
    final ground = toScreen(0, 0).dy;
    final grassTop = ground - s * 0.6;
    for (var i = 0; i < 8; i++) {
      _fill.color = i.isEven ? const Color(0xFF3FA54A) : const Color(0xFF379641);
      canvas.drawRect(
        Rect.fromLTRB(r.left + i * r.width / 8, grassTop, r.left + (i + 1) * r.width / 8, r.bottom),
        _fill,
      );
    }
    _stroke
      ..strokeWidth = 2
      ..color = const Color(0x88FFFFFF);
    canvas.drawLine(Offset(r.center.dx, grassTop), Offset(r.center.dx, r.bottom), _stroke);
    // Goal flash tint.
    if (_goalFlash > 0) {
      final c = _flashScorer == 0 ? kBonkP1 : kBonkP2;
      _fill.color = c.withValues(alpha: 0.16 * (_goalFlash / 1.4));
      canvas.drawRect(r, _fill);
    }
  }

  void _drawGoalNet(Canvas canvas, int side) {
    final s = _scale;
    final (ax, ay, bx, by) = BonkWorld.crossbar(side);
    final back = toScreen(ax, ay), mouth = toScreen(bx, by);
    final ground = toScreen(0, 0).dy;
    final rect = Rect.fromLTRB(math.min(back.dx, mouth.dx), mouth.dy, math.max(back.dx, mouth.dx), ground);
    _fill.color = const Color(0x55101528);
    canvas.drawRect(rect, _fill);
    _stroke
      ..strokeWidth = 1
      ..color = const Color(0x66FFFFFF);
    final step = math.max(4.0, s * 0.35);
    for (var x = rect.left; x <= rect.right; x += step) {
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), _stroke);
    }
    for (var y = rect.top; y <= rect.bottom; y += step) {
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), _stroke);
    }
  }

  void _drawGoalFrame(Canvas canvas, int side) {
    final s = _scale;
    final (ax, ay, bx, by) = BonkWorld.crossbar(side);
    final back = toScreen(ax, ay), mouth = toScreen(bx, by);
    final ground = toScreen(0, 0).dy;
    final color = side == 0 ? kBonkP1 : kBonkP2;
    _stroke
      ..strokeWidth = math.max(3, BonkWorld.crossbarThickness * s)
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFF4F4F8);
    canvas.drawLine(back, mouth, _stroke);
    canvas.drawLine(mouth, Offset(mouth.dx, ground), _stroke);
    _stroke
      ..strokeWidth = 2
      ..color = color;
    canvas.drawLine(Offset(mouth.dx, ground), Offset(mouth.dx, ground - s * 0.3), _stroke);
    _stroke.strokeCap = StrokeCap.butt;
  }

  void _drawPlayer(Canvas canvas, int index) {
    final p = bonk.players[index];
    final look = _looks[index];
    final s = _scale;
    final head = toScreen(p.x, p.y);
    final hr = BonkWorld.headRadius * s;
    final f = p.facing.toDouble();
    // Shadow.
    final ground = toScreen(p.x, 0);
    _fill.color = const Color(0x44000000);
    final lift = (p.footY / 4).clamp(0.0, 1.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: ground,
        width: hr * 1.6 * (1 - lift * 0.5),
        height: hr * 0.3 * (1 - lift * 0.5),
      ),
      _fill,
    );
    // Body (shirt) and back leg.
    final bodyTop = toScreen(p.x, p.footY + BonkWorld.bodyHeight).dy;
    final foot = toScreen(p.x, p.footY).dy;
    final bw = BonkWorld.bodyWidth * s;
    _stroke
      ..strokeWidth = math.max(3, s * 0.2)
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF20263D);
    canvas.drawLine(Offset(head.dx - f * bw * 0.2, bodyTop), Offset(head.dx - f * bw * 0.35, foot), _stroke);
    _fill.color = look.kit;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(head.dx - bw / 2, bodyTop - hr * 0.2, head.dx + bw / 2, foot - s * 0.1),
        Radius.circular(bw * 0.25),
      ),
      _fill,
    );
    // Kicking leg: swings from behind to the boot spot and back.
    final t = p.kickProgress;
    final swing = p.kicking ? math.sin(t * math.pi) : 0.0;
    final hip = Offset(head.dx + f * bw * 0.15, bodyTop + (foot - bodyTop) * 0.4);
    final bootRest = Offset(head.dx + f * bw * 0.3, foot);
    final bootOut = toScreen(p.bootX, p.bootY);
    final boot = Offset.lerp(bootRest, bootOut, swing)!;
    _stroke.color = const Color(0xFF20263D);
    canvas.drawLine(hip, boot, _stroke);
    _stroke.strokeCap = StrokeCap.butt;
    _fill.color = p.kicking ? kBonkGold : const Color(0xFF111111);
    canvas.drawOval(
      Rect.fromCenter(center: boot + Offset(f * s * 0.08, 0), width: s * 0.45, height: s * 0.24),
      _fill,
    );
    // Head.
    _fill.color = look.skin;
    canvas.drawCircle(head, hr, _fill);
    _drawHair(canvas, look, head, hr, f);
    // Eyes follow the ball.
    final ball = toScreen(bonk.ballX, bonk.ballY);
    final look2 = ball - head;
    final ld = look2.distance;
    final lv = ld < 1e-6 ? Offset(f, 0) : look2 / ld;
    final eyeY = head.dy - hr * 0.08;
    for (final ex in [0.12, 0.52]) {
      final e = Offset(head.dx + f * hr * ex, eyeY);
      _fill.color = const Color(0xFFFFFFFF);
      canvas.drawCircle(e, hr * 0.17, _fill);
      _fill.color = const Color(0xFF151515);
      canvas.drawCircle(e + lv * hr * 0.07, hr * 0.085, _fill);
    }
    // Eyebrows.
    _stroke
      ..strokeWidth = math.max(1.5, hr * 0.08)
      ..color = look.hair;
    for (final ex in [0.12, 0.52]) {
      final c = Offset(head.dx + f * hr * ex, eyeY - hr * 0.25);
      canvas.drawLine(
        c - Offset(hr * 0.12, -hr * 0.03 * look.brow),
        c + Offset(hr * 0.12, -hr * 0.03 * look.brow),
        _stroke,
      );
    }
    // Mouth: grin normally, open when kicking or celebrating.
    final mouth = Offset(head.dx + f * hr * 0.4, head.dy + hr * 0.38);
    final celebrating = _goalFlash > 0 && _flashScorer == index;
    if (p.kicking || celebrating) {
      _fill.color = const Color(0xFF6B1E1E);
      canvas.drawOval(Rect.fromCenter(center: mouth, width: hr * 0.34, height: hr * 0.26), _fill);
    } else {
      _stroke
        ..strokeWidth = math.max(1.5, hr * 0.07)
        ..color = const Color(0xFF6B1E1E);
      canvas.drawArc(
        Rect.fromCenter(center: mouth, width: hr * 0.4, height: hr * 0.22),
        0.2,
        math.pi - 0.4,
        false,
        _stroke,
      );
    }
  }

  void _drawHair(Canvas canvas, _Look look, Offset head, double hr, double f) {
    _fill.color = look.hair;
    switch (look.style) {
      case 0: // Cap of hair over the top.
        canvas.drawArc(
          Rect.fromCircle(center: head, radius: hr * 1.02),
          math.pi * 1.05,
          math.pi * 0.9,
          true,
          _fill,
        );
      case 1: // Spikes.
        _path.reset();
        for (var i = 0; i <= 6; i++) {
          final a = math.pi * (1.1 + i * 0.8 / 6);
          final rr = i.isEven ? hr * 1.0 : hr * 1.3;
          final pt = head + Offset(math.cos(a), math.sin(a)) * rr;
          if (i == 0) {
            _path.moveTo(pt.dx, pt.dy);
          } else {
            _path.lineTo(pt.dx, pt.dy);
          }
        }
        _path.lineTo(head.dx, head.dy - hr * 0.3);
        _path.close();
        canvas.drawPath(_path, _fill);
      default: // Bun at the back plus a headband in the kit colour.
        canvas.drawArc(
          Rect.fromCircle(center: head, radius: hr * 1.0),
          math.pi * 1.05,
          math.pi * 0.9,
          true,
          _fill,
        );
        canvas.drawCircle(head + Offset(-f * hr * 0.8, -hr * 0.65), hr * 0.32, _fill);
        _stroke
          ..strokeWidth = math.max(2, hr * 0.14)
          ..color = look.kit;
        canvas.drawArc(
          Rect.fromCircle(center: head, radius: hr * 0.93),
          math.pi * 1.12,
          math.pi * 0.76,
          false,
          _stroke,
        );
    }
  }

  void _drawBall(Canvas canvas) {
    final s = _scale;
    final c = toScreen(bonk.ballX, bonk.ballY);
    final r = BonkWorld.ballRadius * s;
    // Shadow on the grass.
    _fill.color = const Color(0x33000000);
    final g = toScreen(bonk.ballX, 0);
    canvas.drawOval(Rect.fromCenter(center: g, width: r * 1.6, height: r * 0.35), _fill);
    _fill.color = const Color(0xFFF7F7F2);
    canvas.drawCircle(c, r, _fill);
    // Rotating panel pattern.
    _fill.color = const Color(0xFF2A2A33);
    for (var i = 0; i < 5; i++) {
      final a = _ballSpin + i * math.pi * 2 / 5;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * r * 0.62, r * 0.2, _fill);
    }
    canvas.drawCircle(c, r * 0.24, _fill);
    _stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF2A2A33);
    canvas.drawCircle(c, r, _stroke);
    if (bonk.kickoffTimer > 0) {
      final t = bonk.kickoffTimer / BonkWorld.kickoffTicksFirst;
      _stroke
        ..strokeWidth = 2
        ..color = kBonkGold.withValues(alpha: 0.8);
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 1.8),
        -math.pi / 2,
        math.pi * 2 * t.clamp(0.0, 1.0),
        false,
        _stroke,
      );
    }
  }

  void _drawButtons(Canvas canvas) {
    for (final b in buttons) {
      final held = isHeld(b.player, b.kind);
      final color = b.player == 0 ? kBonkP1 : kBonkP2;
      final rr = RRect.fromRectAndRadius(b.rect, Radius.circular(b.rect.width * 0.3));
      _fill.color = held ? color.withValues(alpha: 0.55) : const Color(0x33FFFFFF);
      canvas.drawRRect(rr, _fill);
      _stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: held ? 1 : 0.7);
      canvas.drawRRect(rr, _stroke);
      final c = b.rect.center;
      final u = b.rect.width * 0.2;
      switch (b.kind) {
        case BonkButton.left:
        case BonkButton.right:
          final d = b.worldDir;
          _path
            ..reset()
            ..moveTo(c.dx + d * u * 1.1, c.dy)
            ..lineTo(c.dx - d * u * 0.7, c.dy - u)
            ..lineTo(c.dx - d * u * 0.7, c.dy + u)
            ..close();
          _fill.color = const Color(0xFFFFFFFF);
          canvas.drawPath(_path, _fill);
        case BonkButton.jump:
        case BonkButton.kick:
          _text(
            canvas,
            b.kind == BonkButton.jump ? 'JUMP' : 'KICK',
            c,
            b.rect.width * 0.22,
            const Color(0xFFFFFFFF),
            flip: b.flip,
          );
      }
    }
  }

  /// Draws [text] centred on [at], upside down when [flip] (for the far player).
  void _text(Canvas canvas, String text, Offset at, double size, Color color, {bool flip = false}) {
    if (flip) {
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(math.pi);
      at = Offset.zero;
    }
    CanvasText.draw(
      canvas,
      text,
      at,
      size: size,
      color: color,
      align: Alignment.center,
      weight: FontWeight.w900,
    );
    if (flip) canvas.restore();
  }

  String get _clockText {
    if (bonk.goldenGoalActive) return 'GOLDEN GOAL';
    final secs = (bonk.remainingTicks * BonkWorld.stepDt).ceil();
    return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  void _drawHud(Canvas canvas) {
    final r = pitchRect;
    final a = bonk.scores[0], b = bonk.scores[1];
    final timeColor = bonk.goldenGoalActive || bonk.remainingTicks < 10 * 120
        ? kBonkGold
        : const Color(0xFFE6EAFF);
    if (twoPlayer) {
      // Player 1 reads below the pitch, player 2 above it (upside down).
      final y1 = r.bottom + 22;
      _text(canvas, 'P1  $a', Offset(size.x * 0.25, y1), 20, kBonkP1);
      _text(canvas, _clockText, Offset(size.x * 0.5, y1), 16, timeColor);
      _text(canvas, '$b  P2', Offset(size.x * 0.75, y1), 20, kBonkP2);
      final y2 = r.top - 22;
      _text(canvas, 'P2  $b', Offset(size.x * 0.75, y2), 20, kBonkP2, flip: true);
      _text(canvas, _clockText, Offset(size.x * 0.5, y2), 16, timeColor, flip: true);
      _text(canvas, '$a  P1', Offset(size.x * 0.25, y2), 20, kBonkP1, flip: true);
    } else {
      final y = r.top - 30;
      _text(canvas, 'YOU  $a', Offset(size.x * 0.22, y), 22, kBonkP1);
      _text(canvas, _clockText, Offset(size.x * 0.5, y), 18, timeColor);
      _text(canvas, '$b  CPU', Offset(size.x * 0.78, y), 22, kBonkP2);
      _text(
        canvas,
        '${level.name.toUpperCase()} · FIRST TO ${bonk.winScore}',
        Offset(size.x * 0.5, y + 20),
        11,
        const Color(0xAAE6EAFF),
      );
    }
    final mid = toScreen(BonkWorld.width / 2, BonkWorld.height * 0.62);
    final s = _scale;
    if (_goalFlash > 0) {
      final alpha = (_goalFlash / 0.6).clamp(0.0, 1.0);
      final c = (_flashScorer == 0 ? kBonkP1 : kBonkP2).withValues(alpha: alpha);
      final label = bonk.isOver ? 'WINNER!' : (_flashOwn ? 'OWN GOAL!' : 'GOAL!');
      _text(canvas, label, mid, s * 1.2, c, flip: twoPlayer && _flashScorer == 1);
    } else if (started && bonk.kickoffTimer > 0 && !bonk.isOver) {
      _text(canvas, 'READY', mid, s * 0.9, kBonkGold);
    }
    if (bonk.isOver) {
      final String line;
      if (bonk.isDraw) {
        line = 'FULL TIME · DRAW';
      } else if (twoPlayer) {
        line = 'PLAYER ${(bonk.winner ?? 0) + 1} WINS';
      } else {
        line = bonk.won ? 'YOU WIN' : 'CPU WINS';
      }
      final at = toScreen(BonkWorld.width / 2, BonkWorld.height * 0.4);
      _text(canvas, line, at, s * 0.9, kBonkGold);
      if (twoPlayer) {
        _text(
          canvas,
          line,
          toScreen(BonkWorld.width / 2, BonkWorld.height * 0.82),
          s * 0.7,
          kBonkGold,
          flip: true,
        );
      }
    }
    if (_hintTime > 0 && !bonk.isOver) {
      final c = const Color(0xFFFFFFFF).withValues(alpha: 0.85 * (_hintTime / 1.0).clamp(0.0, 1.0));
      final hint = 'HOLD ARROWS TO RUN · JUMP · KICK';
      _text(canvas, hint, Offset(size.x / 2, buttons.first.rect.top - 14), 12, c);
      if (twoPlayer) {
        _text(canvas, hint, Offset(size.x / 2, buttons.last.rect.bottom + 14), 12, c, flip: true);
      }
    }
  }

  void _drawMenu(Canvas canvas) {
    _fill.color = const Color(0xC4101528);
    canvas.drawRect(Offset.zero & Size(size.x, size.y), _fill);
    _text(canvas, 'BONK BALL', Offset(size.x / 2, size.y * 0.24), 40, kBonkGold);
    _text(
      canvas,
      '60 SECONDS OR FIRST TO 5',
      Offset(size.x / 2, size.y * 0.24 + 40),
      15,
      const Color(0xFFE6EAFF),
    );
    final pulse = 0.5 + 0.5 * math.sin(_clock * 3);
    for (var i = 0; i < _menu.length; i++) {
      final b = _menuButton(i);
      final o = _menu[i];
      final color = o.twoPlayer ? kBonkP2 : kBonkP1;
      final rr = RRect.fromRectAndRadius(b, const Radius.circular(25));
      _fill.color = color.withValues(alpha: 0.18 + 0.08 * pulse);
      canvas.drawRRect(rr, _fill);
      _stroke
        ..strokeWidth = 2
        ..color = color;
      canvas.drawRRect(rr, _stroke);
      _text(canvas, o.label, b.center, 15, const Color(0xFFFFFFFF));
    }
    final last = _menuButton(_menu.length - 1);
    _text(
      canvas,
      '2 players: sit opposite, each uses their own corners',
      Offset(size.x / 2, last.bottom + 26),
      12,
      const Color(0xAAE6EAFF),
    );
  }
}
