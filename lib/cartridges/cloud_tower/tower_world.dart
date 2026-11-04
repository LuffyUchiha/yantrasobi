import 'dart:math' as math;

/// Horizontal axis a slab slides along.
enum SlideAxis { x, z }

/// Result of a single drop.
enum DropOutcome { perfect, slice, miss }

enum TowerEventKind { place, perfect, regrow, milestone, miss }

/// Something that happened since the renderer last drained [TowerWorld.events].
class TowerEvent {
  const TowerEvent(this.kind, this.level, {this.streak = 0});

  final TowerEventKind kind;

  /// Floor the event concerns.
  final int level;
  final int streak;
}

/// One placed (or moving) slab. Coordinates are in world units; [x] / [z]
/// are the centre, [w] the size along X and [d] the size along Z. A slab on
/// floor `level` spans heights `(level - 1) * slabHeight .. level * slabHeight`.
class Slab {
  Slab(this.x, this.z, this.w, this.d, this.level);

  double x, z, w, d;
  final int level;

  double centre(SlideAxis a) => a == SlideAxis.x ? x : z;
  double size(SlideAxis a) => a == SlideAxis.x ? w : d;

  void setCentre(SlideAxis a, double v) => a == SlideAxis.x ? x = v : z = v;
  void setSize(SlideAxis a, double v) => a == SlideAxis.x ? w = v : d = v;

  double get topY => level * TowerWorld.slabHeight;
}

/// A sliced-off overhang tumbling away under gravity.
class Debris {
  Debris(this.x, this.y, this.z, this.w, this.d, this.level, this.vx, this.vz, this.spin);

  double x, y, z;
  final double w, d;

  /// Floor it was cut from (drives its colour).
  final int level;
  double vx, vy = 0, vz;
  double rot = 0;
  final double spin;
  double age = 0;
}

/// Pure rules for Cloud Tower: an endless tap-timing stacking game.
///
/// A new slab slides over the top of the tower, alternating between the X and
/// Z axes. Dropping it keeps the overlap and slices the overhang off; no
/// overlap ends the run. Drops within [perfectTolerance] snap exactly and
/// build a streak; every [regrowEvery] perfects in a row grow the slab back a
/// little (never beyond [baseSize]). Simulation runs on a fixed timestep.
class TowerWorld {
  TowerWorld({this.seed = 1}) : _rng = math.Random(seed) {
    hueBase = _rng.nextDouble() * 360;
    slabs.add(Slab(0, 0, baseSize, baseSize, 0));
    _spawn();
  }

  static const double baseSize = 10;
  static const double slabHeight = 1;
  static const double perfectTolerance = 0.3;
  static const double regrowStep = 0.75;
  static const int regrowEvery = 4;
  static const double slideRange = 12;
  static const double baseSpeed = 8;
  static const double speedPerFloor = 0.1;
  static const double maxSpeed = 20;
  static const double step = 1 / 120;
  static const int milestoneEvery = 25;
  static const double gravity = 32;
  static const double debrisLife = 3.5;

  final int seed;
  final math.Random _rng;

  /// Starting hue of the procedural palette (degrees).
  late final double hueBase;

  /// Placed slabs; index 0 is the foundation (level 0).
  final List<Slab> slabs = [];
  final List<Debris> debris = [];
  final List<TowerEvent> events = [];

  Slab? _moving;
  SlideAxis _axis = SlideAxis.x;
  double _dir = 1;
  double _acc = 0;

  bool isOver = false;
  double time = 0;
  int perfects = 0;
  int streak = 0;
  int bestStreak = 0;
  int regrows = 0;
  int bonus = 0;
  int drops = 0;

  Slab? get moving => _moving;
  Slab get top => slabs.last;
  SlideAxis get axis => _axis;

  /// Direction the moving slab currently travels along [axis] (+1 / -1).
  double get direction => _dir;

  /// Floors stacked on the foundation.
  int get floors => slabs.length - 1;

  /// Height plus perfect bonuses.
  int get score => floors + bonus;

  int get entityCount => slabs.length + debris.length + (_moving == null ? 0 : 1);

  static double speedFor(int level) => math.min(maxSpeed, baseSpeed + speedPerFloor * (level - 1));

  /// Current slide speed in units per second.
  double get speed => speedFor(slabs.length);

  /// Bonus awarded for a perfect drop at the given streak length.
  static int perfectBonus(int streak) => math.min(streak, 5);

  /// Signed offset of the moving slab from the top slab along the slide axis.
  double get targetOffset {
    final m = _moving;
    if (m == null) return 0;
    return m.centre(_axis) - top.centre(_axis);
  }

  void _spawn() {
    final t = top;
    final level = slabs.length;
    _axis = level.isOdd ? SlideAxis.x : SlideAxis.z;
    _dir = _rng.nextBool() ? 1 : -1;
    final m = Slab(t.x, t.z, t.w, t.d, level);
    m.setCentre(_axis, t.centre(_axis) - _dir * slideRange);
    _moving = m;
  }

