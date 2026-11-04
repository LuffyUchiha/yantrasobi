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
import 'serpent_world.dart';

class SerpentLoopCartridge extends FlameCartridge<SerpentLoopGame> {
  const SerpentLoopCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'serpent-loop',
    title: 'Serpent Loop',
    tagline: 'Swipe, snack, grow. Do not bite yourself.',
    description:
        'A modern take on the grid serpent. Swipe to steer, eat apples to grow and race the '
        'clock for golden fruit. Shrink berries trim your tail and a phase orb lets you slip '
        'through your own body for a few seconds. Classic mode walls you in with level goals and '
        'rocky layouts; Wrap mode loops the edges for an endless score attack.',
    genre: 'Arcade snake',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF7BE36A),
    icon: Icons.gesture_rounded,
    tags: ['arcade', 'snake', 'grid', 'one-thumb', 'levels', 'score-attack'],
    controls: [
      'Swipe up / down / left / right to turn (two quick swipes queue two turns)',
      'On the start card, tap CLASSIC or WRAP to pick a mode, then PLAY or just swipe',
    ],
    mechanics: [
      'grid movement',
      'turn queue',
      'growth',
      'speed ramp',
      'timed golden fruit',
      'shrink berries',
      'phase through self',
      'wrap-around edges',
      'levels',
    ],
    goal:
        'Classic: reach the target length to clear the level; walls, rocks and your own body '
        'end the run. Wrap: survive and score as long as you can.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  SerpentLoopGame createGame(FlameCartridgeSession<SerpentLoopGame> session) => SerpentLoopGame(session);
}

class SerpentLoopGame extends AsobiFlameGame {
  SerpentLoopGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      _seed = seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff {
    mode = session.context.save.data['mode'] == 'wrap' ? SerpentMode.wrap : SerpentMode.classic;
    serpent = _build();
  }

  final int? seed;
  final int _seed;

  /// Saved Classic level (Wrap mode ignores it).
  final int level;
  late SerpentMode mode;

  /// The rules object (FlameGame already owns `world`).
  late SerpentWorld serpent;
  final Sparks sparks = Sparks(capacity: 240);

  /// Whether the start card has been dismissed.
  bool started = false;

  static const double swipeThreshold = 18;

  static const Color _accent = Color(0xFF7BE36A);
  static const Color _headColor = Color(0xFFB8FF7A);
  static const Color _tailColor = Color(0xFF1E9E78);
  static const Color _appleColor = Color(0xFFFF4F5E);
  static const Color _goldColor = Color(0xFFFFC933);
  static const Color _berryColor = Color(0xFFB45CFF);
  static const Color _phaseColor = Color(0xFF4FE3FF);
  static const Color _rockColor = Color(0xFF5B5F7A);

  final Paint _paint = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Path _path = Path();
  late final List<Color> _palette = List.generate(
    32,
    (i) => Color.lerp(_headColor, _tailColor, i / 31)!,
    growable: false,
  );

  Picture? _background;
  Size _backgroundSize = Size.zero;
  bool _backgroundDirty = true;

  Vector2? _anchor;
  bool _swiped = false;

  double _clock = 0;
  double _endTimer = 0;
  double _shake = 0;
  double _flash = 0;
  Color _flashColor = Colors.white;
  bool _reported = false;

  int get best => session.context.save.intData('best_${mode.name}', 0);

  SerpentWorld _build() =>
      SerpentWorld(seed: _seed, mode: mode, level: mode == SerpentMode.classic ? level : 1);

  @override
  int get entityCount => serpent.entityCount + sparks.count;

  @override
  Color backgroundColor() => const Color(0xFF0D1A16);

  /// Switches mode on the start card (rebuilds the run).
  void setMode(SerpentMode m) {
    if (started || m == mode) return;
    mode = m;
    session.context.save.data['mode'] = m.name;
    serpent = _build();
    _backgroundDirty = true;
  }

  /// Dismisses the start card and starts the clock.
  void startRun() {
    if (started) return;
    started = true;
    audio.play(Sfx.whoosh);
  }

