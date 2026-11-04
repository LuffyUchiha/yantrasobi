import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, HSVColor, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'stack_world.dart';

class StackRunnerCartridge extends FlameCartridge<StackRunnerGame> {
  const StackRunnerCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'stack-runner',
    title: 'Stack Runner',
    tagline: 'Grow the tower. Spend it wisely.',
    description:
        'A sprint down a floating five-lane track. Scoop up blocks to grow '
        'the tower under your feet, slam through walls that shave blocks off, lay planks over '
        'gaps, then burn whatever is left climbing the x1 to x10 multiplier stairs.',
    genre: 'Hyper-casual runner',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFFB627),
    icon: Icons.directions_run_rounded,
    tags: ['runner', 'hyper-casual', 'one-thumb', 'levels', 'pseudo-3d'],
    controls: ['Tap to start running', 'Drag left / right to steer'],
    mechanics: ['block stacking', 'walls strip blocks', 'gap bridging', 'multiplier stairs', 'levels'],
    goal:
        'Reach the finish with blocks to spare. Each step of the x1 to x10 stairs costs blocks; '
        'score = gems x the step you reach.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  StackRunnerGame createGame(FlameCartridgeSession<StackRunnerGame> session) => StackRunnerGame(session);
}

/// Three pre-shaded face colours for a box.
class _Shade {
  _Shade(Color base)
    : top = Color.lerp(base, const Color(0xFFFFFFFF), 0.22)!,
      front = base,
      side = Color.lerp(base, const Color(0xFF000000), 0.3)!;
  final Color top;
  final Color front;
  final Color side;
}

/// Allocation-free pinhole camera (same conventions as `Projector`: +X right,
/// +Y up, +Z into the screen, vertical FOV). The last projection is left in
/// [sx], [sy] and [sd] instead of returning an `Offset`.
class _Cam {
  double ex = 0, ey = 0, ez = 0;
  double _fx = 0, _fy = 0, _fz = 1, _rx = 1, _ry = 0, _rz = 0, _ux = 0, _uy = 1, _uz = 0;
  double _tanY = 0.6, _aspect = 0.5, _w = 1, _h = 1;
  double sx = 0, sy = 0, sd = 1;
  bool ready = false;

  void setUp(
    double eyeX,
    double eyeY,
    double eyeZ,
    double tx,
    double ty,
    double tz,
    Vector2 size,
    double fovY,
  ) {
    ex = eyeX;
    ey = eyeY;
    ez = eyeZ;
    var fx = tx - ex, fy = ty - ey, fz = tz - ez;
    var l = math.sqrt(fx * fx + fy * fy + fz * fz);
    fx /= l;
    fy /= l;
    fz /= l;
    // right = up x forward with up = (0, 1, 0).
    var rx = fz, rz = -fx;
    l = math.sqrt(rx * rx + rz * rz);
    rx /= l;
    rz /= l;
    _fx = fx;
    _fy = fy;
    _fz = fz;
    _rx = rx;
    _ry = 0;
    _rz = rz;
    // up2 = forward x right.
    _ux = fy * rz;
    _uy = fz * rx - fx * rz;
    _uz = -fy * rx;
    _tanY = math.tan(fovY / 2);
    _w = size.x;
    _h = size.y;
    _aspect = _h == 0 ? 1 : _w / _h;
    ready = true;
  }

  bool project(double x, double y, double z) {
    final dx = x - ex, dy = y - ey, dz = z - ez;
    final d = dx * _fx + dy * _fy + dz * _fz;
    if (d <= 0.1) return false;
    final xs = (dx * _rx + dy * _ry + dz * _rz) / d;
    final ys = (dx * _ux + dy * _uy + dz * _uz) / d;
    sx = (xs / (_tanY * _aspect) + 1) / 2 * _w;
    sy = (1 - ys / _tanY) / 2 * _h;
    sd = d;
    return true;
  }

  /// Pixels per world unit at the depth of the last projected point.
  double scale(double worldSize) => worldSize / (sd * _tanY) * _h / 2;
}

