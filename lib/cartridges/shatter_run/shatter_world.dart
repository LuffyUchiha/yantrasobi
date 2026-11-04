import 'dart:math' as math;

/// Pure-Dart rules for Shatter Run: glide down a corridor and throw metal
/// balls to break glass before you crash into it. Balls are your life.
///
/// Axes: x across (−[halfWidth]..+[halfWidth]), y up (0..[height]), z forward.

enum ShatterEventKind { throwBall, shatter, crystal, crash, bounce, checkpoint }

class ShatterEvent {
  const ShatterEvent(this.kind, this.x, this.y, this.z, [this.amount = 0]);
  final ShatterEventKind kind;
  final double x, y, z;
  final int amount;
}

/// A rectangular obstacle in the x-y plane at depth [z].
class Pane {
  Pane({
    required this.z,
    required this.x0,
    required this.x1,
    required this.y0,
    required this.y1,
    this.solid = false,
    this.slide = 0,
    this.phase = 0,
  });
  final double z;
  final double x0, x1, y0, y1;

  /// Solid frames cannot be broken; balls bounce off them.
  final bool solid;

  /// Sideways oscillation amplitude (0 = static).
  final double slide;
  final double phase;
  bool broken = false;
  double offset = 0;

  bool contains(double x, double y) => x >= x0 + offset && x <= x1 + offset && y >= y0 && y <= y1;
}

class Crystal {
  Crystal(this.x, this.y, this.z);
  final double x, y, z;
  bool taken = false;
}

class Ball {
  double x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0;
  bool alive = false;
  double life = 0;
}

class ShatterWorld {
  ShatterWorld({int seed = 1}) : _rng = math.Random(seed) {
    for (var i = 0; i < ballPoolSize; i++) {
      balls.add(Ball());
    }
    _generateUntil(120);
  }

  static const double halfWidth = 3;
  static const double height = 4.5;
  static const double eyeY = 1.6;
  static const double ballSpeed = 34;
  static const double gravity = -9.8;
  static const double ballRadius = 0.18;
  static const int ballPoolSize = 24;
  static const int startBalls = 25;
  static const int crashPenalty = 10;

  final math.Random _rng;
  final List<Pane> panes = [];
  final List<Crystal> crystals = [];
  final List<Ball> balls = [];
  final List<ShatterEvent> events = [];

  double z = 0;
  double time = 0;
  int ammo = startBalls;
  int shattered = 0;
  int crashes = 0;
  int crystalsTaken = 0;
  bool over = false;
  double _generatedTo = 10;
  int _nextCheckpoint = 100;

  double get speed => math.min(16, 7 + z / 120);
  bool get isOver => over;
  int get score => z.round() + shattered * 5 + crystalsTaken * 10;
  int get entityCount =>
      panes.where((p) => !p.broken).length +
      crystals.where((c) => !c.taken).length +
      balls.where((b) => b.alive).length;

  void _generateUntil(double until) {
    while (_generatedTo < until) {
      final z0 = _generatedTo + 9 + _rng.nextDouble() * 5;
      final roll = _rng.nextDouble();
      final difficulty = math.min(1.0, z0 / 600);
      if (roll < 0.35) {
        // Full-width glass wall: must be broken.
        panes.add(Pane(z: z0, x0: -halfWidth, x1: halfWidth, y0: 0, y1: height));
      } else if (roll < 0.6) {
        // Glass door in a solid frame.
        // The door always spans the flight line (x = 0): the camera cannot steer.
        final doorX = (_rng.nextDouble() * 2 - 1) * 0.6;
        panes
          ..add(Pane(z: z0, x0: -halfWidth, x1: doorX - 0.9, y0: 0, y1: height, solid: true))
          ..add(Pane(z: z0, x0: doorX + 0.9, x1: halfWidth, y0: 0, y1: height, solid: true))
          ..add(Pane(z: z0, x0: doorX - 0.9, x1: doorX + 0.9, y0: 0, y1: height));
      } else if (roll < 0.8) {
        // Sliding glass panels.
        final w = 1.6 + _rng.nextDouble();
        panes.add(
          Pane(
            z: z0,
            x0: -w / 2,
            x1: w / 2,
            y0: 0.4,
            y1: 3.2,
            slide: 1.2 + difficulty * 1.2,
            phase: _rng.nextDouble() * 6,
          ),
        );
      } else {
        // Stacked glass bars across the corridor.
        for (var k = 0; k < 2; k++) {
          panes.add(
            Pane(z: z0 + k * 1.5, x0: -halfWidth, x1: halfWidth, y0: 1.0 + k * 0.4, y1: 2.6 + k * 0.4),
          );
        }
      }
      if (_rng.nextDouble() < 0.7) {
        crystals.add(
          Crystal(
            (_rng.nextDouble() * 2 - 1) * 2.2,
            0.8 + _rng.nextDouble() * 2.2,
            z0 - 4 - _rng.nextDouble() * 3,
          ),
        );
      }
      _generatedTo = z0;
    }
  }

