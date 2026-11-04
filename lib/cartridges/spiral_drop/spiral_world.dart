import 'dart:math' as math;

/// Pure-Dart rules for Spiral Drop (helix-tower descent).
///
/// A ball bounces at a fixed spot in front of a central pillar. Rings of
/// segments surround the pillar; the player rotates the tower so the ball
/// falls through gaps. Landing on a hazard segment ends the run, unless the
/// ball is in "blaze" mode (3+ rings fallen without a bounce), which smashes
/// whatever it lands on.

enum SegKind { solid, gap, hazard }

enum SpiralPhase { playing, won, lost }

enum SpiralEventKind { bounce, pass, smash, hazard, finish }

class SpiralEvent {
  const SpiralEvent(this.kind, this.ring, [this.combo = 0]);
  final SpiralEventKind kind;
  final int ring;
  final int combo;
}

class Ring {
  Ring(this.index, this.y, this.segments, {this.finish = false});
  final int index;
  final double y;
  final List<SegKind> segments;
  final bool finish;
  bool passed = false;
  bool smashed = false;
}

class SpiralWorld {
  SpiralWorld({this.level = 1, int seed = 1}) : _rng = math.Random(seed) {
    _build();
  }

  static const int segmentsPerRing = 12;
  static const double spacing = 3.2;
  static const double ringThickness = 0.35;
  static const double innerRadius = 0.75;
  static const double outerRadius = 2.3;
  static const double ballRadius = 0.3;

  /// Ball orbit radius (where it bounces, measured from the pillar axis).
  static const double ballOrbit = 1.55;
  static const double gravity = -30;
  static const double bounceSpeed = 10.5;
  static const int blazeCombo = 3;

  final int level;
  final math.Random _rng;
  final List<Ring> rings = [];
  final List<SpiralEvent> events = [];

  SpiralPhase phase = SpiralPhase.playing;
  double ballY = 0;
  double ballVy = 0;

  /// Tower rotation in radians (positive = counter-clockwise seen from above).
  double towerAngle = 0;
  int combo = 0;
  int score = 0;
  int ringsPassed = 0;
  int smashes = 0;
  double time = 0;
  int _next = 0;

  int get ringCount => rings.length - 1; // excluding finish platform
  bool get isOver => phase != SpiralPhase.playing;
  bool get blazing => combo >= blazeCombo;
  double get progress => ringsPassed / ringCount;
  Ring? get nextRing => _next < rings.length ? rings[_next] : null;
  int get entityCount => rings.where((r) => !r.passed).length * segmentsPerRing + 1;

  static double segmentArc = 2 * math.pi / segmentsPerRing;

  void _build() {
    final count = 10 + 2 * level;
    for (var i = 0; i < count; i++) {
      final segs = List<SegKind>.filled(segmentsPerRing, SegKind.solid);
      final gapLen = math.max(1, 3 - level ~/ 3 - (_rng.nextDouble() < 0.3 ? 1 : 0));
      // First ring: keep the starting spot (segment 0) solid.
      final start = i == 0 ? 3 + _rng.nextInt(6) : _rng.nextInt(segmentsPerRing);
      for (var k = 0; k < gapLen; k++) {
        segs[(start + k) % segmentsPerRing] = SegKind.gap;
      }
      final hazards = i == 0 ? 0 : math.min(5, (level - 1) + i ~/ 4);
      var placed = 0, guard = 0;
      while (placed < hazards && guard++ < 50) {
        final s = _rng.nextInt(segmentsPerRing);
        // Never put hazards right next to the gap so each ring stays fair.
        final nearGap =
            segs[(s + 1) % segmentsPerRing] == SegKind.gap ||
            segs[(s - 1 + segmentsPerRing) % segmentsPerRing] == SegKind.gap;
        if (segs[s] == SegKind.solid && !nearGap) {
          segs[s] = SegKind.hazard;
          placed++;
        }
      }
      rings.add(Ring(i, -(i + 1) * spacing, segs));
    }
    rings.add(
      Ring(count, -(count + 1) * spacing, List<SegKind>.filled(segmentsPerRing, SegKind.solid), finish: true),
    );
    ballY = rings.first.y + ringThickness / 2 + ballRadius + 1.2;
  }

  /// Segment of [ring] currently under the ball (the ball sits at world angle 0).
  int segmentUnderBall() {
    final local = _wrap(-towerAngle);
    return (local / segmentArc).floor() % segmentsPerRing;
  }

  static double _wrap(double a) {
    final t = a % (2 * math.pi);
    return t < 0 ? t + 2 * math.pi : t;
  }

  void rotate(double radians) {
    if (isOver) return;
    towerAngle += radians;
  }

  void update(double dt) {
    events.clear();
    if (isOver) return;
    var remaining = math.min(dt, 0.2);
    while (remaining > 1e-9 && !isOver) {
      final step = math.min(remaining, 1 / 120);
      _step(step);
      remaining -= step;
    }
  }

  void _step(double dt) {
    time += dt;
    final prevY = ballY;
    ballVy += gravity * dt;
    ballY += ballVy * dt;
    final ring = nextRing;
    if (ring == null) return;
    final top = ring.y + ringThickness / 2 + ballRadius;
    if (!(prevY > top && ballY <= top) || ballVy > 0) return;
    if (ring.finish) {
      _bounce(top);
      phase = SpiralPhase.won;
      score += 50 * level;
      events.add(SpiralEvent(SpiralEventKind.finish, ring.index, combo));
      return;
    }
    final seg = ring.segments[segmentUnderBall()];
    if (seg == SegKind.gap) {
      ring.passed = true;
      _next++;
      combo++;
      ringsPassed++;
      score += combo;
      events.add(SpiralEvent(SpiralEventKind.pass, ring.index, combo));
      return;
    }
    if (blazing) {
      ring
        ..passed = true
        ..smashed = true;
      _next++;
      ringsPassed++;
      smashes++;
      score += combo * 2;
      events.add(SpiralEvent(SpiralEventKind.smash, ring.index, combo));
      combo = 0;
      _bounce(top);
      return;
    }
    if (seg == SegKind.hazard) {
      ballY = top;
      ballVy = 0;
      phase = SpiralPhase.lost;
      events.add(SpiralEvent(SpiralEventKind.hazard, ring.index, combo));
      return;
    }
    combo = 0;
    _bounce(top);
    events.add(SpiralEvent(SpiralEventKind.bounce, ring.index));
  }

  void _bounce(double top) {
    ballY = top;
    ballVy = bounceSpeed;
  }

  /// Rotates the tower so the ball sits over segment [segment] of [ring]'s frame.
  void debugAlignToSegment(int segment) => towerAngle = -(segment + 0.5) * segmentArc;

  /// Index of the first segment of [kind] in [ring], or -1.
  static int findSegment(Ring ring, SegKind kind) => ring.segments.indexOf(kind);
}
