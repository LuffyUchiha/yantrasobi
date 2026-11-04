import 'dart:math' as math;

/// A tiny deterministic 2D circle physics engine for Ball Pour.
///
/// * Dynamic bodies are equal-mass circles ([PBall]).
/// * Static and kinematic geometry is made of capsules ([PSeg]): a segment
///   with a thickness. A zero-length segment is a round peg.
/// * Fixed timestep: [step] always advances by exactly [dt]. Callers own the
///   accumulator, so the same inputs always produce the same trajectory.
/// * Iteration order is deterministic (list order + a linked-list spatial
///   hash rebuilt every step), and no objects are allocated while stepping.
///
/// Coordinates are world units with +y pointing down (screen-like), so
/// gravity is positive.

class PBall {
  PBall(this.id);

  /// Stable id assigned at spawn (used for colours and tests).
  int id;
  double x = 0, y = 0, vx = 0, vy = 0;
  double radius = 0.15;

  /// Seconds this ball has moved slower than [CirclePhysics.restSpeed].
  double restTime = 0;

  /// Seconds this ball has been continuously inside the cup.
  double cupTime = 0;

  /// Bitmask of multiplier rings this ball (or its parent) already used.
  int ringMask = 0;

  /// Whether the ball touched any geometry or ball during the last step.
  bool touching = false;

  /// Strongest normal impact speed against geometry during the last step.
  double impact = 0;

  double get speed => math.sqrt(vx * vx + vy * vy);

  void reset(int newId, double px, double py, double pvx, double pvy, double r) {
    id = newId;
    x = px;
    y = py;
    vx = pvx;
    vy = pvy;
    radius = r;
    restTime = 0;
    cupTime = 0;
    ringMask = 0;
    touching = false;
    impact = 0;
  }
}

/// A capsule: segment a-b with half-thickness [thickness]. Endpoint
/// velocities make it kinematic (moving planks and cups push balls).
class PSeg {
  PSeg(
    this.ax,
    this.ay,
    this.bx,
    this.by, {
    this.thickness = 0.06,
    this.restitution = 0.35,
    this.friction = 0.08,
  });

  double ax, ay, bx, by;
  double avx = 0, avy = 0, bvx = 0, bvy = 0;
  double thickness;
  double restitution;
  double friction;

  /// Disabled segments are skipped by collision (kept for stable indices).
  bool enabled = true;

  bool get isPeg => ax == bx && ay == by;

  /// Moves the segment to new endpoints over [dt] seconds, recording the
  /// endpoint velocities used by the collision response.
  void moveTo(double nax, double nay, double nbx, double nby, double dt) {
    if (dt > 0) {
      avx = (nax - ax) / dt;
      avy = (nay - ay) / dt;
      bvx = (nbx - bx) / dt;
      bvy = (nby - by) / dt;
    }
    ax = nax;
    ay = nay;
    bx = nbx;
    by = nby;
  }

  void stop() {
    avx = avy = bvx = bvy = 0;
  }
}

class CirclePhysics {
  CirclePhysics({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    this.capacity = 250,
    this.gravity = 18,
    this.maxRadius = 0.15,
  }) : _cell = maxRadius * 2.2 {
    _cols = ((maxX - minX) / _cell).ceil() + 1;
    _rows = ((maxY - minY) / _cell).ceil() + 1;
    _heads = List<int>.filled(_cols * _rows, -1);
    _next = List<int>.filled(capacity, -1);
    _cellOf = List<int>.filled(capacity, 0);
  }

  /// Grid bounds (balls outside are clamped into the border cells).
  final double minX, minY, maxX, maxY;
  final int capacity;
  double gravity;
  final double maxRadius;

  /// Fixed substep length.
  static const double dt = 1 / 120;

  /// Terminal speed. `maxSpeed * dt` (0.1) stays well below the smallest
  /// contact distance (ball radius + segment thickness), so nothing tunnels.
  static const double maxSpeed = 12;
  static const double restSpeed = 0.45;
  static const double ballRestitution = 0.25;
  static const double ballFriction = 0.04;
  static const double airDamping = 0.15;
  static const int ballIterations = 2;

  /// Largest positional correction per ball-ball contact per iteration.
  static const double maxCorrection = 0.05;

  final List<PBall> balls = [];
  final List<PSeg> segs = [];
  final List<PBall> _pool = [];
  int _nextId = 0;

  final double _cell;
  late final int _cols, _rows;
  late final List<int> _heads;
  late final List<int> _next;
  late final List<int> _cellOf;

