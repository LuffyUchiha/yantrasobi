import 'dart:math' as math;

/// Pure-Dart rules for Mob Magnet: lead a crowd through a city, recruit
/// idle citizens by touching them, and absorb smaller rival crowds.
///
/// Coordinates: x/z on the ground plane, the city spans 0..[size] on both axes.

enum MobPhase { playing, won, lost }

enum MobEventKind { recruit, absorb, eliminated, playerEliminated }

class MobEvent {
  const MobEvent(this.kind, this.team, this.x, this.z);
  final MobEventKind kind;
  final int team;
  final double x;
  final double z;
}

/// Team 0 = neutral citizens, 1 = player, 2.. = rivals.
class Person {
  double x = 0;
  double z = 0;
  double vx = 0;
  double vz = 0;
  int team = 0;
  bool leader = false;
  double wanderTimer = 0;
}

class Building {
  const Building(this.x0, this.z0, this.x1, this.z1, this.height);
  final double x0, z0, x1, z1, height;
  bool contains(double x, double z, double pad) =>
      x > x0 - pad && x < x1 + pad && z > z0 - pad && z < z1 + pad;
}

class Team {
  Team(this.id, this.leader);
  final int id;
  final Person leader;
  bool alive = true;
  int size = 1;
  int absorbed = 0;
  // Bot steering target.
  double tx = 0, tz = 0;
  double thinkTimer = 0;
}

class MobWorld {
  MobWorld({int seed = 1, this.rivals = 3, this.citizens = 260, this.roundTime = 75})
    : _rng = math.Random(seed) {
    _buildCity();
    for (var i = 0; i < citizens; i++) {
      final p = Person();
      _placeFree(p);
      p.wanderTimer = _rng.nextDouble() * 2;
      people.add(p);
    }
    teams.add(Team(0, Person())); // neutral placeholder
    _addTeam(1, size / 2, size / 2);
    for (var r = 0; r < rivals; r++) {
      final a = r * 2 * math.pi / rivals + 0.5;
      _addTeam(2 + r, size / 2 + math.cos(a) * size * 0.33, size / 2 + math.sin(a) * size * 0.33);
    }
    timeLeft = roundTime;
    _recount();
  }

  static const double size = 64;
  static const double personRadius = 0.32;
  static const double leaderSpeed = 6.2;
  static const double followerSpeed = 7.4;
  static const double recruitRange = 0.75;
  static const int maxPeople = 420;

  final math.Random _rng;
  final int rivals;
  final int citizens;
  final double roundTime;
  final List<Person> people = [];
  final List<Building> buildings = [];
  final List<Team> teams = [];
  final List<MobEvent> events = [];

  /// Joystick input for the player leader (length ≤ 1).
  double inputX = 0, inputZ = 0;
  MobPhase phase = MobPhase.playing;
  double time = 0;
  double timeLeft = 0;
  double _respawnTimer = 0;

  Team get player => teams[1];
  bool get isOver => phase != MobPhase.playing;
  int get entityCount => people.length + buildings.length;
  int sizeOf(int team) => teams[team].size;

  int get rank {
    final mine = player.size;
    return 1 + teams.skip(2).where((t) => t.alive && t.size > mine).length;
  }

  int get score => player.size * 10 + player.absorbed * 2 + (phase == MobPhase.won ? 500 : 0);

  void _buildCity() {
    // A grid of blocks with streets between them.
    const block = 9.0, street = 5.0;
    for (var bx = street; bx + block < size; bx += block + street) {
      for (var bz = street; bz + block < size; bz += block + street) {
        if (_rng.nextDouble() < 0.25) continue; // plazas
        final inset = _rng.nextDouble() * 1.5;
        buildings.add(
          Building(bx + inset, bz + inset, bx + block - inset, bz + block - inset, 2 + _rng.nextDouble() * 6),
        );
      }
    }
    // Keep the centre open for the player spawn.
    buildings.removeWhere((b) => b.contains(size / 2, size / 2, 4));
  }

  bool blocked(double x, double z, [double pad = personRadius]) {
    if (x < pad || z < pad || x > size - pad || z > size - pad) return true;
    for (final b in buildings) {
      if (b.contains(x, z, pad)) return true;
    }
    return false;
  }

  void _placeFree(Person p) {
    for (var i = 0; i < 50; i++) {
      p.x = 1 + _rng.nextDouble() * (size - 2);
      p.z = 1 + _rng.nextDouble() * (size - 2);
      if (!blocked(p.x, p.z, 0.5)) return;
    }
  }

