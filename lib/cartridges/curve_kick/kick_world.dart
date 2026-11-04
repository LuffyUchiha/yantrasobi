import 'dart:math' as math;

import 'kick_levels.dart';

/// Pure-Dart rules for Curve Kick: draw the ball's path with your finger.
/// Pass to team-mates around defenders, then bend a shot past the keeper.

enum KickPhase { aiming, flying, won, lost }

enum KickEventKind { pass, intercepted, saved, wide, loose, goal, attemptLost }

class KickEvent {
  const KickEvent(this.kind, this.x, this.y);
  final KickEventKind kind;
  final double x;
  final double y;
}

class Pt {
  const Pt(this.x, this.y);
  final double x;
  final double y;
  double dist(Pt o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
}

class KickWorld {
  KickWorld({this.levelNumber = 1})
    : def = kKickLevels[(math.max(1, levelNumber) - 1) % kKickLevels.length],
      loop = (math.max(1, levelNumber) - 1) ~/ kKickLevels.length {
    attemptsLeft = def.attempts;
    _resetAttempt();
  }

  static const double ballSpeed = 20;
  static const double maxPathLength = 42;
  static const double grabRadius = 4;
  static const double receiveRadius = 1.8;
  static const double interceptRadius = 0.9;
  static const double keeperReach = 1.15;

  final int levelNumber;
  final KickLevel def;

  /// Completed passes through the level list (harder keepers each loop).
  final int loop;
  final List<KickEvent> events = [];
  final List<Pt> path = [];

  KickPhase phase = KickPhase.aiming;
  int attemptsLeft = 0;
  int passes = 0;
  double time = 0;
  Pt holder = const Pt(0, 0);

  /// Index of the mate currently holding the ball (-1 = starting player).
  int holderIndex = -1;
  Pt ball = const Pt(0, 0);
  double keeperX = kPitchWidth / 2;
  double _travel = 0;
  double _pathLength = 0;
  bool _drawing = false;

  bool get isOver => phase == KickPhase.won || phase == KickPhase.lost;
  bool get drawing => _drawing;
  double get pathLength => _pathLength;
  double get keeperSpeed => def.keeperSpeed + loop * 0.8;
  int get entityCount => 2 + def.mates.length + def.defenders.length + path.length;

  int get score =>
      phase == KickPhase.won ? 1000 + attemptsLeft * 300 + passes * 100 + loop * 500 : passes * 100;

  List<Pt> get mates => [for (final m in def.mates) Pt(m.$1, m.$2)];

  /// Defender position at the current time (patrols oscillate sinusoidally).
  Pt defenderAt(int i) {
    final d = def.defenders[i];
    final p = d.patrol;
    if (p == null) return Pt(d.x, d.y);
    final s = math.sin(time * 2 * math.pi / p.period);
    return Pt(d.x + p.dx * s, d.y + p.dy * s);
  }

  void _resetAttempt() {
    holder = Pt(def.holder.$1, def.holder.$2);
    holderIndex = -1;
    ball = holder;
    keeperX = kPitchWidth / 2;
    path.clear();
    _pathLength = 0;
    _travel = 0;
    _drawing = false;
    phase = KickPhase.aiming;
  }

  // -------------------------------------------------------------- drawing
  /// Starts drawing if the touch is near the ball holder.
  bool beginPath(double x, double y) {
    if (phase != KickPhase.aiming) return false;
    if (Pt(x, y).dist(holder) > grabRadius) return false;
    path
      ..clear()
      ..add(holder);
    _pathLength = 0;
    _drawing = true;
    return true;
  }

  void extendPath(double x, double y) {
    if (!_drawing) return;
    final p = Pt(x.clamp(0, kPitchWidth), y.clamp(-2, kPitchLength));
    final last = path.last;
    final d = p.dist(last);
    if (d < 0.5) return;
    if (_pathLength + d > maxPathLength) {
      // Clip the final point to the remaining budget.
      final remain = maxPathLength - _pathLength;
      if (remain <= 0.05) return;
      final t = remain / d;
      path.add(Pt(last.x + (p.x - last.x) * t, last.y + (p.y - last.y) * t));
      _pathLength = maxPathLength;
      return;
    }
    path.add(p);
    _pathLength += d;
  }

