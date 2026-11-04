import 'dart:math' as math;

/// Pure-Dart rules for Roll Ridge: steer a rolling ball down a winding sky
/// track, jump gaps off ramps, dodge sweepers and pushers, reach the finish.
///
/// The track runs along +z. Each [TrackSegment] spans `length` metres and has a
/// centre-line offset that interpolates from the previous segment, a width,
/// and a kind. The ball's x is absolute (world space).

enum SegmentKind { flat, narrow, ramp, gap, checkpoint, finish }

enum HazardKind { sweeper, pusher, bumper }

enum RidgePhase { playing, won, lost }

enum RidgeEventKind { fall, respawn, checkpoint, gem, bump, finish, jump }

class RidgeEvent {
  const RidgeEvent(this.kind, this.x, this.z);
  final RidgeEventKind kind;
  final double x;
  final double z;
}

class TrackSegment {
  TrackSegment({
    required this.z0,
    required this.length,
    required this.cx0,
    required this.cx1,
    required this.width,
    required this.kind,
  });
  final double z0;
  final double length;
  final double cx0;
  final double cx1;
  final double width;
  final SegmentKind kind;
  double get z1 => z0 + length;
  bool get hasFloor => kind != SegmentKind.gap;
  double centerAt(double z) {
    final t = ((z - z0) / length).clamp(0.0, 1.0);
    final s = t * t * (3 - 2 * t);
    return cx0 + (cx1 - cx0) * s;
  }

  /// Ramp height at [z] (0 for non-ramps).
  double heightAt(double z) {
    if (kind != SegmentKind.ramp) return 0;
    final t = ((z - z0) / length).clamp(0.0, 1.0);
    return t * 1.1;
  }
}

class Hazard {
  Hazard({
    required this.kind,
    required this.x,
    required this.z,
    this.size = 2.4,
    this.speed = 1.6,
    this.phase = 0,
  });
  final HazardKind kind;
  final double x;
  final double z;
  final double size;
  final double speed;
  final double phase;

  /// Current angle (sweeper) or lateral offset (pusher).
  double state = 0;
}

class Gem {
  Gem(this.x, this.z);
  final double x;
  final double z;
  bool taken = false;
}

class RidgeWorld {
  RidgeWorld({this.level = 1, int seed = 1}) : _rng = math.Random(seed * 31 + level) {
    _build();
    _respawn(atStart: true);
  }

  static const double ballRadius = 0.45;
  static const double gravity = -22;
  static const double steerSpeed = 7.5;
  static const int startLives = 3;

  final int level;
  final math.Random _rng;
  final List<TrackSegment> segments = [];
  final List<Hazard> hazards = [];
  final List<Gem> gems = [];
  final List<RidgeEvent> events = [];

  RidgePhase phase = RidgePhase.playing;
  double x = 0, y = 0, z = 0;
  double vy = 0;
  double vx = 0;
  double speed = 0;
  double roll = 0;
  bool airborne = false;
  int lives = startLives;
  int gemsTaken = 0;
  double time = 0;
  double checkpointZ = 0;
  double _respawnTimer = 0;

  /// Steering input in −1..1 (positive = world +x = screen right).
  double steer = 0;

  double get trackLength => segments.last.z1;
  double get progress => (z / trackLength).clamp(0.0, 1.0);
  bool get isOver => phase != RidgePhase.playing;
  bool get falling => _respawnTimer > 0;
  int get entityCount => segments.length + hazards.length + gems.where((g) => !g.taken).length + 1;
  double get cruiseSpeed => 9 + level * 0.6;

  int get score =>
      (progress * 1000).round() + gemsTaken * 50 + (phase == RidgePhase.won ? 500 + lives * 200 : 0);