class StackRunnerGame extends AsobiFlameGame {
  StackRunnerGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      rules = StackWorld(
        level: math.max(1, session.context.save.intData('level', 1)),
        seed: seed ?? kCourseSeed,
      ) {
    _levelLabel = 'LEVEL $level';
  }

  /// Courses are procedural but fixed per level number, so a level can be learned.
  static const int kCourseSeed = 2718;

  final int? seed;
  final int level;
  final StackWorld rules;
  final Sparks sparks = Sparks(capacity: 260);
  late final String _levelLabel;

  final _Cam _cam = _Cam();
  final Path _path = Path();
  final Paint _paint = Paint();
  final Paint _line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _sky = Paint();
  final Float64List _q = Float64List(16);

  double _camX = 0;
  double _camY = -1;
  double _baseY = 0;
  double _shake = 0;
  double _flash = 0;
  double _endTimer = 0;
  double _fallY = 0;
  double _fallV = 0;
  bool _reported = false;

  static const double _viewDist = 58;
  static const double _fov = 60 * math.pi / 180;
  static const Color _fog = Color(0xFF2B2452);
  static const Color _abyss = Color(0xFF06060E);
  static const Color _accent = Color(0xFFFFB627);
  static const Color _gemColor = Color(0xFF4DE1FF);
  static const Color _bandA = Color(0xFF2C3068);
  static const Color _bandB = Color(0xFF353A7A);
  static const Color _rail = Color(0xFF8C93FF);

  static final _Shade _blockA = _Shade(const Color(0xFFFFB627));
  static final _Shade _blockB = _Shade(const Color(0xFFFF8F3D));
  static final _Shade _shed = _Shade(const Color(0xFF8C7A5B));
  static final _Shade _plank = _Shade(const Color(0xFFC98B3A));
  static final _Shade _wallSafe = _Shade(const Color(0xFF9E6BFF));
  static final _Shade _wallDanger = _Shade(const Color(0xFFE63964));
  static final _Shade _pit = _Shade(const Color(0xFF15142B));
  static final List<_Shade> _steps = [
    for (var i = 0; i < StackWorld.maxMultiplier; i++)
      _Shade(HSVColor.fromAHSV(1, (200 - i * 22) % 360, 0.62, 0.95).toColor()),
  ];
  static const List<String> _xLabels = ['x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7', 'x8', 'x9', 'x10'];
  static const List<String> _hLabels = ['0', '1', '2', '3', '4', '5', '6'];