  /// Releases the drawn path; a too-short path is cancelled.
  void releasePath() {
    if (!_drawing) return;
    _drawing = false;
    if (_pathLength < 2) {
      path.clear();
      _pathLength = 0;
      return;
    }
    _travel = 0;
    phase = KickPhase.flying;
  }

  Pt _pointAt(double s) {
    var acc = 0.0;
    for (var i = 1; i < path.length; i++) {
      final seg = path[i].dist(path[i - 1]);
      if (acc + seg >= s) {
        final t = seg == 0 ? 0.0 : (s - acc) / seg;
        return Pt(
          path[i - 1].x + (path[i].x - path[i - 1].x) * t,
          path[i - 1].y + (path[i].y - path[i - 1].y) * t,
        );
      }
      acc += seg;
    }
    return path.last;
  }

  // -------------------------------------------------------------- simulation
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
    if (phase != KickPhase.flying) {
      // Keeper drifts back to the centre between attempts.
      keeperX += (kPitchWidth / 2 - keeperX).clamp(-keeperSpeed * dt, keeperSpeed * dt);
      return;
    }
    final prev = ball;
    _travel += ballSpeed * dt;
    ball = _pointAt(_travel);
    // Keeper tracks the ball once it is close to goal.
    if (ball.y < 16) {
      final target = ball.x.clamp(kPitchWidth / 2 - kGoalWidth / 2, kPitchWidth / 2 + kGoalWidth / 2);
      keeperX += (target - keeperX).clamp(-keeperSpeed * dt, keeperSpeed * dt);
    }
    for (var i = 0; i < def.defenders.length; i++) {
      if (defenderAt(i).dist(ball) < interceptRadius) {
        _fail(KickEventKind.intercepted);
        return;
      }
    }
    if (prev.y > 0 && ball.y <= 0) {
      final inGoal = (ball.x - kPitchWidth / 2).abs() < kGoalWidth / 2;
      if (!inGoal) {
        _fail(KickEventKind.wide);
      } else if ((ball.x - keeperX).abs() < keeperReach) {
        _fail(KickEventKind.saved);
      } else {
        phase = KickPhase.won;
        events.add(KickEvent(KickEventKind.goal, ball.x, ball.y));
      }
      return;
    }
    if (_travel >= _pathLength) {
      final end = path.last;
      final ms = mates;
      for (var i = 0; i < ms.length; i++) {
        if (i == holderIndex) continue;
        if (ms[i].dist(end) < receiveRadius) {
          passes++;
          holderIndex = i;
          holder = ms[i];
          ball = holder;
          path.clear();
          _pathLength = 0;
          phase = KickPhase.aiming;
          events.add(KickEvent(KickEventKind.pass, holder.x, holder.y));
          return;
        }
      }
      _fail(KickEventKind.loose);
    }
  }

  void _fail(KickEventKind why) {
    events
      ..add(KickEvent(why, ball.x, ball.y))
      ..add(KickEvent(KickEventKind.attemptLost, ball.x, ball.y));
    attemptsLeft--;
    if (attemptsLeft <= 0) {
      phase = KickPhase.lost;
      return;
    }
    _resetAttempt();
  }

  // -------------------------------------------------------------- helpers
  /// Draws a straight path through [points] (tests and bots).
  void debugDrawPath(List<Pt> points) {
    beginPath(holder.x, holder.y);
    for (final p in points) {
      // Subdivide so long straight segments respect the 0.5 m spacing.
      final last = path.last;
      final n = math.max(1, (p.dist(last) / 0.5).ceil());
      for (var k = 1; k <= n; k++) {
        extendPath(last.x + (p.x - last.x) * k / n, last.y + (p.y - last.y) * k / n);
      }
    }
    releasePath();
  }

  void runUntilSettled() {
    for (var i = 0; i < 2000 && phase == KickPhase.flying; i++) {
      update(1 / 60);
    }
  }
}