  void _build() {
    var z = 0.0, cx = 0.0;
    void add(SegmentKind kind, double length, {double? toCx, double width = 4}) {
      final next = toCx ?? cx;
      segments.add(TrackSegment(z0: z, length: length, cx0: cx, cx1: next, width: width, kind: kind));
      z += length;
      cx = next;
    }

    add(SegmentKind.flat, 14, width: 5);
    final blocks = 8 + level * 2;
    for (var b = 0; b < blocks; b++) {
      final roll = _rng.nextDouble();
      final drift = (_rng.nextDouble() * 2 - 1) * 4;
      if (b > 0 && b % 5 == 0) {
        add(SegmentKind.checkpoint, 4, width: 5);
        continue;
      }
      if (roll < 0.3) {
        add(SegmentKind.flat, 10 + _rng.nextDouble() * 6, toCx: drift, width: 4.2);
      } else if (roll < 0.45) {
        add(SegmentKind.narrow, 8, toCx: cx, width: math.max(1.6, 2.6 - level * 0.08));
      } else if (roll < 0.62 && b > 1) {
        add(SegmentKind.ramp, 5, width: 3.6);
        add(SegmentKind.gap, 3 + math.min(3, level * 0.3), width: 3.6);
        add(SegmentKind.flat, 8, width: 4.2);
      } else {
        final seg0 = z;
        add(SegmentKind.flat, 14, toCx: drift * 0.5, width: 4.6);
        final hzZ = seg0 + 7;
        final kind = HazardKind.values[_rng.nextInt(HazardKind.values.length)];
        hazards.add(
          Hazard(
            kind: kind,
            x: segments.last.centerAt(hzZ),
            z: hzZ,
            size: kind == HazardKind.bumper ? 0.8 : 2.2,
            speed: 1.2 + _rng.nextDouble() * 0.6 + level * 0.08,
            phase: _rng.nextDouble() * math.pi * 2,
          ),
        );
      }
      // Scatter gems on floored segments.
      final s = segments.last;
      if (s.hasFloor && s.kind != SegmentKind.ramp && _rng.nextDouble() < 0.7) {
        final gz = s.z0 + s.length * 0.5;
        gems.add(Gem(s.centerAt(gz) + (_rng.nextDouble() * 2 - 1) * s.width * 0.3, gz));
      }
    }
    add(SegmentKind.flat, 6, width: 5);
    add(SegmentKind.finish, 6, width: 6);
  }

  TrackSegment? segmentAt(double zq) {
    for (final s in segments) {
      if (zq >= s.z0 && zq < s.z1) return s;
    }
    return null;
  }

  /// Floor height under (x, z), or null when there is no floor.
  double? floorAt(double xq, double zq) {
    final s = segmentAt(zq);
    if (s == null || !s.hasFloor) return null;
    if ((xq - s.centerAt(zq)).abs() > s.width / 2) return null;
    return s.heightAt(zq);
  }

  void _respawn({bool atStart = false}) {
    z = atStart ? 2 : checkpointZ;
    final s = segmentAt(z)!;
    x = s.centerAt(z);
    y = s.heightAt(z) + ballRadius;
    vy = 0;
    vx = 0;
    speed = atStart ? 0 : cruiseSpeed * 0.5;
    airborne = false;
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
    for (final h in hazards) {
      h.state = switch (h.kind) {
        HazardKind.sweeper => time * h.speed + h.phase,
        HazardKind.pusher => math.sin(time * h.speed + h.phase) * 1.6,
        HazardKind.bumper => 0,
      };
    }
    if (_respawnTimer > 0) {
      _respawnTimer -= dt;
      y += vy * dt;
      vy += gravity * dt;
      if (_respawnTimer <= 0) {
        if (lives <= 0) {
          phase = RidgePhase.lost;
          return;
        }
        _respawn();
        events.add(RidgeEvent(RidgeEventKind.respawn, x, z));
      }
      return;
    }
    // Forward motion eases to cruise speed.
    speed += (cruiseSpeed - speed) * math.min(1, dt * 1.5);
    final targetVx = steer.clamp(-1.0, 1.0) * steerSpeed;
    vx += (targetVx - vx) * math.min(1, dt * 10);
    final prevZ = z;
    z += speed * dt;
    x += vx * dt;
    roll += speed * dt / ballRadius;
    final floor = floorAt(x, z);
    if (airborne) {
      vy += gravity * dt;
      y += vy * dt;
      if (floor != null && y - ballRadius <= floor && vy <= 0) {
        y = floor + ballRadius;
        vy = 0;
        airborne = false;
      }
    } else {
      if (floor == null) {
        final prev = segmentAt(prevZ);
        // Leaving a ramp's end launches the ball.
        if (prev != null &&
            prev.kind == SegmentKind.ramp &&
            (x - prev.centerAt(prevZ)).abs() <= prev.width / 2) {
          vy = 7.5;
          airborne = true;
          events.add(RidgeEvent(RidgeEventKind.jump, x, z));
        } else {
          vy = 0;
          airborne = true;
        }
      } else {
        y = floor + ballRadius;
      }
    }
    if (y < -2.5) _fall();
    if (!falling) _hazards(dt);
    _pickups();
    final seg = segmentAt(z);
    if (seg != null && seg.kind == SegmentKind.checkpoint && checkpointZ < seg.z0) {
      checkpointZ = seg.z0 + 1;
      events.add(RidgeEvent(RidgeEventKind.checkpoint, x, z));
    }
    if (seg != null && seg.kind == SegmentKind.finish && !airborne) {
      phase = RidgePhase.won;
      events.add(RidgeEvent(RidgeEventKind.finish, x, z));
    }
    if (z >= trackLength) phase = RidgePhase.won;
  }