  // ---------------------------------------------------------------- layout
  double get _arenaTop => hudTop + 58;
  double get _arenaBottom => size.y - safePadding.bottom - 14;
  double get _cell => math.max(
    1,
    math.min((size.x - 20) / SerpentWorld.cols, (_arenaBottom - _arenaTop) / SerpentWorld.rows),
  );
  Rect get _arena {
    final c = _cell;
    final w = SerpentWorld.cols * c, h = SerpentWorld.rows * c;
    return Rect.fromLTWH((size.x - w) / 2, _arenaTop + (_arenaBottom - _arenaTop - h) / 2, w, h);
  }

  Rect get _panel {
    final a = _arena;
    final w = math.min(a.width - 24, 320.0);
    const h = 270.0;
    return Rect.fromCenter(center: Offset(a.center.dx, a.center.dy - 20), width: w, height: h);
  }

  Rect modeButtonRect(int i) {
    final p = _panel;
    final w = (p.width - 48) / 2;
    return Rect.fromLTWH(p.left + 16 + i * (w + 16), p.top + 70, w, 42);
  }

  Rect get playButtonRect {
    final p = _panel;
    return Rect.fromCenter(center: Offset(p.center.dx, p.bottom - 44), width: 160, height: 46);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    _anchor = position.clone();
    _swiped = false;
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final a = _anchor;
    if (a == null) return;
    if (_trySwipe(a, position)) {
      a.setFrom(position);
      _swiped = true;
    }
  }

  @override
  void onPointerUp(Vector2 position) {
    final a = _anchor;
    _anchor = null;
    if (a == null) return;
    if (_trySwipe(a, position)) return;
    if (!_swiped) _tap(Offset(position.x, position.y));
  }

  bool _trySwipe(Vector2 from, Vector2 to) {
    final dx = to.x - from.x, dy = to.y - from.y;
    if (math.max(dx.abs(), dy.abs()) < swipeThreshold) return false;
    final d = dx.abs() >= dy.abs()
        ? (dx < 0 ? SerpentDir.left : SerpentDir.right)
        : (dy < 0 ? SerpentDir.up : SerpentDir.down);
    if (serpent.isOver) return true;
    if (!started) startRun();
    if (serpent.turn(d)) {
      audio.play(Sfx.tap);
      audio.haptic(HapticKind.selection);
    }
    return true;
  }

