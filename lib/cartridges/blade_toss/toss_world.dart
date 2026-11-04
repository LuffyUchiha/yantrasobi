import 'dart:math' as math;

const double _tau = math.pi * 2;

/// Normalises [a] into `[0, 2*pi)`.
double normAngle(double a) {
  final r = a % _tau;
  return r < 0 ? r + _tau : r;
}

/// Smallest absolute difference between two angles, in `[0, pi]`.
double angleGap(double a, double b) {
  final d = normAngle(a - b);
  return d > math.pi ? _tau - d : d;
}

/// One piece of a motion script: angular speed ramps linearly from [from] to
/// [to] (rad/s) over [duration] seconds.
class MotionSegment {
  const MotionSegment(this.duration, this.from, this.to);

  final double duration;
  final double from;
  final double to;

  double speedAt(double t) => from + (to - from) * (t / duration);

  /// Angle travelled after [t] seconds into this segment.
  double angleAt(double t) => from * t + (to - from) * t * t / (2 * duration);

  double get netAngle => (from + to) * duration / 2;
}

/// A looping, declarative rotation pattern built from [MotionSegment]s.
class MotionScript {
  const MotionScript(this.name, this.segments);

  /// Spins at a steady [speed].
  factory MotionScript.constant(double speed) => MotionScript('constant', [MotionSegment(1, speed, speed)]);

  /// Speeds up then slows down again.
  factory MotionScript.swell(double s) =>
      MotionScript('swell', [MotionSegment(1.3, s * 0.35, s * 1.6), MotionSegment(1.3, s * 1.6, s * 0.35)]);

  /// Spins one way, briefly reverses, then swings back.
  factory MotionScript.reverse(double s) => MotionScript('reverse', [
    MotionSegment(1.6, s, s),
    MotionSegment(0.35, s, -s * 0.8),
    MotionSegment(0.9, -s * 0.8, -s * 0.8),
    MotionSegment(0.35, -s * 0.8, s),
  ]);

  /// Spins, brakes to a halt, pauses, and starts again.
  factory MotionScript.stopAndGo(double s) => MotionScript('stop-and-go', [
    MotionSegment(1.2, s * 1.25, s * 1.25),
    MotionSegment(0.25, s * 1.25, 0),
    const MotionSegment(0.45, 0, 0),
    MotionSegment(0.25, 0, s * 1.25),
  ]);

  /// Boss pattern: fast lunges with sharp reversals.
  factory MotionScript.lurch(double s) => MotionScript('lurch', [
    MotionSegment(0.8, s * 1.7, s * 1.7),
    MotionSegment(0.3, s * 1.7, -s),
    MotionSegment(0.8, -s, -s),
    MotionSegment(0.3, -s, s * 1.7),
  ]);

  /// Boss pattern: a heavy wheel that winds up and stutters.
  factory MotionScript.grind(double s) => MotionScript('grind', [
    MotionSegment(0.9, s * 0.3, s * 1.9),
    MotionSegment(0.2, s * 1.9, 0),
    const MotionSegment(0.3, 0, 0),
    MotionSegment(0.5, 0, -s * 0.9),
    MotionSegment(0.4, -s * 0.9, s * 0.3),
  ]);

  final String name;
  final List<MotionSegment> segments;

  double get period => segments.fold(0.0, (a, s) => a + s.duration);

  /// Net rotation over one full period. Non-zero means every angle of the
  /// target eventually passes under the throw point.
  double get netAngle => segments.fold(0.0, (a, s) => a + s.netAngle);

  /// A copy with every speed multiplied by [k] (e.g. -1 to flip direction).
  MotionScript scaled(double k) =>
      MotionScript(name, [for (final s in segments) MotionSegment(s.duration, s.from * k, s.to * k)]);

  /// Total rotation after [t] seconds (unbounded, not normalised).
  double angleAt(double t) {
    final p = period;
    final cycles = (t / p).floor();
    var rest = t - cycles * p;
    var a = cycles * netAngle;
    for (final s in segments) {
      if (rest <= s.duration) return a + s.angleAt(rest);
      a += s.netAngle;
      rest -= s.duration;
    }
    return a;
  }

  double speedAt(double t) {
    var rest = t - (t / period).floor() * period;
    for (final s in segments) {
      if (rest <= s.duration) return s.speedAt(rest);
      rest -= s.duration;
    }
    return segments.last.to;
  }
}

enum TargetShape { disc, gear, shield }

/// Everything needed to play one stage.
class StagePlan {
  const StagePlan({
    required this.stage,
    required this.blades,
    required this.script,
    this.obstacles = const [],
    this.gems = const [],
    this.shape = TargetShape.disc,
  });

  final int stage;
  final int blades;
  final MotionScript script;

  /// Relative angles of pre-placed obstacle blades.
  final List<double> obstacles;

  /// Relative angles of gems on the rim.
  final List<double> gems;
  final TargetShape shape;

  bool get isBoss => TossWorld.isBossStage(stage);
}

