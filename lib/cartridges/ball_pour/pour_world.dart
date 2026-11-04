import 'dart:math' as math;

import 'circle_physics.dart';
import 'levels.dart';

export 'levels.dart';

/// Pure-Dart rules for Ball Pour. No Flutter/Flame imports, deterministic for
/// a given level + seed + input sequence (fixed 1/120 s substeps).
///
/// Balls wait in a hopper above the play field. While the gate is open they
/// pour out of the spout at the level's flow rate. Static walls and pegs,
/// player-dragged planks and multiplier rings shape the stream; the goal is
/// to settle at least `target` balls inside the cup. Balls that fall off the
/// bottom are lost.

enum PourPhase { playing, won, lost }

/// Live state of one player plank.
class PourPlank {
  PourPlank(this.def, this.seg) : t = def.start, targetT = def.start;

  final PlankDef def;
  final PSeg seg;

  /// Current and requested rail parameter (0..1).
  double t;
  double targetT;

  bool get isPivot => def.kind == PlankKind.pivot;

  /// Plank angle in radians.
  double angleAt(double tt) {
    final deg = isPivot ? def.minAngle + (def.maxAngle - def.minAngle) * tt : def.angle;
    return deg * math.pi / 180;
  }

  double centerXAt(double tt) => def.ax + (def.bx - def.ax) * tt;
  double centerYAt(double tt) => def.ay + (def.by - def.ay) * tt;

  double get centerX => centerXAt(t);
  double get centerY => centerYAt(t);
  double get angle => angleAt(t);

  /// Distance moved per unit of t (world units for slides, radians for pivots).
  double get railSpan {
    if (isPivot) return (def.maxAngle - def.minAngle).abs() * math.pi / 180;
    final dx = def.bx - def.ax, dy = def.by - def.ay;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Rail parameter closest to the world point (x, y).
  double project(double x, double y) {
    if (isPivot) {
      var a = math.atan2(y - def.ay, x - def.ax);
      // A plank through its pivot looks the same rotated by pi: fold into
      // (-pi/2, pi/2].
      if (a > math.pi / 2) a -= math.pi;
      if (a <= -math.pi / 2) a += math.pi;
      final deg = a * 180 / math.pi;
      final span = def.maxAngle - def.minAngle;
      if (span.abs() < 1e-9) return 0;
      return ((deg - def.minAngle) / span).clamp(0.0, 1.0);
    }
    final ex = def.bx - def.ax, ey = def.by - def.ay;
    final l2 = ex * ex + ey * ey;
    if (l2 < 1e-12) return 0;
    return (((x - def.ax) * ex + (y - def.ay) * ey) / l2).clamp(0.0, 1.0);
  }
}

class PourWorld {
  PourWorld({this.level = 1, this.seed = 0, PourLevelDef? def})
    : def = def ?? pourLevel(level),
      _rng = math.Random(seed * 31 + level * 7907) {
    _build();
  }

  final int level;
  final int seed;
  final PourLevelDef def;
  final math.Random _rng;

  // ---------------------------------------------------------------- constants
  static const double width = kPourWidth;
  static const double height = kPourHeight;
  static const double ballRadius = 0.15;
  static const double spoutY = 2.15;
  static const double hopperTop = 0.35;
  static const double hopperBottom = 1.95;
  static const double spoutHalfWidth = 0.42;
  static const double plankThickness = 0.08;
  static const double cupThickness = 0.08;
  static const double plankSpeed = 9; // world units / s along a rail
  static const double pivotSpeed = 5; // rad / s
  static const double settleTime = 0.5;
  static const double cupSettleTime = 0.6;
  static const double stalemateTime = 1.0;
  static const double drainTimeout = 14;
  static const int pointsPerBall = 10;

  late final CirclePhysics phys = CirclePhysics(
    minX: -1,
    minY: -2,
    maxX: width + 1,
    maxY: height + 2,
    capacity: kPourBallCap,
    maxRadius: ballRadius,
  );

  final List<PourPlank> planks = [];
  late final PSeg cupLeft, cupBottom, cupRight;

  /// Per-ring split counters (renderer flashes rings on change).
  late final List<int> ringHits = List<int>.filled(def.rings.length, 0);