  void _tap(Offset p) {
    if (started || size.x <= 0) return;
    for (var i = 0; i < 2; i++) {
      if (modeButtonRect(i).contains(p)) {
        final m = SerpentMode.values[i];
        if (m != mode) {
          setMode(m);
          audio.play(Sfx.pop);
          audio.haptic(HapticKind.selection);
        }
        return;
      }
    }
    if (playButtonRect.contains(p)) startRun();
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (_flash > 0) _flash -= dt;
    if (!started) return;
    final w = serpent;
    w.update(dt);
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      final c = size.x > 0 ? _center(e.cell) : Offset.zero;
      switch (e.kind) {
        case SerpentEventKind.ate:
          final color = _foodColor(e.food!);
          switch (e.food!) {
            case FoodKind.apple:
              audio.play(Sfx.coin);
              audio.haptic(HapticKind.light);
            case FoodKind.golden:
              audio.play(Sfx.powerup);
              audio.haptic(HapticKind.medium);
              _flash = 0.18;
              _flashColor = _goldColor;
            case FoodKind.berry:
              audio.play(Sfx.pop);
              audio.haptic(HapticKind.light);
            case FoodKind.phase:
              audio.play(Sfx.powerup);
              audio.haptic(HapticKind.medium);
              _flash = 0.18;
              _flashColor = _phaseColor;
          }
          sparks.burst(c.dx, c.dy, reduced ? 4 : 14, color, speed: 160, life: 0.45);
        case SerpentEventKind.expired:
          if (!reduced) sparks.burst(c.dx, c.dy, 6, _foodColor(e.food!).withValues(alpha: 0.6), speed: 70);
        case SerpentEventKind.phaseEnded:
          audio.play(Sfx.whoosh);
        case SerpentEventKind.died:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          sparks.burst(c.dx, c.dy, reduced ? 10 : 40, const Color(0xFFFF5470), speed: 260);
          _flash = 0.35;
          _flashColor = const Color(0xFFFF5470);
          if (!reduced) _shake = 0.35;
        case SerpentEventKind.cleared:
          audio.play(Sfx.win);
          audio.haptic(HapticKind.medium);
          final a = _arena;
          sparks.burst(a.center.dx, a.center.dy, reduced ? 12 : 60, _goldColor, speed: 320);
      }
    }
    if (w.isOver && !_reported) {
      _endTimer += dt;
      if (_endTimer >= 1.0) _report();
    }
  }

  void _report() {
    _reported = true;
    final w = serpent;
    final save = session.context.save;
    final key = 'best_${mode.name}';
    final newBest = w.score > save.intData(key, 0);
    if (newBest) save.data[key] = w.score;
    final details = <String, String>{
      'Mode': mode == SerpentMode.classic ? 'Classic' : 'Wrap',
      if (mode == SerpentMode.classic) 'Level': '$level',
      'Length': '${w.length}',
      'Longest': '${w.maxLength}',
      'Apples': '${w.apples}',
      'Golden': '${w.goldens}',
      'Time': '${w.time.toStringAsFixed(0)}s',
    };
    if (mode == SerpentMode.wrap) {
      finish(
        RunResult(
          score: w.score,
          headline: newBest && w.score > 0
              ? 'New best! Length ${w.maxLength} in the loop.'
              : 'Loop closed at length ${w.maxLength}.',
          details: details,
        ),
      );
      return;
    }
    if (w.cleared) {
      save.data['level'] = level + 1;
      session.context.commitSave();
    }
    final headline = w.cleared
        ? 'Level $level cleared! Level ${level + 1} unlocked.'
        : switch (w.cause) {
            DeathCause.wall => 'Hit the wall on level $level.',
            DeathCause.obstacle => 'Ran into a rock on level $level.',
            _ => 'Bit your own tail on level $level.',
          };
    finish(RunResult(score: w.score, won: w.cleared, headline: headline, details: details));
  }

  @override
  void onRemove() {
    _background?.dispose();
    _background = null;
    super.onRemove();
  }

  // ---------------------------------------------------------------- render
  Offset _center(int cell) {
    final a = _arena, c = _cell;
    return Offset(
      a.left + (SerpentWorld.cellX(cell) + 0.5) * c,
      a.top + (SerpentWorld.cellY(cell) + 0.5) * c,
    );
  }

  static Color _foodColor(FoodKind k) => switch (k) {
    FoodKind.apple => _appleColor,
    FoodKind.golden => _goldColor,
    FoodKind.berry => _berryColor,
    FoodKind.phase => _phaseColor,
  };

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    final w = serpent;
    final arena = _arena;
    if (_backgroundDirty || _background == null || _backgroundSize != Size(size.x, size.y)) {
      _buildBackground(arena);
    }
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 10;
      canvas.translate(math.sin(_clock * 83) * m, math.cos(_clock * 71) * m);
    }
    canvas.drawPicture(_background!);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(arena, const Radius.circular(10)));
    for (final f in w.foods) {
      _drawFood(canvas, f);
    }
    _drawSnake(canvas, w);
    canvas.restore();
    sparks.render(canvas);
    canvas.restore();
    if (_flash > 0) {
      _paint.color = _flashColor.withValues(alpha: (_flash * 0.6).clamp(0.0, 0.3));
      canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
    }
    _drawHud(canvas, w);
    if (!started) _drawStartCard(canvas);
    if (w.isOver) {
      CanvasText.draw(
        canvas,
        w.cleared ? 'LEVEL CLEARED!' : (mode == SerpentMode.wrap ? 'LOOP CLOSED' : 'OUCH!'),
        arena.center,
        size: 34,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: w.cleared ? _goldColor : const Color(0xFFFF5470),
      );
    }
  }

  void _buildBackground(Rect arena) {
    _background?.dispose();
    final rec = PictureRecorder();
    final canvas = Canvas(rec);
    final c = _cell;
    final paint = Paint();
    final rr = RRect.fromRectAndRadius(arena, const Radius.circular(10));
    paint.color = mode == SerpentMode.wrap ? const Color(0xFF4FE3FF) : const Color(0xFF2E5C4A);
    canvas.drawRRect(rr.inflate(3), paint);
    paint.color = const Color(0xFF15281F);
    canvas.drawRRect(rr, paint);
    paint.color = const Color(0xFF1A3226);
    for (var y = 0; y < SerpentWorld.rows; y++) {
      for (var x = y % 2; x < SerpentWorld.cols; x += 2) {
        canvas.drawRect(Rect.fromLTWH(arena.left + x * c, arena.top + y * c, c, c), paint);
      }
    }
    if (mode == SerpentMode.wrap) {
      // Dashed edges hint that the walls are open.
      paint.color = const Color(0xFF0D1A16);
      for (var t = 0.0; t < arena.width; t += c) {
        canvas.drawRect(Rect.fromLTWH(arena.left + t + c * 0.3, arena.top - 3.5, c * 0.4, 3.5), paint);
        canvas.drawRect(Rect.fromLTWH(arena.left + t + c * 0.3, arena.bottom, c * 0.4, 3.5), paint);
      }
      for (var t = 0.0; t < arena.height; t += c) {
        canvas.drawRect(Rect.fromLTWH(arena.left - 3.5, arena.top + t + c * 0.3, 3.5, c * 0.4), paint);
        canvas.drawRect(Rect.fromLTWH(arena.right, arena.top + t + c * 0.3, 3.5, c * 0.4), paint);
      }
    }
    for (final cell in serpent.obstacleCells) {
      final r = Rect.fromLTWH(
        arena.left + SerpentWorld.cellX(cell) * c,
        arena.top + SerpentWorld.cellY(cell) * c,
        c,
        c,
      ).deflate(c * 0.06);
      paint.color = const Color(0xFF2B2D3D);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.shift(Offset(0, c * 0.08)), Radius.circular(c * 0.2)),
        paint,
      );
      paint.color = _rockColor;
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(c * 0.2)), paint);
      paint.color = const Color(0xFF7D82A3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(r.left + c * 0.12, r.top + c * 0.1, r.width * 0.5, c * 0.16),
          Radius.circular(c * 0.08),
        ),
        paint,
      );
    }
    _background = rec.endRecording();
    _backgroundSize = Size(size.x, size.y);
    _backgroundDirty = false;
  }

  void _drawFood(Canvas canvas, SerpentFood f) {
    final c = _center(f.cell);
    final cell = _cell;
    var r = cell * 0.36;
    if (f.expires) {
      final age = f.maxLife - f.life;
      r *= math.min(1.0, age * 6);
      // Blink during the last 1.5 seconds.
      if (f.life < 1.5 && (f.life * 8).floor().isEven) r *= 0.82;
    }
    if (r <= 0) return;
    switch (f.kind) {
      case FoodKind.apple:
        _paint.color = const Color(0x55000000);
        canvas.drawCircle(c + Offset(0, r * 0.25), r, _paint);
        _paint.color = _appleColor;
        canvas.drawCircle(c, r, _paint);
        _paint.color = const Color(0x66FFFFFF);
        canvas.drawCircle(c + Offset(-r * 0.35, -r * 0.35), r * 0.28, _paint);
        _stroke
          ..strokeWidth = math.max(1.5, r * 0.18)
          ..color = const Color(0xFF7A4A22);
        canvas.drawLine(c + Offset(0, -r * 0.8), c + Offset(r * 0.15, -r * 1.25), _stroke);
        _paint.color = const Color(0xFF5BD15B);
        canvas.drawOval(
          Rect.fromCenter(center: c + Offset(r * 0.5, -r * 1.05), width: r * 0.8, height: r * 0.4),
          _paint,
        );
      case FoodKind.golden:
        final pulse = 0.5 + 0.5 * math.sin(_clock * 7);
        _paint.color = _goldColor.withValues(alpha: 0.18 + 0.12 * pulse);
        canvas.drawCircle(c, r * (1.5 + 0.2 * pulse), _paint);
        _paint.color = _goldColor;
        canvas.drawCircle(c, r, _paint);
        _paint.color = const Color(0xFFFFF3B0);
        _star(canvas, c, r * 0.55);
        _timerRing(canvas, c, r * 1.35, f, _goldColor);
      case FoodKind.berry:
        _paint.color = _berryColor;
        final s = r * 0.52;
        canvas.drawCircle(c + Offset(-s * 0.75, s * 0.4), s, _paint);
        canvas.drawCircle(c + Offset(s * 0.75, s * 0.4), s, _paint);
        canvas.drawCircle(c + Offset(0, -s * 0.6), s, _paint);
        _paint.color = const Color(0x77FFFFFF);
        canvas.drawCircle(c + Offset(-s * 0.2, -s * 0.9), s * 0.3, _paint);
        _timerRing(canvas, c, r * 1.35, f, _berryColor.withValues(alpha: 0.6));
      case FoodKind.phase:
        final rot = _clock * 2.5;
        _path.reset();
        for (var i = 0; i < 4; i++) {
          final a = rot + i * math.pi / 2;
          final p = c + Offset(math.cos(a), math.sin(a)) * r * 1.05;
          i == 0 ? _path.moveTo(p.dx, p.dy) : _path.lineTo(p.dx, p.dy);
        }
        _path.close();
        _paint.color = _phaseColor.withValues(alpha: 0.85);
        canvas.drawPath(_path, _paint);
        _paint.color = Colors.white.withValues(alpha: 0.8);
        canvas.drawCircle(c, r * 0.28, _paint);
        _timerRing(canvas, c, r * 1.45, f, _phaseColor);
    }
  }

  void _star(Canvas canvas, Offset c, double r) {
    _path.reset();
    for (var i = 0; i < 8; i++) {
      final a = -math.pi / 2 + i * math.pi / 4;
      final rr = i.isEven ? r : r * 0.42;
      final p = c + Offset(math.cos(a), math.sin(a)) * rr;
      i == 0 ? _path.moveTo(p.dx, p.dy) : _path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(_path..close(), _paint);
  }

  void _timerRing(Canvas canvas, Offset c, double r, SerpentFood f, Color color) {
    if (!f.expires) return;
    final t = (f.life / f.maxLife).clamp(0.0, 1.0);
    _stroke
      ..strokeWidth = math.max(1.5, _cell * 0.08)
      ..color = color;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, math.pi * 2 * t, false, _stroke);
  }

  // Scratch delta for the interpolated polyline (grid units).
  double _ddx = 0, _ddy = 0;

  /// Wrap-corrected one-step delta from cell [a] to the adjacent cell [b].
  void _delta(int a, int b) {
    var dx = SerpentWorld.cellX(b) - SerpentWorld.cellX(a);
    var dy = SerpentWorld.cellY(b) - SerpentWorld.cellY(a);
    if (dx > 1) dx = -1;
    if (dx < -1) dx = 1;
    if (dy > 1) dy = -1;
    if (dy < -1) dy = 1;
    _ddx = dx.toDouble();
    _ddy = dy.toDouble();
  }

  void _seg(Canvas canvas, double ax, double ay, double bx, double by) {
    final a = _arena, c = _cell;
    canvas.drawLine(
      Offset(a.left + (ax + 0.5) * c, a.top + (ay + 0.5) * c),
      Offset(a.left + (bx + 0.5) * c, a.top + (by + 0.5) * c),
      _stroke,
    );
  }

  /// Draws the part of the step from cell [from] toward adjacent cell [to]
  /// covering fraction [f] of it; across a wrap edge, both halves are drawn.
  void _partial(Canvas canvas, int from, int to, double f) {
    _delta(from, to);
    final fx = SerpentWorld.cellX(from).toDouble(), fy = SerpentWorld.cellY(from).toDouble();
    _seg(canvas, fx, fy, fx + _ddx * f, fy + _ddy * f);
    final tx = SerpentWorld.cellX(to).toDouble(), ty = SerpentWorld.cellY(to).toDouble();
    if ((tx - fx).abs() > 1 || (ty - fy).abs() > 1) {
      _seg(canvas, tx - _ddx, ty - _ddy, tx - _ddx + _ddx * f, ty - _ddy + _ddy * f);
    }
  }

  void _drawSnake(Canvas canvas, SerpentWorld w) {
    final body = w.body;
    final n = body.length;
    final a = w.alpha;
    final c = _cell;
    final phasing = w.phasing;
    final ghost = phasing ? 0.55 + 0.2 * math.sin(_clock * 14) : 1.0;
    // Three passes: shadow, body, highlight. Segments go tail to head so the
    // head ends up on top.
    for (var pass = 0; pass < 3; pass++) {
      for (var k = n - 1; k >= 1; k--) {
        final t = k / math.max(1, n - 1);
        final width = c * (0.82 - 0.3 * t);
        final col = _palette[(t * 31).round()];
        switch (pass) {
          case 0:
            _stroke
              ..strokeWidth = width + c * 0.12
              ..color = (phasing ? _phaseColor : const Color(0xFF07130E)).withValues(alpha: 0.55 * ghost);
          case 1:
            _stroke
              ..strokeWidth = width
              ..color = w.dead
                  ? Color.lerp(col, const Color(0xFF8A3045), 0.55)!
                  : col.withValues(alpha: ghost);
          default:
            _stroke
              ..strokeWidth = width * 0.28
              ..color = Colors.white.withValues(alpha: 0.22 * ghost);
        }
        if (k == n - 1 && w.prevTail != body[k]) {
          // Tail: retreats from prevTail toward body[n - 1].
          _partial(canvas, body[k], w.prevTail, 1 - a);
        }
        // Link to the next segment; the head link slides in as the tick runs.
        _partial(canvas, body[k], body[k - 1], k == 1 ? a : 1);
      }
    }
    // Head blob + eyes, drawn at the interpolated head position (and at its
    // twin across a wrap edge).
    _delta(body[1], body[0]);
    final dx = _ddx, dy = _ddy;
    _drawHead(canvas, _cx(body[1]) + dx * a, _cy(body[1]) + dy * a, dx, dy, ghost, w.dead);
    final tx = _cx(body[0]), ty = _cy(body[0]);
    if ((tx - _cx(body[1])).abs() > 1 || (ty - _cy(body[1])).abs() > 1) {
      _drawHead(canvas, tx - dx * (1 - a), ty - dy * (1 - a), dx, dy, ghost, w.dead);
    }
  }

  double _cx(int cell) => SerpentWorld.cellX(cell).toDouble();
  double _cy(int cell) => SerpentWorld.cellY(cell).toDouble();

  void _drawHead(Canvas canvas, double gx, double gy, double dx, double dy, double ghost, bool dead) {
    final a = _arena, c = _cell;
    final p = Offset(a.left + (gx + 0.5) * c, a.top + (gy + 0.5) * c);
    _paint.color = (dead ? const Color(0xFFE0566E) : _headColor).withValues(alpha: ghost);
    canvas.drawCircle(p, c * 0.47, _paint);
    // Eyes sit forward of centre, either side of the heading.
    final fwd = Offset(dx, dy);
    final side = Offset(-dy, dx);
    for (final s in const [-1.0, 1.0]) {
      final e = p + fwd * (c * 0.14) + side * (c * 0.21 * s);
      _paint.color = Colors.white;
      canvas.drawCircle(e, c * 0.14, _paint);
      _paint.color = const Color(0xFF10201A);
      if (dead) {
        _stroke
          ..strokeWidth = math.max(1.2, c * 0.06)
          ..color = const Color(0xFF10201A);
        final q = c * 0.08;
        canvas.drawLine(e + Offset(-q, -q), e + Offset(q, q), _stroke);
        canvas.drawLine(e + Offset(-q, q), e + Offset(q, -q), _stroke);
      } else {
        canvas.drawCircle(e + fwd * (c * 0.05), c * 0.07, _paint);
      }
    }
  }

  void _drawHud(Canvas canvas, SerpentWorld w) {
    final top = hudTop;
    CanvasText.draw(canvas, 'SCORE', Offset(16, top), size: 11, color: Colors.white54);
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(16, top + 13),
      size: 22,
      color: _goldColor,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      'LENGTH',
      Offset(size.x / 2, top),
      size: 11,
      color: Colors.white54,
      align: Alignment.topCenter,
    );
    CanvasText.draw(
      canvas,
      mode == SerpentMode.classic ? '${w.length} / ${w.goal}' : '${w.length}',
      Offset(size.x / 2, top + 13),
      size: 22,
      weight: FontWeight.w900,
      align: Alignment.topCenter,
      color: _accent,
    );
    CanvasText.draw(
      canvas,
      'BEST',
      Offset(size.x - 16, top),
      size: 11,
      color: Colors.white54,
      align: Alignment.topRight,
    );
    CanvasText.draw(
      canvas,
      '${math.max(best, w.score)}',
      Offset(size.x - 16, top + 13),
      size: 22,
      weight: FontWeight.w900,
      align: Alignment.topRight,
    );
    final barTop = top + 44;
    final barRect = Rect.fromLTWH(16, barTop, size.x - 32, 6);
    if (w.phasing) {
      drawBar(canvas, barRect, w.phaseTimer / SerpentWorld.phaseDuration, _phaseColor);
      CanvasText.draw(
        canvas,
        'PHASE',
        Offset(size.x / 2, barTop - 1),
        size: 10,
        align: Alignment.bottomCenter,
        color: _phaseColor,
      );
    } else if (mode == SerpentMode.classic) {
      final start = SerpentWorld.startLength;
      drawBar(canvas, barRect, (w.length - start) / math.max(1, w.goal - start), _accent);
      CanvasText.draw(
        canvas,
        'LEVEL $level',
        Offset(size.x / 2, barTop - 1),
        size: 10,
        align: Alignment.bottomCenter,
        color: Colors.white60,
      );
    } else {
      CanvasText.draw(
        canvas,
        'WRAP · ENDLESS',
        Offset(size.x / 2, barTop - 1),
        size: 10,
        align: Alignment.bottomCenter,
        color: _phaseColor,
      );
    }
  }

  void _drawStartCard(Canvas canvas) {
    final arena = _arena;
    _paint.color = const Color(0xAA06100C);
    canvas.drawRRect(RRect.fromRectAndRadius(arena, const Radius.circular(10)), _paint);
    final p = _panel;
    final rr = RRect.fromRectAndRadius(p, const Radius.circular(20));
    _paint.color = const Color(0xF0182B22);
    canvas.drawRRect(rr, _paint);
    _stroke
      ..strokeWidth = 2
      ..color = _accent.withValues(alpha: 0.7);
    canvas.drawRRect(rr, _stroke);
    CanvasText.draw(
      canvas,
      'SERPENT LOOP',
      Offset(p.center.dx, p.top + 22),
      size: 24,
      weight: FontWeight.w900,
      align: Alignment.topCenter,
      color: _accent,
    );
    const labels = ['CLASSIC', 'WRAP'];
    for (var i = 0; i < 2; i++) {
      final r = modeButtonRect(i);
      final selected = mode == SerpentMode.values[i];
      final b = RRect.fromRectAndRadius(r, const Radius.circular(21));
      _paint.color = selected ? (i == 0 ? _accent : _phaseColor) : const Color(0xFF243A30);
      canvas.drawRRect(b, _paint);
      CanvasText.draw(
        canvas,
        labels[i],
        r.center,
        size: 15,
        weight: FontWeight.w900,
        align: Alignment.center,
        color: selected ? const Color(0xFF0D1A16) : Colors.white60,
      );
    }
    final line1 = mode == SerpentMode.classic
        ? 'Level $level · reach length ${SerpentWorld.goalForLevel(level)}'
        : 'Edges loop around · endless';
    final line2 = mode == SerpentMode.classic ? 'Walls and rocks bite' : 'Score as much as you can';
    CanvasText.draw(
      canvas,
      line1,
      Offset(p.center.dx, p.top + 128),
      size: 14,
      align: Alignment.topCenter,
      color: Colors.white,
      maxWidth: p.width - 24,
    );
    CanvasText.draw(
      canvas,
      line2,
      Offset(p.center.dx, p.top + 150),
      size: 13,
      align: Alignment.topCenter,
      color: Colors.white60,
      maxWidth: p.width - 24,
      weight: FontWeight.w500,
    );
    final pb = playButtonRect;
    final pulse = 0.5 + 0.5 * math.sin(_clock * 4);
    _paint.color = Color.lerp(_goldColor, const Color(0xFFFFE08A), pulse)!;
    canvas.drawRRect(RRect.fromRectAndRadius(pb, const Radius.circular(23)), _paint);
    CanvasText.draw(
      canvas,
      'PLAY',
      pb.center,
      size: 18,
      weight: FontWeight.w900,
      align: Alignment.center,
      color: const Color(0xFF2A1E00),
    );
    CanvasText.draw(
      canvas,
      'Swipe to steer · swipe anywhere to start',
      Offset(arena.center.dx, p.bottom + 14),
      size: 12,
      align: Alignment.topCenter,
      color: Colors.white70,
      weight: FontWeight.w500,
    );
  }
}