  @override
  int get entityCount => rules.entityCount + sparks.count;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _sky.shader = Gradient.linear(Offset.zero, Offset(0, size.y * 0.55), const [
      Color(0xFF0F1029),
      Color(0xFF3A2A6E),
    ]);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) => rules.start();

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (size.x <= 0) return;
    rules.steer(delta.x * 6.0 / size.x);
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    final w = rules;
    w.update(dt);
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      switch (e.kind) {
        case StackEventKind.block:
          audio.play(Sfx.pop);
          if (!reduced) _burst(e, 5, _accent, 140);
        case StackEventKind.gem:
          audio.play(Sfx.coin);
          _burst(e, reduced ? 3 : 10, _gemColor, 180);
        case StackEventKind.wallHit:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.medium);
          _burst(e, reduced ? 4 : 14, const Color(0xFFFF8F3D), 220);
          if (!reduced) _shake = 0.18;
        case StackEventKind.crash:
          audio.play(Sfx.hit);
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
          _flash = 0.5;
          _burst(e, reduced ? 6 : 30, const Color(0xFFE63964), 260);
          if (!reduced) _shake = 0.45;
        case StackEventKind.bridge:
          audio.play(Sfx.tap);
        case StackEventKind.fall:
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
        case StackEventKind.finish:
          audio.play(Sfx.powerup);
        case StackEventKind.step:
          audio.play(Sfx.merge);
          audio.haptic(HapticKind.selection);
          _burst(e, reduced ? 3 : 12, _steps[e.count - 1].front, 200);
        case StackEventKind.win:
          audio.play(Sfx.win);
          _burst(e, reduced ? 10 : 60, const Color(0xFFFFE08A), 320);
      }
    }
    sparks.update(dt);
    final k = 1 - math.exp(-dt * 10);
    _baseY += (w.baseY - _baseY) * k;
    final towerTop = _baseY + math.min(w.stack, 40) * StackWorld.blockHeight;
    _camY = _camY < 0 ? towerTop : _camY + (towerTop - _camY) * (1 - math.exp(-dt * 3.5));
    _camX += (w.x * 0.55 - _camX) * k;
    if (_shake > 0) _shake -= dt;
    if (_flash > 0) _flash -= dt;
    if (w.isOver) {
      _endTimer += dt;
      if (w.lossCause == LossCause.gap) {
        _fallV += 18 * dt;
        _fallY -= _fallV * dt;
      }
      final delay = w.won ? 1.6 : 1.2;
      if (_endTimer >= delay && !_reported) _report(w);
    }
  }

  void _burst(StackEvent e, int n, Color color, double speed) {
    if (n <= 0 || !_cam.ready || !_cam.project(e.x, e.y, e.z)) return;
    sparks.burst(_cam.sx, _cam.sy, n, color, speed: speed);
  }

  void _report(StackWorld w) {
    _reported = true;
    if (w.won) {
      final save = session.context.save;
      save.data['level'] = level + 1;
      save.data['bestMultiplier'] = math.max(save.intData('bestMultiplier', 1), w.multiplier);
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: w.score,
        won: w.won,
        headline: w.won
            ? 'Level $level cleared at x${w.multiplier}! Level ${level + 1} unlocked.'
            : w.lossCause == LossCause.gap
            ? 'Out of blocks over a gap on level $level'
            : 'Tower too short for a wall on level $level',
        details: {
          'Level': '$level',
          'Gems': '${w.gems}',
          'Multiplier': 'x${w.multiplier}',
          'Blocks collected': '${w.blocksCollected}',
          'Blocks left': '${w.stack}',
          'Distance': '${(w.progress * 100).round()}%',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    final w = rules;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _sky);
    final ry = math.max(0.0, _camY);
    _cam.setUp(
      _camX,
      ry * 0.8 + 3.6,
      w.distance - 7.4 - ry * 0.75,
      _camX * 0.5,
      ry * 0.3 + 0.6,
      w.distance + 10,
      size,
      _fov,
    );
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 14;
      canvas.translate(math.sin(w.time * 90) * m, math.cos(w.time * 77) * m);
    }
    _drawTrack(canvas, w);
    _drawScene(canvas, w);
    sparks.render(canvas);
    canvas.restore();
    if (_flash > 0) {
      _paint.color = Color.fromARGB((_flash * 200).round().clamp(0, 255), 230, 57, 100);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
    }
    _drawHud(canvas, w);
  }

  double _fogAt(double z) => ((z - rules.distance - 34) / 24).clamp(0.0, 1.0) * 0.85;

  Color _fogged(Color c, double f) => f <= 0 ? c : Color.lerp(c, _fog, f)!;

  bool _corner(int i, double x, double y, double z) {
    if (!_cam.project(x, y, z)) return false;
    _q[i * 2] = _cam.sx;
    _q[i * 2 + 1] = _cam.sy;
    return true;
  }

  void _quad(Canvas canvas, int a, int b, int c, int d, Color color, double fog) {
    _path
      ..reset()
      ..moveTo(_q[a * 2], _q[a * 2 + 1])
      ..lineTo(_q[b * 2], _q[b * 2 + 1])
      ..lineTo(_q[c * 2], _q[c * 2 + 1])
      ..lineTo(_q[d * 2], _q[d * 2 + 1])
      ..close();
    _paint.color = _fogged(color, fog);
    canvas.drawPath(_path, _paint);
  }

  /// Axis-aligned box; only camera-facing faces are drawn.
  void _box(
    Canvas canvas,
    double x0,
    double x1,
    double y0,
    double y1,
    double z0,
    double z1,
    _Shade s, [
    double fog = 0,
  ]) {
    if (!(_corner(0, x0, y0, z0) &&
        _corner(1, x1, y0, z0) &&
        _corner(2, x1, y1, z0) &&
        _corner(3, x0, y1, z0) &&
        _corner(4, x0, y0, z1) &&
        _corner(5, x1, y0, z1) &&
        _corner(6, x1, y1, z1) &&
        _corner(7, x0, y1, z1))) {
      return;
    }
    final c = _cam;
    if (c.ex < x0) _quad(canvas, 0, 3, 7, 4, s.side, fog);
    if (c.ex > x1) _quad(canvas, 1, 2, 6, 5, s.side, fog);
    if (c.ey > y1) _quad(canvas, 3, 2, 6, 7, s.top, fog);
    if (c.ez < z0) _quad(canvas, 0, 1, 2, 3, s.front, fog);
  }

  /// Flat quad on the plane y = [y].
  void _floor(Canvas canvas, double x0, double x1, double z0, double z1, double y, Color color, double fog) {
    if (!(_corner(0, x0, y, z0) && _corner(1, x1, y, z0) && _corner(2, x1, y, z1) && _corner(3, x0, y, z1))) {
      return;
    }
    _quad(canvas, 0, 1, 2, 3, color, fog);
  }

  void _drawTrack(Canvas canvas, StackWorld w) {
    const hw = StackWorld.trackHalfWidth;
    final zNear = math.max(-20.0, _cam.ez + 0.6);
    final zFar = math.min(w.distance + _viewDist, w.finishZ);
    if (zFar > zNear) {
      const band = 3.0;
      var z0 = (zNear / band).floorToDouble() * band;
      while (z0 < zFar) {
        final a = math.max(z0, zNear);
        final b = math.min(z0 + band, zFar);
        final even = ((z0 / band).round() & 1) == 0;
        _floor(canvas, -hw, hw, a, b, 0, even ? _bandA : _bandB, _fogAt(a));
        z0 += band;
      }
      // Edge rails.
      _line
        ..strokeWidth = 2
        ..color = _rail;
      for (var side = -1; side <= 1; side += 2) {
        if (_cam.project(side * hw, 0, zNear)) {
          final x0 = _cam.sx, y0 = _cam.sy;
          if (_cam.project(side * hw, 0, zFar)) {
            canvas.drawLine(Offset(x0, y0), Offset(_cam.sx, _cam.sy), _line);
          }
        }
      }
      // Gaps: a hole in the floor plus the far wall of the pit.
      final items = w.items;
      for (var i = _lowerBound(items, zNear - 8); i < items.length; i++) {
        final it = items[i];
        if (it.z > zFar) break;
        if (it.kind != ItemKind.gap) continue;
        final a = math.max(it.z, zNear);
        final b = it.endZ;
        if (b <= a) continue;
        _floor(canvas, -hw, hw, a, b, 0, _abyss, 0);
        _box(canvas, -hw, hw, -3, 0, b, b + 0.01, _pit, _fogAt(b));
      }
    }
    // Finish line checkers.
    final f = w.finishZ;
    if (f < w.distance + _viewDist && f > w.distance - 6) {
      final fog = _fogAt(f);
      for (var r = 0; r < 2; r++) {
        for (var c = 0; c < 10; c++) {
          final light = ((r + c) & 1) == 0;
          final x0 = -hw + c * 0.5;
          _floor(
            canvas,
            x0,
            x0 + 0.5,
            f - 1 + r * 0.5,
            f - 0.5 + r * 0.5,
            0.005,
            light ? const Color(0xFFF2F2F2) : const Color(0xFF16162A),
            fog,
          );
        }
      }
    }
  }

  static int _lowerBound(List<TrackItem> items, double z) {
    var lo = 0, hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].z < z) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static int _lowerBoundPlaced(List<PlacedBlock> placed, double z) {
    var lo = 0, hi = placed.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (placed[mid].z < z) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _drawScene(Canvas canvas, StackWorld w) {
    final zNear = _cam.ez + 0.6;
    final zFar = w.distance + _viewDist;
    final onStairs = w.distance >= w.finishZ;
    var runnerDrawn = false;
    // Stairs are beyond every track item, so they come first (far to near).
    if (w.finishZ < zFar) {
      for (var m = StackWorld.maxMultiplier; m >= 1; m--) {
        final z0 = w.finishZ + (m - 1) * StackWorld.stepDepth;
        if (z0 > zFar) continue;
        final top = (m - 1) * StackWorld.stepHeight;
        final fog = _fogAt(z0);
        _box(
          canvas,
          -StackWorld.trackHalfWidth,
          StackWorld.trackHalfWidth,
          -0.6,
          top + 0.001,
          z0,
          z0 + StackWorld.stepDepth,
          _steps[m - 1],
          fog,
        );
        if (_cam.project(0, m == 1 ? 0 : top - StackWorld.stepHeight * 0.5, m == 1 ? z0 + 0.7 : z0)) {
          _label(canvas, _xLabels[m - 1], _cam.sx, _cam.sy, _cam.scale(0.42) / 20, m <= w.multiplier);
        }
        if (onStairs && !runnerDrawn && w.distance >= z0) {
          _drawRunner(canvas, w);
          runnerDrawn = true;
        }
      }
    }
    // Items and placed blocks, merged far to near with the runner.
    final items = w.items;
    final placed = w.placed;
    var i = _lowerBound(items, zFar) - 1;
    var j = _lowerBoundPlaced(placed, zFar) - 1;
    final iEnd = _lowerBound(items, zNear);
    final jEnd = _lowerBoundPlaced(placed, zNear);
    while (i >= iEnd || j >= jEnd) {
      final zi = i >= iEnd ? items[i].z : double.negativeInfinity;
      final zj = j >= jEnd ? placed[j].z : double.negativeInfinity;
      final z = math.max(zi, zj);
      if (!runnerDrawn && z < w.distance) {
        _drawRunner(canvas, w);
        runnerDrawn = true;
      }
      if (zi >= zj) {
        _drawItem(canvas, w, items[i]);
        i--;
      } else {
        _drawPlaced(canvas, placed[j]);
        j--;
      }
    }
    if (!runnerDrawn) _drawRunner(canvas, w);
  }

  void _drawItem(Canvas canvas, StackWorld w, TrackItem it) {
    final fog = _fogAt(it.z);
    switch (it.kind) {
      case ItemKind.block:
        if (it.taken) return;
        final bob = 0.08 + math.sin(w.time * 3 + it.z) * 0.06;
        const h = 0.3;
        _box(
          canvas,
          it.x - 0.3,
          it.x + 0.3,
          bob,
          bob + StackWorld.blockHeight,
          it.z - h,
          it.z + h,
          _blockA,
          fog,
        );
      case ItemKind.gem:
        if (it.taken) return;
        if (!_cam.project(it.x, 0.65 + math.sin(w.time * 4 + it.z) * 0.08, it.z)) return;
        final s = _cam.scale(1);
        final spin = 0.35 + 0.65 * math.cos(w.time * 3 + it.z).abs();
        final hw = s * 0.2 * spin, hh = s * 0.28;
        _path
          ..reset()
          ..moveTo(_cam.sx, _cam.sy - hh)
          ..lineTo(_cam.sx + hw, _cam.sy)
          ..lineTo(_cam.sx, _cam.sy + hh)
          ..lineTo(_cam.sx - hw, _cam.sy)
          ..close();
        _paint.color = _fogged(_gemColor, fog);
        canvas.drawPath(_path, _paint);
        _paint.color = _fogged(const Color(0xFFE8FDFF), fog);
        canvas.drawCircle(Offset(_cam.sx - hw * 0.3, _cam.sy - hh * 0.3), s * 0.05, _paint);
      case ItemKind.wall:
        final top = it.height * StackWorld.blockHeight;
        final danger = it.height > w.stack && !it.taken;
        final shade = danger ? _wallDanger : _wallSafe;
        _box(canvas, it.x0 + 0.04, it.x1 - 0.04, 0, top, it.z, it.z + StackWorld.wallDepth, shade, fog);
        // Block seams on the front face so the height reads as a count.
        _line
          ..strokeWidth = 1.5
          ..color = _fogged(const Color(0x66000000), fog);
        for (var r = 1; r < it.height; r++) {
          final y = r * StackWorld.blockHeight;
          if (_cam.project(it.x0 + 0.04, y, it.z)) {
            final ax = _cam.sx, ay = _cam.sy;
            if (_cam.project(it.x1 - 0.04, y, it.z)) {
              canvas.drawLine(Offset(ax, ay), Offset(_cam.sx, _cam.sy), _line);
            }
          }
        }
        if (_cam.project(it.x, top * 0.5, it.z)) {
          _label(canvas, _hLabels[it.height.clamp(0, 6)], _cam.sx, _cam.sy, _cam.scale(0.3) / 20, true);
        }
      case ItemKind.gap:
        break;
    }
  }

  void _drawPlaced(Canvas canvas, PlacedBlock p) {
    const bh = StackWorld.blockHeight;
    final fog = _fogAt(p.z);
    if (p.layer < 0) {
      _box(canvas, p.x - 0.42, p.x + 0.42, -bh, 0, p.z - 0.5, p.z + 0.5, _plank, fog);
    } else {
      _box(
        canvas,
        p.x - 0.38,
        p.x + 0.38,
        p.layer * bh,
        (p.layer + 1) * bh,
        p.z - 0.38,
        p.z + 0.38,
        _shed,
        fog,
      );
    }
  }

  void _drawRunner(Canvas canvas, StackWorld w) {
    const bh = StackWorld.blockHeight;
    final base = _baseY + _fallY;
    final x = w.x;
    final z = w.distance;
    final shown = math.min(w.stack, 40);
    for (var i = 0; i < shown; i++) {
      final y0 = base + i * bh;
      _box(canvas, x - 0.4, x + 0.4, y0, y0 + bh, z - 0.4, z + 0.4, i.isEven ? _blockA : _blockB);
    }
    final feetY = base + shown * bh;
    if (!_cam.project(x, feetY, z)) return;
    final s = _cam.scale(1);
    final fx = _cam.sx, fy = _cam.sy;
    final running = w.phase == StackPhase.running || w.phase == StackPhase.climbing;
    final swing = running ? math.sin(w.time * 14) * 0.13 * s : 0.0;
    final crashed = w.lossCause == LossCause.wall;
    _line
      ..strokeWidth = math.max(2, 0.1 * s)
      ..color = const Color(0xFF2B2F55);
    final hipY = fy - 0.36 * s;
    canvas.drawLine(Offset(fx, hipY), Offset(fx - 0.1 * s + swing, fy), _line);
    canvas.drawLine(Offset(fx, hipY), Offset(fx + 0.1 * s - swing, fy), _line);
    _paint.color = crashed ? const Color(0xFFE63964) : const Color(0xFFF5F7FF);
    canvas.drawRRect(
      RRect.fromLTRBR(fx - 0.17 * s, fy - 0.78 * s, fx + 0.17 * s, hipY + 0.04 * s, Radius.circular(0.1 * s)),
      _paint,
    );
    _paint.color = _accent;
    canvas.drawRect(Rect.fromLTRB(fx - 0.17 * s, fy - 0.62 * s, fx + 0.17 * s, fy - 0.54 * s), _paint);
    _paint.color = const Color(0xFFFFD9B0);
    canvas.drawCircle(Offset(fx, fy - 0.94 * s), 0.15 * s, _paint);
    // Stack counter floating above the head.
    if (!w.isOver || w.won) {
      CanvasText.draw(
        canvas,
        '${w.stack}',
        Offset(fx, fy - 1.15 * s),
        size: 15,
        align: Alignment.bottomCenter,
        color: const Color(0xFFFFE08A),
        weight: FontWeight.w900,
      );
    }
  }

  /// Text drawn at a fixed font size and scaled, so the text cache does not
  /// churn as objects approach.
  void _label(Canvas canvas, String text, double x, double y, double scale, bool bright) {
    if (scale < 0.15) return;
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(math.min(scale, 3));
    CanvasText.draw(
      canvas,
      text,
      Offset.zero,
      size: 20,
      align: Alignment.center,
      color: bright ? const Color(0xFFFFFFFF) : const Color(0xAAFFFFFF),
      weight: FontWeight.w900,
    );
    canvas.restore();
  }

  void _drawHud(Canvas canvas, StackWorld w) {
    final top = safePadding.top + 14;
    CanvasText.draw(canvas, _levelLabel, Offset(size.x / 2, top), size: 18, align: Alignment.topCenter);
    drawBar(canvas, Rect.fromLTWH(16, hudTop, size.x - 32, 8), w.progress, _accent);
    // Stack count (left) and gems (right).
    final rowY = hudTop + 18;
    _paint.color = _accent;
    canvas.drawRect(Rect.fromLTWH(16, rowY + 4, 14, 14), _paint);
    _paint.color = const Color(0xFFFF8F3D);
    canvas.drawRect(Rect.fromLTWH(16, rowY + 12, 14, 6), _paint);
    CanvasText.draw(canvas, '${w.stack}', Offset(36, rowY), size: 20, weight: FontWeight.w900);
    final gemX = size.x - 16;
    final gemSize = CanvasText.draw(
      canvas,
      '${w.gems}',
      Offset(gemX, rowY),
      size: 20,
      align: Alignment.topRight,
      color: _gemColor,
      weight: FontWeight.w900,
    );
    final gx = gemX - gemSize.width - 12;
    _path
      ..reset()
      ..moveTo(gx, rowY + 3)
      ..lineTo(gx + 7, rowY + 12)
      ..lineTo(gx, rowY + 21)
      ..lineTo(gx - 7, rowY + 12)
      ..close();
    _paint.color = _gemColor;
    canvas.drawPath(_path, _paint);

    final cy = size.y * 0.3;
    switch (w.phase) {
      case StackPhase.ready:
        CanvasText.draw(
          canvas,
          _levelLabel,
          Offset(size.x / 2, cy),
          size: 38,
          align: Alignment.center,
          color: const Color(0xFFFFE08A),
          weight: FontWeight.w900,
        );
        CanvasText.draw(
          canvas,
          'Tap to run · drag to steer',
          Offset(size.x / 2, cy + 40),
          size: 16,
          align: Alignment.center,
        );
        CanvasText.draw(
          canvas,
          'Walls take blocks · gaps need a block per plank',
          Offset(size.x / 2, size.y - safePadding.bottom - 48),
          size: 13,
          align: Alignment.center,
          color: Colors.white70,
          maxWidth: size.x - 32,
        );
      case StackPhase.climbing:
      case StackPhase.won:
        CanvasText.draw(
          canvas,
          _xLabels[w.multiplier - 1],
          Offset(size.x / 2, cy),
          size: 54,
          align: Alignment.center,
          color: _steps[w.multiplier - 1].top,
          weight: FontWeight.w900,
        );
        if (w.won) {
          CanvasText.draw(
            canvas,
            'SCORE ${w.score}',
            Offset(size.x / 2, cy + 46),
            size: 22,
            align: Alignment.center,
            color: const Color(0xFFFFE08A),
          );
        }
      case StackPhase.lost:
        CanvasText.draw(
          canvas,
          w.lossCause == LossCause.gap ? 'OUT OF BLOCKS!' : 'CRASH!',
          Offset(size.x / 2, cy),
          size: 38,
          align: Alignment.center,
          color: const Color(0xFFFF6B8A),
          weight: FontWeight.w900,
        );
      case StackPhase.running:
        break;
    }
  }
}