  /// Throws a ball from the camera along the unit direction (dx, dy, dz).
  bool throwBall(double dx, double dy, double dz) {
    if (over || ammo <= 0) return false;
    final b = balls.firstWhere((b) => !b.alive, orElse: () => balls.first);
    ammo--;
    b
      ..alive = true
      ..life = 3
      ..x = 0
      ..y = eyeY - 0.2
      ..z = z + 0.5
      ..vx = dx * ballSpeed
      ..vy = dy * ballSpeed + 1.5
      ..vz = dz * ballSpeed + speed;
    events.add(ShatterEvent(ShatterEventKind.throwBall, b.x, b.y, b.z));
    return true;
  }

  void update(double dt) {
    events.clear();
    if (over) return;
    var remaining = math.min(dt, 0.2);
    while (remaining > 1e-9 && !over) {
      final step = math.min(remaining, 1 / 120);
      _step(step);
      remaining -= step;
    }
  }

  void _step(double dt) {
    time += dt;
    final prevZ = z;
    z += speed * dt;
    _generateUntil(z + 120);
    for (final p in panes) {
      if (p.slide != 0) p.offset = math.sin(time * 1.4 + p.phase) * p.slide;
    }
    _moveBalls(dt);
    // Camera vs panes.
    for (final p in panes) {
      if (p.broken || p.z <= prevZ || p.z > z) continue;
      if (p.contains(0, eyeY)) {
        crashes++;
        p.broken = true;
        ammo -= crashPenalty;
        events.add(ShatterEvent(ShatterEventKind.crash, 0, eyeY, p.z, crashPenalty));
        if (ammo < 0) {
          ammo = 0;
          over = true;
          return;
        }
      }
    }
    // Camera collects crystals it flies through.
    for (final c in crystals) {
      if (c.taken || c.z <= prevZ || c.z > z) continue;
      if ((c.x).abs() < 0.8 && (c.y - eyeY).abs() < 0.8) _takeCrystal(c);
    }
    if (z >= _nextCheckpoint) {
      _nextCheckpoint += 100;
      ammo += 5;
      events.add(ShatterEvent(ShatterEventKind.checkpoint, 0, eyeY, z, 5));
    }
    if (ammo <= 0 && balls.every((b) => !b.alive)) {
      // Out of balls with nothing in flight: the next pane would end it, so
      // end now to avoid an unwinnable drift.
      over = true;
    }
    panes.removeWhere((p) => p.z < z - 5);
    crystals.removeWhere((c) => c.z < z - 5);
  }

  void _takeCrystal(Crystal c) {
    c.taken = true;
    crystalsTaken++;
    ammo += 3;
    events.add(ShatterEvent(ShatterEventKind.crystal, c.x, c.y, c.z, 3));
  }

  void _moveBalls(double dt) {
    for (final b in balls) {
      if (!b.alive) continue;
      final pz = b.z;
      b.vy += gravity * dt;
      b.x += b.vx * dt;
      b.y += b.vy * dt;
      b.z += b.vz * dt;
      b.life -= dt;
      if (b.x.abs() > halfWidth - ballRadius) {
        b.x = b.x.sign * (halfWidth - ballRadius);
        b.vx = -b.vx * 0.6;
      }
      if (b.y < ballRadius) {
        b.y = ballRadius;
        b.vy = -b.vy * 0.5;
      }
      if (b.y > height - ballRadius) {
        b.y = height - ballRadius;
        b.vy = -b.vy * 0.5;
      }
      for (final p in panes) {
        if (p.broken || p.z <= pz || p.z > b.z) continue;
        if (!p.contains(b.x, b.y)) continue;
        if (p.solid) {
          b.z = p.z - 0.01;
          b.vz = -b.vz * 0.3;
          events.add(ShatterEvent(ShatterEventKind.bounce, b.x, b.y, p.z));
        } else {
          p.broken = true;
          shattered++;
          b.vz *= 0.85;
          events.add(ShatterEvent(ShatterEventKind.shatter, b.x, b.y, p.z));
        }
      }
      for (final c in crystals) {
        if (c.taken) continue;
        final dx = c.x - b.x, dy = c.y - b.y, dz = c.z - b.z;
        if (dx * dx + dy * dy + dz * dz < 0.6 * 0.6) _takeCrystal(c);
      }
      if (b.life <= 0 || b.z > z + 90) b.alive = false;
    }
  }

  // --- helpers for tests and bots ---
  /// The nearest unbroken glass pane ahead that blocks the camera path.
  Pane? nextBlockingGlass() {
    Pane? best;
    for (final p in panes) {
      if (p.broken || p.solid || p.z <= z) continue;
      if (!p.contains(0, eyeY) && p.slide == 0) continue;
      if (best == null || p.z < best.z) best = p;
    }
    return best;
  }

  /// The nearest untaken crystal ahead within [range] metres.
  Crystal? nextCrystal(double range) {
    Crystal? best;
    for (final c in crystals) {
      if (c.taken || c.z <= z + 3 || c.z - z > range) continue;
      if (best == null || c.z < best.z) best = c;
    }
    return best;
  }

  void debugClear() {
    panes.clear();
    crystals.clear();
    _generatedTo = 1e9;
  }
}