  void _addTeam(int id, double x, double z) {
    final leader = Person()
      ..team = id
      ..leader = true
      ..x = x
      ..z = z;
    if (blocked(x, z)) _placeFree(leader);
    people.add(leader);
    final t = Team(id, leader)
      ..tx = x
      ..tz = z;
    teams.add(t);
  }

  void update(double dt) {
    events.clear();
    if (isOver) return;
    var remaining = math.min(dt, 0.2);
    while (remaining > 1e-9 && !isOver) {
      final step = math.min(remaining, 1 / 60);
      _step(step);
      remaining -= step;
    }
  }

  void _step(double dt) {
    time += dt;
    timeLeft -= dt;
    _steerPlayer();
    for (final t in teams.skip(2)) {
      if (t.alive) _thinkBot(t, dt);
    }
    _move(dt);
    _interact();
    _recount();
    _respawnTimer -= dt;
    if (_respawnTimer <= 0) {
      _respawnTimer = 0.8;
      _respawnNeutral();
    }
    if (!player.alive) {
      phase = MobPhase.lost;
    } else if (teams.skip(2).every((t) => !t.alive)) {
      phase = MobPhase.won;
    } else if (timeLeft <= 0) {
      timeLeft = 0;
      phase = rank == 1 ? MobPhase.won : MobPhase.lost;
    }
  }

  void _steerPlayer() {
    final l = player.leader;
    var ix = inputX, iz = inputZ;
    final len = math.sqrt(ix * ix + iz * iz);
    if (len > 1) {
      ix /= len;
      iz /= len;
    }
    l.vx = ix * leaderSpeed;
    l.vz = iz * leaderSpeed;
  }

  void _thinkBot(Team t, double dt) {
    t.thinkTimer -= dt;
    final l = t.leader;
    if (t.thinkTimer <= 0) {
      t.thinkTimer = 0.6 + _rng.nextDouble() * 0.6;
      // Flee a bigger crowd's leader nearby, chase a smaller one, else recruit.
      Team? threat, prey;
      for (final o in teams.skip(1)) {
        if (o == t || !o.alive) continue;
        final d = _dist(l, o.leader);
        if (o.size > t.size * 1.15 && d < 12) threat = o;
        if (t.size > o.size * 1.3 && d < 16) prey = o;
      }
      if (threat != null) {
        t.tx = (l.x + (l.x - threat.leader.x) * 2).clamp(2, size - 2);
        t.tz = (l.z + (l.z - threat.leader.z) * 2).clamp(2, size - 2);
      } else if (prey != null) {
        t.tx = prey.leader.x;
        t.tz = prey.leader.z;
      } else {
        // Nearest neutral within a sampled set.
        Person? best;
        var bestD = double.infinity;
        for (var i = 0; i < 40; i++) {
          final p = people[_rng.nextInt(people.length)];
          if (p.team != 0) continue;
          final d = _dist(l, p);
          if (d < bestD) {
            bestD = d;
            best = p;
          }
        }
        if (best != null) {
          t.tx = best.x;
          t.tz = best.z;
        }
      }
    }
    final dx = t.tx - l.x, dz = t.tz - l.z;
    final d = math.sqrt(dx * dx + dz * dz);
    final speed = leaderSpeed * 0.82;
    if (d > 0.3) {
      l.vx = dx / d * speed;
      l.vz = dz / d * speed;
    } else {
      l.vx = 0;
      l.vz = 0;
    }
  }

  static double _dist(Person a, Person b) {
    final dx = a.x - b.x, dz = a.z - b.z;
    return math.sqrt(dx * dx + dz * dz);
  }

  void _move(double dt) {
    for (final p in people) {
      if (p.team == 0) {
        p.wanderTimer -= dt;
        if (p.wanderTimer <= 0) {
          p.wanderTimer = 1.5 + _rng.nextDouble() * 2.5;
          final a = _rng.nextDouble() * 2 * math.pi;
          final s = _rng.nextDouble() < 0.3 ? 0.0 : 1.2;
          p.vx = math.cos(a) * s;
          p.vz = math.sin(a) * s;
        }
      } else if (!p.leader) {
        // Followers seek their leader with some slack.
        final l = teams[p.team].leader;
        final dx = l.x - p.x, dz = l.z - p.z;
        final d = math.sqrt(dx * dx + dz * dz);
        final slack = 0.6 + math.sqrt(teams[p.team].size) * 0.25;
        if (d > slack) {
          final s = math.min(followerSpeed, d * 3);
          p.vx = dx / d * s;
          p.vz = dz / d * s;
        } else {
          p.vx *= 0.8;
          p.vz *= 0.8;
        }
      }
      final nx = p.x + p.vx * dt, nz = p.z + p.vz * dt;
      if (!blocked(nx, nz)) {
        p.x = nx;
        p.z = nz;
      } else if (!blocked(nx, p.z)) {
        p.x = nx;
      } else if (!blocked(p.x, nz)) {
        p.z = nz;
      } else if (p.team == 0) {
        p.vx = -p.vx;
        p.vz = -p.vz;
      }
    }
  }