  void _fall() {
    lives--;
    _respawnTimer = 0.9;
    events.add(RidgeEvent(RidgeEventKind.fall, x, z));
  }

  void _hazards(double dt) {
    for (final h in hazards) {
      if ((h.z - z).abs() > h.size + 1) continue;
      switch (h.kind) {
        case HazardKind.sweeper:
          // A bar of length h.size*2 rotating around (h.x, h.z).
          final dx = math.cos(h.state), dz = math.sin(h.state);
          final px = x - h.x, pz = z - h.z;
          final along = (px * dx + pz * dz).clamp(-h.size, h.size);
          final cx = h.x + dx * along, cz = h.z + dz * along;
          final ox = x - cx, oz = z - cz;
          final d = math.sqrt(ox * ox + oz * oz);
          if (d < ballRadius + 0.2) {
            final nx = d > 1e-6 ? ox / d : 1.0;
            vx = nx * 9;
            x += nx * (ballRadius + 0.2 - d);
            speed *= 0.5;
            events.add(RidgeEvent(RidgeEventKind.bump, x, z));
          }
        case HazardKind.pusher:
          // A block (1.4 x 1.0) sliding across the track.
          final bx = h.x + h.state;
          if ((x - bx).abs() < 0.7 + ballRadius && (z - h.z).abs() < 0.5 + ballRadius) {
            final dir = x >= bx ? 1.0 : -1.0;
            x = bx + dir * (0.7 + ballRadius);
            vx = dir * 6;
            events.add(RidgeEvent(RidgeEventKind.bump, x, z));
          }
        case HazardKind.bumper:
          final ox = x - h.x, oz = z - h.z;
          final d = math.sqrt(ox * ox + oz * oz);
          final r = h.size + ballRadius;
          if (d < r) {
            final nx = d > 1e-6 ? ox / d : 0.0, nz = d > 1e-6 ? oz / d : -1.0;
            x = h.x + nx * r;
            z = h.z + nz * r;
            // Deflect sideways even on a dead-centre hit.
            final side = ox.abs() < 0.1 ? (ox >= 0 ? 1.0 : -1.0) : ox.sign;
            vx = side * 8;
            if (oz < 0) speed *= 0.4;
            events.add(RidgeEvent(RidgeEventKind.bump, x, z));
          }
      }
    }
  }

  void _pickups() {
    for (final g in gems) {
      if (g.taken) continue;
      if ((g.z - z).abs() < 0.8 && (g.x - x).abs() < 0.8) {
        g.taken = true;
        gemsTaken++;
        events.add(RidgeEvent(RidgeEventKind.gem, g.x, g.z));
      }
    }
  }

  // --- Test helpers ---
  void debugPlace(double px, double pz) {
    x = px;
    z = pz;
    y = (floorAt(px, pz) ?? 0) + ballRadius;
    airborne = false;
    vy = 0;
    vx = 0;
  }

  void debugClearHazards() => hazards.clear();
}