  PourPhase phase = PourPhase.playing;
  bool _gateOpen = false;
  double _emit = 0;
  int _lane = 0;
  double _acc = 0;
  double _stalemate = 0;
  double _sinceSpawn = 0;
  int _finalScore = 0;

  /// Simulated time in seconds (advances in exact substeps).
  double time = 0;

  /// Balls still waiting in the hopper.
  late int hopper = def.balls;
  int released = 0;
  int lost = 0;
  int splits = 0;

  /// Balls currently inside the cup.
  int cupCount = 0;

  /// Highest cup count seen, and the number of times a ball entered the cup.
  int bestCup = 0;
  int cupEntries = 0;

  /// Current cup centre x (sways on later levels).
  double cupX = 0;

  int get target => def.target;
  bool get gateOpen => _gateOpen;
  bool get isOver => phase != PourPhase.playing;
  bool get won => phase == PourPhase.won;
  List<PBall> get balls => phys.balls;
  int get liveBalls => phys.balls.length;
  int get entityCount => phys.balls.length + phys.segs.length;

  /// Balls that could still end up in the cup (hopper + on the field).
  int get ballsRemaining => hopper + phys.balls.length;

  int get levelBonus => 100 + 25 * level;

  int get score {
    if (isOver) return _finalScore;
    return cupCount * pointsPerBall;
  }

  double get cupLeftX => cupX - def.cup.width / 2;
  double get cupRightX => cupX + def.cup.width / 2;
  double get cupTop => def.cup.top;
  double get cupBottomY => def.cup.bottom;

  // ---------------------------------------------------------------- build
  void _build() {
    // Screen-edge walls; the bottom is open.
    phys.addSeg(PSeg(0, -2, 0, height + 1, thickness: 0.05, restitution: 0.3, friction: 0.05));
    phys.addSeg(PSeg(width, -2, width, height + 1, thickness: 0.05, restitution: 0.3, friction: 0.05));
    // Spout lips so balls leave the hopper cleanly.
    final hx = def.hopperX;
    phys.addSeg(
      PSeg(hx - spoutHalfWidth - 0.05, hopperBottom, hx - spoutHalfWidth - 0.05, spoutY, thickness: 0.05),
    );
    phys.addSeg(
      PSeg(hx + spoutHalfWidth + 0.05, hopperBottom, hx + spoutHalfWidth + 0.05, spoutY, thickness: 0.05),
    );
    for (final w in def.walls) {
      phys.addSeg(PSeg(w.ax, w.ay, w.bx, w.by, thickness: 0.06, restitution: w.bounce, friction: w.friction));
    }
    for (final p in def.pegs) {
      phys.addSeg(PSeg(p.x, p.y, p.x, p.y, thickness: p.r, restitution: 0.4, friction: 0.05));
    }
    for (final k in def.planks) {
      final seg = phys.addSeg(PSeg(0, 0, 0, 0, thickness: plankThickness, restitution: 0.25, friction: 0.3));
      final p = PourPlank(k, seg);
      planks.add(p);
      _placePlank(p, 0);
    }
    cupX = def.cup.x;
    cupLeft = phys.addSeg(PSeg(0, 0, 0, 0, thickness: cupThickness, restitution: 0.2, friction: 0.2));
    cupBottom = phys.addSeg(PSeg(0, 0, 0, 0, thickness: cupThickness, restitution: 0.15, friction: 0.3));
    cupRight = phys.addSeg(PSeg(0, 0, 0, 0, thickness: cupThickness, restitution: 0.2, friction: 0.2));
    _placeCup(0);
  }

  void _placePlank(PourPlank p, double dt) {
    final a = p.angle;
    final hx = math.cos(a) * p.def.length / 2, hy = math.sin(a) * p.def.length / 2;
    final cx = p.centerX, cy = p.centerY;
    p.seg.moveTo(cx - hx, cy - hy, cx + hx, cy + hy, dt);
  }

  double _cupXAt(double t) {
    final c = def.cup;
    if (c.sway <= 0) return c.x;
    return c.x + c.sway * math.sin(2 * math.pi * t / c.period);
  }