  // Spatial hash for neighbour queries.
  final Map<int, List<Person>> _grid = {};
  static const double _cell = 1.6;
  int _key(double x, double z) => (x ~/ _cell) * 1000 + (z ~/ _cell);

  void _interact() {
    _grid.clear();
    for (final p in people) {
      _grid.putIfAbsent(_key(p.x, p.z), () => []).add(p);
    }
    // Separation + recruitment + crowd clashes.
    for (final p in people) {
      final cx = p.x ~/ _cell, cz = p.z ~/ _cell;
      for (var gx = cx - 1; gx <= cx + 1; gx++) {
        for (var gz = cz - 1; gz <= cz + 1; gz++) {
          final list = _grid[gx * 1000 + gz];
          if (list == null) continue;
          for (final o in list) {
            if (identical(o, p)) continue;
            final dx = o.x - p.x, dz = o.z - p.z;
            final d2 = dx * dx + dz * dz;
            if (d2 > recruitRange * recruitRange) continue;
            _contact(p, o);
            // Soft separation between same-team members.
            if (p.team == o.team && d2 > 1e-6 && d2 < (personRadius * 2) * (personRadius * 2)) {
              final d = math.sqrt(d2);
              final push = (personRadius * 2 - d) * 0.5 / d;
              if (!p.leader) {
                final nx = p.x - dx * push, nz = p.z - dz * push;
                if (!blocked(nx, nz)) {
                  p.x = nx;
                  p.z = nz;
                }
              }
            }
          }
        }
      }
    }
  }

  void _contact(Person a, Person b) {
    if (a.team == b.team) return;
    if (a.team != 0 && b.team == 0) {
      _convert(b, a.team, MobEventKind.recruit);
    } else if (a.team != 0 && b.team != 0) {
      final ta = teams[a.team], tb = teams[b.team];
      if (!ta.alive || !tb.alive) return;
      // The bigger crowd wins every contact.
      if (ta.size > tb.size) {
        if (b.leader) {
          _eliminate(tb, by: ta);
        } else {
          _convert(b, ta.id, MobEventKind.absorb);
          ta.absorbed++;
        }
      }
    }
  }

  void _convert(Person p, int team, MobEventKind kind) {
    final from = p.team;
    p.team = team;
    p.vx = 0;
    p.vz = 0;
    if (from != 0) teams[from].size--;
    teams[team].size++;
    events.add(MobEvent(kind, team, p.x, p.z));
  }

  void _eliminate(Team victim, {required Team by}) {
    victim.alive = false;
    for (final p in people) {
      if (p.team == victim.id) {
        p.leader = false;
        p.team = by.id;
        by.absorbed++;
      }
    }
    events.add(
      MobEvent(
        victim.id == 1 ? MobEventKind.playerEliminated : MobEventKind.eliminated,
        victim.id,
        victim.leader.x,
        victim.leader.z,
      ),
    );
    if (victim.id == 1) player.alive = false;
  }

  void _recount() {
    for (final t in teams) {
      t.size = 0;
    }
    for (final p in people) {
      teams[p.team].size++;
    }
    for (final t in teams.skip(1)) {
      if (!t.alive) t.size = 0;
    }
  }

  void _respawnNeutral() {
    final neutral = teams[0].size;
    if (neutral > citizens * 0.25 || people.length >= maxPeople) return;
    final p = Person();
    _placeFree(p);
    // Do not spawn on top of a crowd.
    for (final t in teams.skip(1)) {
      if (t.alive && _dist(p, t.leader) < 6) return;
    }
    people.add(p);
  }

  // --- Test helpers ---
  Person debugSpawn(int team, double x, double z) {
    final p = Person()
      ..team = team
      ..x = x
      ..z = z;
    people.add(p);
    _recount();
    return p;
  }

  void debugClearNeutrals() {
    people.removeWhere((p) => p.team == 0);
    _recount();
  }

  void debugFreezeRivals() {
    for (final t in teams.skip(2)) {
      t
        ..tx = t.leader.x
        ..tz = t.leader.z
        ..thinkTimer = 1e9;
    }
  }
}