class StuckBlade {
  StuckBlade(this.rel, {this.obstacle = false});
  final double rel;
  final bool obstacle;
}

class Gem {
  Gem(this.rel);
  final double rel;
  bool taken = false;
}

enum TossPhase { ready, flying, clearing, lost }

enum TossEventKind { stick, gem, fail, stageClear, bossShatter, stageStart }

class TossEvent {
  const TossEvent(this.kind, this.rel);
  final TossEventKind kind;

  /// Relative angle on the target (where meaningful).
  final double rel;
}

/// Pure rules for Blade Toss: throw blades into a rotating target.
///
/// Angles are radians in screen orientation (x = cos, y = sin, y pointing
/// down), so [impactAngle] (pi/2) is the bottom of the target, where every
/// thrown blade lands. Items on the target (stuck blades, obstacle blades,
/// gems) are stored as angles *relative to the target*; their on-screen angle
/// is `rel + rotation`. Deterministic: fixed 1/120 s steps, seeded stages.
class TossWorld {
  TossWorld({required this.seed, int startStage = 1}) : _custom = false {
    _load(planFor(seed, startStage));
  }

  /// A world that plays exactly [plan] (and stops progressing after it).
  TossWorld.custom(StagePlan plan) : seed = 0, _custom = true {
    _load(plan);
  }

  final int seed;
  final bool _custom;

  static const double step = 1 / 120;
  static const int flightTicks = 12; // 0.1 s
  static const int clearTicks = 108; // 0.9 s
  static const double impactAngle = math.pi / 2;

  /// Two blades closer than this (radians) collide.
  static const double collisionWidth = 0.16;

  /// A blade landing within this of a gem collects it.
  static const double gemWidth = 0.2;

  static const int maxBlades = 10;
  static const int maxObstacles = 4;
  static const int gemValue = 25;

  /// Stage generation keeps at least this much of the circle free even when
  /// the final blade is thrown, so a safe window always exists.
  static const double minFreeArc = 1.6;

  static bool isBossStage(int stage) => stage % 5 == 0;

  static double baseSpeed(int stage) => math.min(1.9 + 0.11 * (stage - 1), 4.0);

  static int bladesFor(int stage) => math.min(maxBlades, 5 + (stage - 1) ~/ 2 + (isBossStage(stage) ? 1 : 0));

  static int obstaclesFor(int stage) => isBossStage(stage) ? 1 : math.min(maxObstacles, (stage - 1) ~/ 2);

  /// Deterministic plan for [stage] of the run seeded with [seed].
  static StagePlan planFor(int seed, int stage) {
    final rng = math.Random((seed * 7919 + stage * 104729) & 0x7fffffff);
    final boss = isBossStage(stage);
    final s = baseSpeed(stage);
    final MotionScript script;
    if (boss) {
      script = (stage ~/ 5).isOdd ? MotionScript.lurch(s) : MotionScript.grind(s);
    } else if (stage == 1) {
      script = MotionScript.constant(s);
    } else {
      final pool = stage < 4 ? 2 : (stage < 7 ? 3 : 4);
      script = switch (rng.nextInt(pool)) {
        0 => MotionScript.constant(s * 1.1),
        1 => MotionScript.swell(s),
        2 => MotionScript.stopAndGo(s),
        _ => MotionScript.reverse(s),
      };
    }
    final dir = rng.nextBool() ? 1.0 : -1.0;

    final blades = bladesFor(stage);
    final nObs = obstaclesFor(stage);
    final offset = rng.nextDouble() * _tau;
    final obstacles = <double>[];
    var tries = 0;
    while (obstacles.length < nObs && tries < 200) {
      tries++;
      // Keep obstacles well away from the throw point at the start.
      final a = normAngle(offset + rng.nextDouble() * _tau);
      if (angleGap(a, impactAngle) < 0.6) continue;
      if (obstacles.every((o) => angleGap(o, a) >= collisionWidth * 2.5)) obstacles.add(a);
    }
    final gems = <double>[];
    final nGems = boss ? 3 : (rng.nextDouble() < 0.6 ? 1 + rng.nextInt(2) : 0);
    tries = 0;
    while (gems.length < nGems && tries < 200) {
      tries++;
      final a = rng.nextDouble() * _tau;
      if (obstacles.any((o) => angleGap(o, a) < collisionWidth + gemWidth)) continue;
      if (gems.any((g) => angleGap(g, a) < gemWidth * 2)) continue;
      gems.add(a);
    }
    final shape = boss ? ((stage ~/ 5).isOdd ? TargetShape.gear : TargetShape.shield) : TargetShape.disc;
    return StagePlan(
      stage: stage,
      blades: blades,
      script: script.scaled(dir),
      obstacles: obstacles,
      gems: gems,
      shape: shape,
    );
  }

  // ------------------------------------------------------------------ state
  late StagePlan plan;
  TossPhase phase = TossPhase.ready;
  final List<StuckBlade> stuck = [];
  final List<Gem> gems = [];
  final List<TossEvent> events = [];