  int get ballCount => balls.length;
  bool get isFull => balls.length >= capacity;

  /// Adds a ball, or returns null when at [capacity].
  PBall? spawn(double x, double y, {double vx = 0, double vy = 0, double? radius}) {
    if (balls.length >= capacity) return null;
    final b = _pool.isNotEmpty ? _pool.removeLast() : PBall(0);
    b.reset(_nextId++, x, y, vx, vy, radius ?? maxRadius);
    balls.add(b);
    return b;
  }

  /// Removes the ball at [index] (swap-remove, deterministic).
  void removeAt(int index) {
    final b = balls[index];
    final last = balls.removeLast();
    if (!identical(last, b)) balls[index] = last;
    _pool.add(b);
  }

  PSeg addSeg(PSeg s) {
    segs.add(s);
    return s;
  }

  /// True when the circle at (x, y) with radius [r] overlaps any ball.
  bool isFree(double x, double y, double r) {
    for (final b in balls) {
      final dx = b.x - x, dy = b.y - y, rs = b.radius + r;
      if (dx * dx + dy * dy < rs * rs) return false;
    }
    return true;
  }

  /// Advances the simulation by one fixed substep of [dt].
  void step() {
    const h = dt;
    final n = balls.length;
    // 1. Integrate.
    final damp = 1 - airDamping * h;
    for (var i = 0; i < n; i++) {
      final b = balls[i];
      b.vy += gravity * h;
      b.vx *= damp;
      b.vy *= damp;
      final s2 = b.vx * b.vx + b.vy * b.vy;
      if (s2 > maxSpeed * maxSpeed) {
        final k = maxSpeed / math.sqrt(s2);
        b.vx *= k;
        b.vy *= k;
      }
      b.x += b.vx * h;
      b.y += b.vy * h;
      b.touching = false;
      b.impact = 0;
    }
    // 2. Ball-ball contacts via a spatial hash.
    for (var it = 0; it < ballIterations; it++) {
      _buildGrid();
      _solveBalls(it == 0);
    }
    // 3. Geometry last, so walls always win over pile pressure.
    for (var i = 0; i < n; i++) {
      _solveSegs(balls[i]);
    }
    // 4. Rest timers.
    for (var i = 0; i < n; i++) {
      final b = balls[i];
      final s2 = b.vx * b.vx + b.vy * b.vy;
      if (s2 < restSpeed * restSpeed) {
        b.restTime += h;
      } else {
        b.restTime = 0;
      }
    }
  }

  int _cellIndex(double x, double y) {
    var cx = ((x - minX) / _cell).floor();
    var cy = ((y - minY) / _cell).floor();
    if (cx < 0) cx = 0;
    if (cx >= _cols) cx = _cols - 1;
    if (cy < 0) cy = 0;
    if (cy >= _rows) cy = _rows - 1;
    return cy * _cols + cx;
  }

  void _buildGrid() {
    _heads.fillRange(0, _heads.length, -1);
    // Insert in reverse so each cell's list is in ascending ball order.
    for (var i = balls.length - 1; i >= 0; i--) {
      final c = _cellIndex(balls[i].x, balls[i].y);
      _cellOf[i] = c;
      _next[i] = _heads[c];
      _heads[c] = i;
    }
  }

  void _solveBalls(bool impulses) {
    final n = balls.length;
    for (var i = 0; i < n; i++) {
      final a = balls[i];
      final c = _cellOf[i];
      final cx = c % _cols, cy = c ~/ _cols;
      for (var oy = -1; oy <= 1; oy++) {
        final yy = cy + oy;
        if (yy < 0 || yy >= _rows) continue;
        for (var ox = -1; ox <= 1; ox++) {
          final xx = cx + ox;
          if (xx < 0 || xx >= _cols) continue;
          var j = _heads[yy * _cols + xx];
          while (j >= 0) {
            if (j > i) _collidePair(a, balls[j], i, j, impulses);
            j = _next[j];
          }
        }
      }
    }
  }