  void update(double dt) {
    if (dt <= 0) return;
    _acc += math.min(dt, 0.25);
    while (_acc >= step) {
      _acc -= step;
      _tick(step);
    }
    if (events.length > 64) events.removeRange(0, events.length - 64);
  }

  void _tick(double h) {
    time += h;
    final m = _moving;
    if (m != null && !isOver) {
      final c0 = top.centre(_axis);
      var p = m.centre(_axis) + _dir * speed * h;
      if (p > c0 + slideRange) {
        p = 2 * (c0 + slideRange) - p;
        _dir = -1;
      } else if (p < c0 - slideRange) {
        p = 2 * (c0 - slideRange) - p;
        _dir = 1;
      }
      m.setCentre(_axis, p);
    }
    for (var i = debris.length - 1; i >= 0; i--) {
      final b = debris[i];
      b.age += h;
      b.vy -= gravity * h;
      b.x += b.vx * h;
      b.z += b.vz * h;
      b.y += b.vy * h;
      b.rot += b.spin * h;
      if (b.age > debrisLife) debris.removeAt(i);
    }
  }

  void _addDebris(SlideAxis a, double centre, double size, Slab from, double out) {
    final b = Debris(
      a == SlideAxis.x ? centre : from.x,
      from.topY,
      a == SlideAxis.z ? centre : from.z,
      a == SlideAxis.x ? size : from.w,
      a == SlideAxis.z ? size : from.d,
      from.level,
      a == SlideAxis.x ? out * 2.5 : 0,
      a == SlideAxis.z ? out * 2.5 : 0,
      out * (a == SlideAxis.x ? 1.6 : -1.6),
    );
    debris.add(b);
  }

  /// Drops the moving slab. Returns null when nothing can be dropped.
  DropOutcome? drop() {
    final m = _moving;
    if (isOver || m == null) return null;
    drops++;
    final t = top;
    final c0 = t.centre(_axis);
    final s = t.size(_axis);
    final delta = m.centre(_axis) - c0;
    final dist = delta.abs();
    DropOutcome outcome;
    if (dist <= perfectTolerance) {
      outcome = DropOutcome.perfect;
      m.setCentre(_axis, c0);
      streak++;
      perfects++;
      bestStreak = math.max(bestStreak, streak);
      bonus += perfectBonus(streak);
      events.add(TowerEvent(TowerEventKind.perfect, m.level, streak: streak));
      if (streak % regrowEvery == 0 && (m.w < baseSize || m.d < baseSize)) {
        m.w = math.min(baseSize, m.w + regrowStep);
        m.d = math.min(baseSize, m.d + regrowStep);
        regrows++;
        events.add(TowerEvent(TowerEventKind.regrow, m.level, streak: streak));
      }
    } else if (dist >= s) {
      outcome = DropOutcome.miss;
      streak = 0;
      isOver = true;
      _moving = null;
      _addDebris(_axis, m.centre(_axis), s, m, delta.sign);
      events.add(TowerEvent(TowerEventKind.miss, m.level));
      return outcome;
    } else {
      outcome = DropOutcome.slice;
      streak = 0;
      final sign = delta.sign;
      final cut = dist;
      _addDebris(_axis, m.centre(_axis) + sign * (s - cut) / 2, cut, m, sign);
      m.setSize(_axis, s - cut);
      m.setCentre(_axis, c0 + delta / 2);
    }
    slabs.add(m);
    _moving = null;
    events.add(TowerEvent(TowerEventKind.place, m.level, streak: streak));
    if (m.level % milestoneEvery == 0) events.add(TowerEvent(TowerEventKind.milestone, m.level));
    _spawn();
    return outcome;
  }

  // ---------------------------------------------------------------- debug
  /// Moves the sliding slab so its centre sits [offset] from the top slab's
  /// centre along the current axis (tests only).
  void debugSetOffset(double offset) {
    final m = _moving;
    if (m == null) return;
    m.setCentre(_axis, top.centre(_axis) + offset);
  }

  /// Advances one fixed step at a time until the moving slab is within
  /// [window] of [offset] from the target (or [maxSteps] pass). Returns the
  /// number of steps taken.
  int debugWaitFor(double offset, {double window = 0.1, int maxSteps = 20000}) {
    var n = 0;
    while (n < maxSteps && !isOver && (targetOffset - offset).abs() > window) {
      update(step);
      n++;
    }
    return n;
  }

  String snapshot() => [
    for (final s in slabs)
      '${s.level}:${s.x.toStringAsFixed(3)},${s.z.toStringAsFixed(3)},'
          '${s.w.toStringAsFixed(3)},${s.d.toStringAsFixed(3)}',
    'score=$score streak=$streak over=$isOver',
  ].join(';');
}