  int stage = 1;
  int bladesLeft = 0;
  int bladesStuck = 0; // whole run
  int gemsCollected = 0;
  int stagesCleared = 0;
  int bossesCleared = 0;
  int throws = 0;

  /// Relative angle of the blade we collided with (when lost).
  double? failRel;

  int _stageTicks = 0;
  int _flightTicks = 0;
  int _clearTicks = 0;
  int _runTicks = 0;
  double _acc = 0;

  bool get isOver => phase == TossPhase.lost;
  bool get isBoss => plan.isBoss;
  double get stageTime => _stageTicks * step;
  double get time => _runTicks * step;

  /// Current target rotation (radians, unbounded).
  double get rotation => plan.script.angleAt(stageTime);
  double get angularSpeed => plan.script.speedAt(stageTime);

  /// 0..1 progress of the blade in flight.
  double get flightProgress => phase == TossPhase.flying ? 1 - _flightTicks / flightTicks : 0;

  /// 0..1 progress of the stage-clear pause.
  double get clearProgress => phase == TossPhase.clearing ? 1 - _clearTicks / clearTicks : 0;

  int get score => stage * 100 + bladesStuck + gemsCollected * gemValue;

  int get entityCount =>
      stuck.length + gems.where((g) => !g.taken).length + (phase == TossPhase.flying ? 1 : 0) + 1;

  void _load(StagePlan p) {
    plan = p;
    stage = p.stage;
    stuck
      ..clear()
      ..addAll([for (final o in p.obstacles) StuckBlade(normAngle(o), obstacle: true)]);
    gems
      ..clear()
      ..addAll([for (final g in p.gems) Gem(normAngle(g))]);
    bladesLeft = p.blades;
    _stageTicks = 0;
    _flightTicks = 0;
    phase = TossPhase.ready;
    events.add(const TossEvent(TossEventKind.stageStart, 0));
  }

  /// Relative angle a blade would stick at if it hit the target right now.
  double relAtRotation(double rot) => normAngle(impactAngle - rot);

  /// Where a blade thrown now would land (relative angle).
  double predictImpactRel() => relAtRotation(plan.script.angleAt((_stageTicks + flightTicks) * step));

  /// Whether a blade landing at [rel] would stick without colliding.
  bool isSafeRel(double rel, {double margin = 0}) =>
      stuck.every((b) => angleGap(b.rel, rel) >= collisionWidth + margin);

  bool get canThrow => phase == TossPhase.ready && bladesLeft > 0;

  /// Throws a blade. Returns false if no throw is possible right now.
  bool throwBlade() {
    if (!canThrow) return false;
    phase = TossPhase.flying;
    _flightTicks = flightTicks;
    bladesLeft--;
    throws++;
    return true;
  }

  void update(double dt) {
    if (isOver) return;
    _acc += dt;
    while (_acc >= step - 1e-9) {
      _acc -= step;
      _tick();
      if (isOver) {
        _acc = 0;
        return;
      }
    }
  }

  void _tick() {
    _runTicks++;
    if (phase == TossPhase.clearing) {
      _clearTicks--;
      if (_clearTicks <= 0) {
        if (_custom) {
          _clearTicks = 0;
        } else {
          _load(planFor(seed, stage + 1));
        }
      }
      return;
    }
    _stageTicks++;
    if (phase == TossPhase.flying) {
      _flightTicks--;
      if (_flightTicks <= 0) _resolve();
    }
  }

  void _resolve() {
    final rel = relAtRotation(rotation);
    for (final b in stuck) {
      if (angleGap(b.rel, rel) < collisionWidth) {
        failRel = b.rel;
        phase = TossPhase.lost;
        events.add(TossEvent(TossEventKind.fail, rel));
        return;
      }
    }
    stuck.add(StuckBlade(rel));
    bladesStuck++;
    events.add(TossEvent(TossEventKind.stick, rel));
    for (final g in gems) {
      if (!g.taken && angleGap(g.rel, rel) < gemWidth) {
        g.taken = true;
        gemsCollected++;
        events.add(TossEvent(TossEventKind.gem, g.rel));
      }
    }
    if (bladesLeft <= 0) {
      phase = TossPhase.clearing;
      _clearTicks = clearTicks;
      stagesCleared++;
      if (isBoss) bossesCleared++;
      events.add(TossEvent(isBoss ? TossEventKind.bossShatter : TossEventKind.stageClear, rel));
    } else {
      phase = TossPhase.ready;
    }
  }

  // ------------------------------------------------------------ debug/test
  /// Total arc (radians) of the circle where a blade could still land safely.
  double freeArc({int samples = 720}) {
    var free = 0;
    for (var i = 0; i < samples; i++) {
      if (isSafeRel(i * _tau / samples)) free++;
    }
    return free * _tau / samples;
  }

  /// Advances the stage clock without throwing (test helper).
  void debugAdvanceTicks(int ticks) {
    for (var i = 0; i < ticks && !isOver; i++) {
      _tick();
    }
  }
}