  void _collidePair(PBall a, PBall b, int i, int j, bool impulses) {
    var dx = b.x - a.x, dy = b.y - a.y;
    final rs = a.radius + b.radius;
    final d2 = dx * dx + dy * dy;
    if (d2 >= rs * rs) return;
    double d;
    if (d2 < 1e-12) {
      // Coincident centres: separate along a deterministic direction.
      dx = ((i + j).isEven ? 1 : -1) * 1e-3;
      dy = -1e-3;
      d = math.sqrt(dx * dx + dy * dy);
    } else {
      d = math.sqrt(d2);
    }
    final nx = dx / d, ny = dy / d;
    var corr = (rs - d) * 0.5 * 0.9;
    if (corr > maxCorrection) corr = maxCorrection;
    a.x -= nx * corr;
    a.y -= ny * corr;
    b.x += nx * corr;
    b.y += ny * corr;
    a.touching = true;
    b.touching = true;
    if (!impulses) return;
    final rvx = b.vx - a.vx, rvy = b.vy - a.vy;
    final vn = rvx * nx + rvy * ny;
    if (vn >= 0) return;
    final jn = -(1 + ballRestitution) * vn * 0.5;
    a.vx -= jn * nx;
    a.vy -= jn * ny;
    b.vx += jn * nx;
    b.vy += jn * ny;
    // Light tangential friction.
    final tvx = rvx - vn * nx, tvy = rvy - vn * ny;
    a.vx += tvx * ballFriction;
    a.vy += tvy * ballFriction;
    b.vx -= tvx * ballFriction;
    b.vy -= tvy * ballFriction;
  }

  void _solveSegs(PBall b) {
    for (var k = 0; k < segs.length; k++) {
      final s = segs[k];
      if (!s.enabled) continue;
      final reach = b.radius + s.thickness;
      // AABB reject.
      if (b.x + reach < math.min(s.ax, s.bx) ||
          b.x - reach > math.max(s.ax, s.bx) ||
          b.y + reach < math.min(s.ay, s.by) ||
          b.y - reach > math.max(s.ay, s.by)) {
        continue;
      }
      final ex = s.bx - s.ax, ey = s.by - s.ay;
      final len2 = ex * ex + ey * ey;
      var t = 0.0;
      if (len2 > 1e-12) {
        t = ((b.x - s.ax) * ex + (b.y - s.ay) * ey) / len2;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
      }
      final qx = s.ax + ex * t, qy = s.ay + ey * t;
      var dx = b.x - qx, dy = b.y - qy;
      final d2 = dx * dx + dy * dy;
      if (d2 >= reach * reach) continue;
      double d;
      if (d2 < 1e-12) {
        // Centre exactly on the segment: push along its left normal (up for
        // a left-to-right segment), or straight up for a peg.
        if (len2 > 1e-12) {
          final l = math.sqrt(len2);
          dx = ey / l;
          dy = -ex / l;
        } else {
          dx = 0;
          dy = -1;
        }
        d = 0;
      } else {
        d = math.sqrt(d2);
        dx /= d;
        dy /= d;
      }
      final nx = dx, ny = dy;
      final pen = reach - d;
      b.x += nx * pen;
      b.y += ny * pen;
      b.touching = true;
      // Velocity of the surface at the contact point.
      final svx = s.avx + (s.bvx - s.avx) * t, svy = s.avy + (s.bvy - s.avy) * t;
      var rvx = b.vx - svx, rvy = b.vy - svy;
      final vn = rvx * nx + rvy * ny;
      if (vn < 0) {
        if (-vn > b.impact) b.impact = -vn;
        final e = -vn > 1.0 ? s.restitution : 0.0;
        rvx -= (1 + e) * vn * nx;
        rvy -= (1 + e) * vn * ny;
        // Coulomb friction on the tangential part, bounded by the normal impulse.
        final vnAfter = rvx * nx + rvy * ny;
        final ttx = rvx - vnAfter * nx, tty = rvy - vnAfter * ny;
        final tl = math.sqrt(ttx * ttx + tty * tty);
        if (tl > 1e-9) {
          var drop = s.friction * (-vn) * (1 + e);
          if (drop > tl) drop = tl;
          rvx -= ttx / tl * drop;
          rvy -= tty / tl * drop;
        }
        b.vx = svx + rvx;
        b.vy = svy + rvy;
      }
    }
  }

  /// Total kinetic energy (mass 1 per ball), for tests and debugging.
  double get kineticEnergy {
    var e = 0.0;
    for (final b in balls) {
      e += 0.5 * (b.vx * b.vx + b.vy * b.vy);
    }
    return e;
  }

  /// Smallest centre distance minus radii over all ball pairs (O(n^2), debug only).
  double minPairGap() {
    var best = double.infinity;
    for (var i = 0; i < balls.length; i++) {
      for (var j = i + 1; j < balls.length; j++) {
        final a = balls[i], b = balls[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        final g = math.sqrt(dx * dx + dy * dy) - a.radius - b.radius;
        if (g < best) best = g;
      }
    }
    return best;
  }
}