  void _placeCup(double dt) {
    cupX = _cupXAt(time);
    final c = def.cup;
    final l = cupX - c.width / 2, r = cupX + c.width / 2;
    cupLeft.moveTo(l, c.top, l, c.bottom, dt);
    cupBottom.moveTo(l, c.bottom, r, c.bottom, dt);
    cupRight.moveTo(r, c.bottom, r, c.top, dt);
  }

  // ---------------------------------------------------------------- input
  void setGateOpen(bool open) {
    if (isOver) open = false;
    _gateOpen = open;
  }

  /// Requests plank [index] to move toward the world point (x, y). The plank
  /// is constrained to its rail (slide) or angle range (pivot) and moves
  /// there at a limited speed so it can't teleport through balls.
  void movePlank(int index, double x, double y) {
    if (index < 0 || index >= planks.length) return;
    final p = planks[index];
    p.targetT = p.project(x, y);
  }

  /// Requests plank [index] to move to rail parameter [t] (0..1).
  void setPlankT(int index, double t) {
    if (index < 0 || index >= planks.length) return;
    planks[index].targetT = t.clamp(0.0, 1.0);
  }

  /// Index of the plank whose segment lies within [reach] of (x, y), or -1.
  int plankAt(double x, double y, double reach) {
    var best = -1;
    var bestD = reach;
    for (var i = 0; i < planks.length; i++) {
      final s = planks[i].seg;
      final d = _distToSeg(x, y, s.ax, s.ay, s.bx, s.by);
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  static double _distToSeg(double px, double py, double ax, double ay, double bx, double by) {
    final ex = bx - ax, ey = by - ay;
    final l2 = ex * ex + ey * ey;
    var t = 0.0;
    if (l2 > 1e-12) t = (((px - ax) * ex + (py - ay) * ey) / l2).clamp(0.0, 1.0);
    final dx = px - (ax + ex * t), dy = py - (ay + ey * t);
    return math.sqrt(dx * dx + dy * dy);
  }

  // ---------------------------------------------------------------- update
  /// Advances by [dt] seconds using fixed 1/120 s substeps.
  void update(double dt) {
    if (dt <= 0) return;
    _acc += dt > 0.1 ? 0.1 : dt;
    while (_acc >= CirclePhysics.dt - 1e-12) {
      _acc -= CirclePhysics.dt;
      _substep();
    }
  }

  /// Runs exactly [n] substeps (debug/test helper).
  void stepSubsteps(int n) {
    for (var i = 0; i < n; i++) {
      _substep();
    }
  }

  void _substep() {
    const h = CirclePhysics.dt;
    time += h;
    _moveKinematics(h);
    _emitBalls(h);
    phys.step();
    _postStep(h);
  }

  void _moveKinematics(double h) {
    for (final p in planks) {
      final span = p.railSpan;
      final maxDt = span < 1e-9 ? 1.0 : (p.isPivot ? pivotSpeed : plankSpeed) * h / span;
      final d = p.targetT - p.t;
      if (d.abs() < 1e-9) {
        if (p.seg.avx != 0 || p.seg.avy != 0 || p.seg.bvx != 0 || p.seg.bvy != 0) p.seg.stop();
        continue;
      }
      p.t += d.abs() <= maxDt ? d : maxDt * d.sign;
      _placePlank(p, h);
    }
    if (def.cup.sway > 0) _placeCup(h);
  }

  void _emitBalls(double h) {
    _sinceSpawn += h;
    if (!_gateOpen || hopper <= 0 || isOver) {
      _emit = 0;
      return;
    }
    _emit += def.flowRate * h;
    if (_emit > 2) _emit = 2;
    while (_emit >= 1 && hopper > 0 && !phys.isFull) {
      const lanes = [0.0, -0.2, 0.2, -0.1, 0.1];
      final x = def.hopperX + lanes[_lane % lanes.length] + (_rng.nextDouble() - 0.5) * 0.04;
      if (!phys.isFree(x, spoutY, ballRadius * 0.95)) break;
      _lane++;
      phys.spawn(x, spoutY, vx: (_rng.nextDouble() - 0.5) * 0.2, vy: 2.5);
      hopper--;
      released++;
      _emit -= 1;
      _sinceSpawn = 0;
    }
  }

  void _postStep(double h) {
    final bs = phys.balls;
    final l = cupLeftX, r = cupRightX, top = cupTop, bottom = cupBottomY;
    var inCup = 0;
    var unsettled = 0;
    var i = 0;
    while (i < bs.length) {
      final b = bs[i];
      if (b.y > height + 0.6 || b.x < -0.8 || b.x > width + 0.8) {
        phys.removeAt(i);
        lost++;
        continue;
      }
      for (var k = 0; k < def.rings.length; k++) {
        final bit = 1 << k;
        if (b.ringMask & bit != 0) continue;
        final rg = def.rings[k];
        final dx = b.x - rg.x, dy = b.y - rg.y;
        if (dx * dx + dy * dy > rg.r * rg.r) continue;
        b.ringMask |= bit;
        final c = phys.spawn(b.x + ballRadius, b.y, vx: b.vx + 1.2, vy: b.vy, radius: b.radius);
        if (c != null) {
          c.ringMask = b.ringMask;
          b.x -= ballRadius;
          b.vx -= 1.2;
          splits++;
          ringHits[k]++;
        }
      }
      if (b.x > l && b.x < r && b.y > top && b.y < bottom) {
        inCup++;
        b.cupTime += h;
      } else {
        b.cupTime = 0;
      }
      if (b.restTime < settleTime && b.cupTime < cupSettleTime) unsettled++;
      i++;
    }
    if (inCup > cupCount) cupEntries += inCup - cupCount;
    cupCount = inCup;
    if (inCup > bestCup) bestCup = inCup;
    if (!isOver) _checkOutcome(unsettled, h);
  }

  void _checkOutcome(int unsettled, double h) {
    final pouring = _gateOpen && hopper > 0;
    if (cupCount >= target && unsettled == 0 && !pouring) {
      _end(PourPhase.won);
      return;
    }
    if (potentialBalls < target) {
      _end(PourPhase.lost);
      return;
    }
    if (hopper == 0 && unsettled == 0 && cupCount < target) {
      _stalemate += h;
      if (_stalemate >= stalemateTime) _end(PourPhase.lost);
    } else {
      _stalemate = 0;
    }
    if (hopper == 0 && _sinceSpawn > drainTimeout) {
      _end(cupCount >= target ? PourPhase.won : PourPhase.lost);
    }
  }

  /// Upper bound on how many balls could still reach the cup, counting the
  /// splits that unused multiplier rings could still produce.
  int get potentialBalls {
    final rings = def.rings.length;
    if (rings == 0) return hopper + phys.balls.length;
    final all = (1 << rings) - 1;
    var p = 0;
    for (final b in phys.balls) {
      var unused = 0;
      var m = all & ~b.ringMask;
      while (m != 0) {
        unused += m & 1;
        m >>= 1;
      }
      p += 1 << unused;
      if (p >= kPourBallCap) return kPourBallCap;
    }
    p += hopper * (1 << rings);
    return p > kPourBallCap ? kPourBallCap : p;
  }

  void _end(PourPhase p) {
    phase = p;
    _gateOpen = false;
    _finalScore = cupCount * pointsPerBall + (p == PourPhase.won ? levelBonus : 0);
  }

  // ---------------------------------------------------------------- debug
  /// Whether the ball is inside the cup's interior right now.
  bool inCup(PBall b) => b.x > cupLeftX && b.x < cupRightX && b.y > cupTop && b.y < cupBottomY;

  /// A compact, exact state fingerprint (for determinism tests).
  String debugSnapshot() {
    final sb = StringBuffer('t=${time.toStringAsFixed(4)} h=$hopper c=$cupCount l=$lost s=$splits|');
    for (final b in phys.balls) {
      sb
        ..write(b.id)
        ..write(':')
        ..write(b.x.toStringAsFixed(6))
        ..write(',')
        ..write(b.y.toStringAsFixed(6))
        ..write(';');
    }
    return sb.toString();
  }

  /// Drops a ball at an arbitrary point (debug/test helper).
  PBall? debugSpawn(double x, double y, {double vx = 0, double vy = 0}) =>
      phys.spawn(x, y, vx: vx, vy: vy, radius: ballRadius);
}
