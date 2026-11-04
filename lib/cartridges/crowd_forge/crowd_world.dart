import 'dart:math' as math;

/// Pure-Dart rules for Crowd Forge (3D crowd launcher).
///
/// World axes: x is across the lane (−[laneHalfWidth]..+[laneHalfWidth]), z runs
/// from the player's launcher (z = 0) to the enemy forge (z = [forgeZ]). y is up.

enum CrowdPhase { playing, won, lost }

enum CrowdEventKind { fire, multiply, clash, forgeHit, breach, champion, blade }

class CrowdEvent {
  const CrowdEvent(this.kind, this.x, this.z);
  final CrowdEventKind kind;
  final double x;
  final double z;
}

class Unit {
  double x = 0;
  double z = 0;
  int hp = 1;
  bool alive = false;
  bool champion = false;
  int gateMask = 0;
  double drift = 0;
}

class Foe {
  double x = 0;
  double z = 0;
  int hp = 1;
  bool alive = false;
  bool brute = false;
}

/// A multiplier gate. Every unit passing through it once spawns
/// `multiplier - 1` clones. Some gates sway across the lane.
class Gate {
  Gate({required this.baseX, required this.z, required this.multiplier, this.width = 2.4, this.sway = 0});
  final double baseX;
  final double z;
  final int multiplier;
  final double width;
  final double sway;
  double x = 0;
}

/// A spinning blade sweeping across the lane, destroying units it touches.
class Blade {
  Blade({required this.z, required this.speed, this.radius = 0.7});
  final double z;
  final double speed;
  final double radius;
  double x = 0;
  double angle = 0;
}

class CrowdWorld {
  CrowdWorld({this.level = 1, int seed = 1}) : _rng = math.Random(seed) {
    forgeMaxHp = 400 + 150 * level;
    forgeHp = forgeMaxHp;
    _layoutLevel();
    for (var i = 0; i < maxUnits; i++) {
      units.add(Unit());
    }
    for (var i = 0; i < maxFoes; i++) {
      foes.add(Foe());
    }
  }

  static const double laneHalfWidth = 3.2;
  static const double forgeZ = 34;
  static const double unitSpeed = 7.5;
  static const double foeSpeed = 3.6;
  static const double fireInterval = 0.11;
  static const int maxUnits = 360;
  static const int maxFoes = 160;
  static const int championCharge = 45;
  static const double hitRadius = 0.5;

  final int level;
  final math.Random _rng;

  /// Fixed-size pools (instanced rendering maps 1:1 onto these slots).
  final List<Unit> units = [];
  final List<Foe> foes = [];
  final List<Gate> gates = [];
  final List<Blade> blades = [];
  final List<CrowdEvent> events = [];

  CrowdPhase phase = CrowdPhase.playing;
  double time = 0;
  double launcherX = 0;
  double targetX = 0;
  bool firing = false;
  double _fireTimer = 0;
  int charge = 0;
  int forgeMaxHp = 0;
  int forgeHp = 0;
  int baseMaxHp = 20;
  int baseHp = 20;
  int fired = 0;
  int clones = 0;
  int foesDefeated = 0;
  int damageDealt = 0;
  double _foeTimer = 1.5;
  int _foeCount = 0;

  int get liveUnits => units.where((u) => u.alive).length;
  int get liveFoes => foes.where((f) => f.alive).length;
  int get entityCount => liveUnits + liveFoes + gates.length + blades.length + 2;
  bool get isOver => phase != CrowdPhase.playing;
  double get championProgress => charge / championCharge;

  int get score => damageDealt * 10 + foesDefeated * 5 + (phase == CrowdPhase.won ? 500 + baseHp * 25 : 0);

  void _layoutLevel() {
    final mults = level < 3 ? [2, 2, 3] : [2, 3, 3, 4];
    final rows = math.min(3, 1 + (level + 1) ~/ 2);
    final zs = [9.0, 16.0, 23.0];
    for (var r = 0; r < rows; r++) {
      final z = zs[r];
      if (_rng.nextBool()) {
        // Two side-by-side gates with different multipliers.
        final a = mults[_rng.nextInt(mults.length)];
        final b = a == 2 ? 3 : 2;
        gates.add(Gate(baseX: -1.6, z: z, multiplier: a));
        gates.add(Gate(baseX: 1.6, z: z, multiplier: b));
      } else {
        gates.add(
          Gate(
            baseX: 0,
            z: z,
            multiplier: mults[_rng.nextInt(mults.length)],
            width: 2.2,
            sway: 1.4 + _rng.nextDouble(),
          ),
        );
      }
    }
    if (level >= 2) blades.add(Blade(z: 12.5, speed: 1.2 + 0.1 * level));
    if (level >= 4) blades.add(Blade(z: 19.5, speed: 1.6 + 0.1 * level));
    _updateObstacles(0);
  }

  /// Sets the aim from a normalised horizontal input in −1..1.
  void aim(double normalized) => targetX = (normalized.clamp(-1.0, 1.0)) * laneHalfWidth;

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
    // Launcher follows the aim.
    final dx = targetX - launcherX;
    final maxMove = 14 * dt;
    launcherX += dx.clamp(-maxMove, maxMove);
    _updateObstacles(dt);
    if (firing) {
      _fireTimer -= dt;
      while (_fireTimer <= 0) {
        _fireTimer += fireInterval;
        _fire();
      }
    } else {
      _fireTimer = math.max(0, _fireTimer - dt);
    }
    _spawnFoes(dt);
    _moveUnits(dt);
    _moveFoes(dt);
    _resolveClashes();
    if (forgeHp <= 0) {
      forgeHp = 0;
      phase = CrowdPhase.won;
    } else if (baseHp <= 0) {
      baseHp = 0;
      phase = CrowdPhase.lost;
    }
  }

  void _updateObstacles(double dt) {
    for (final g in gates) {
      g.x = g.sway == 0
          ? g.baseX
          : (math.sin(time * 1.1 + g.z) * g.sway).clamp(
              -laneHalfWidth + g.width / 2,
              laneHalfWidth - g.width / 2,
            );
    }
    for (final b in blades) {
      b.x = math.sin(time * b.speed + b.z) * (laneHalfWidth - 0.4);
      b.angle += dt * 12;
    }
  }

  Unit? _obtainUnit() {
    for (final u in units) {
      if (!u.alive) return u;
    }
    return null;
  }

  void _fire() {
    final u = _obtainUnit();
    if (u == null) return;
    fired++;
    final champ = charge >= championCharge;
    if (champ) {
      charge = 0;
      events.add(CrowdEvent(CrowdEventKind.champion, launcherX, 0.8));
    } else {
      charge++;
    }
    u
      ..alive = true
      ..champion = champ
      ..hp = champ ? 12 : 1
      ..gateMask = 0
      ..x = launcherX
      ..z = 0.8
      ..drift = (_rng.nextDouble() - 0.5) * 0.3;
    events.add(CrowdEvent(CrowdEventKind.fire, u.x, u.z));
  }

  void _moveUnits(double dt) {
    for (final u in units) {
      if (!u.alive) continue;
      final prevZ = u.z;
      u.z += unitSpeed * (u.champion ? 0.8 : 1) * dt;
      u.x = (u.x + u.drift * dt).clamp(-laneHalfWidth + 0.2, laneHalfWidth - 0.2);
      // Gates: crossing the gate plane inside its span multiplies the unit.
      for (var gi = 0; gi < gates.length; gi++) {
        final g = gates[gi];
        final bit = 1 << gi;
        if (u.gateMask & bit != 0 || u.champion) continue;
        if (prevZ < g.z && u.z >= g.z && (u.x - g.x).abs() <= g.width / 2) {
          u.gateMask |= bit;
          _clone(u, g.multiplier - 1);
          events.add(CrowdEvent(CrowdEventKind.multiply, u.x, g.z));
        }
      }
      for (final b in blades) {
        if (u.champion) continue;
        if ((u.z - b.z).abs() < b.radius && (u.x - b.x).abs() < b.radius) {
          u.alive = false;
          events.add(CrowdEvent(CrowdEventKind.blade, u.x, u.z));
          break;
        }
      }
      if (!u.alive) continue;
      if (u.z >= forgeZ - 0.8) {
        forgeHp -= u.hp;
        damageDealt += u.hp;
        u.alive = false;
        events.add(CrowdEvent(CrowdEventKind.forgeHit, u.x, u.z));
      }
    }
  }

  void _clone(Unit source, int n) {
    for (var i = 0; i < n; i++) {
      final c = _obtainUnit();
      if (c == null) return;
      clones++;
      c
        ..alive = true
        ..champion = false
        ..hp = 1
        ..gateMask = source.gateMask
        ..x = (source.x + (i + 1) * 0.35 * (i.isEven ? 1 : -1)).clamp(
          -laneHalfWidth + 0.2,
          laneHalfWidth - 0.2,
        )
        ..z = source.z + 0.05
        ..drift = (_rng.nextDouble() - 0.5) * 0.6;
    }
  }

  void _spawnFoes(double dt) {
    _foeTimer -= dt;
    if (_foeTimer > 0) return;
    _foeTimer = math.max(0.35, 1.1 - 0.07 * level) * (0.7 + _rng.nextDouble() * 0.6);
    final group = 2 + _rng.nextInt(math.min(6, 2 + level ~/ 2));
    for (var i = 0; i < group; i++) {
      final f = foes.firstWhere((f) => !f.alive, orElse: () => Foe());
      if (!foes.contains(f)) return; // pool exhausted
      _foeCount++;
      final brute = _foeCount % math.max(4, 12 - level) == 0;
      f
        ..alive = true
        ..brute = brute
        ..hp = brute ? 6 + level : 1
        ..x = (_rng.nextDouble() * 2 - 1) * (laneHalfWidth - 0.5)
        ..z = forgeZ - 1.5 - i * 0.6;
    }
  }

  void _moveFoes(double dt) {
    for (final f in foes) {
      if (!f.alive) continue;
      f.z -= foeSpeed * (f.brute ? 0.6 : 1) * dt;
      // Foes drift toward the launcher.
      f.x += (launcherX - f.x).clamp(-1, 1) * 0.35 * dt;
      if (f.z <= 0.4) {
        baseHp -= f.brute ? 4 : 1;
        f.alive = false;
        events.add(CrowdEvent(CrowdEventKind.breach, f.x, f.z));
      }
    }
  }

  /// Units and foes destroy each other 1 HP for 1 HP. Uses z-bucketing so the
  /// cost stays near-linear even with hundreds of units.
  final Map<int, List<Foe>> _buckets = {};

  void _resolveClashes() {
    _buckets.clear();
    for (final f in foes) {
      if (!f.alive) continue;
      _buckets.putIfAbsent(f.z.floor(), () => []).add(f);
    }
    if (_buckets.isEmpty) return;
    for (final u in units) {
      if (!u.alive) continue;
      final zb = u.z.floor();
      for (var b = zb - 1; b <= zb + 1 && u.alive; b++) {
        final list = _buckets[b];
        if (list == null) continue;
        for (final f in list) {
          if (!f.alive) continue;
          final r = hitRadius + (f.brute ? 0.25 : 0) + (u.champion ? 0.25 : 0);
          final dx = u.x - f.x, dz = u.z - f.z;
          if (dx * dx + dz * dz > r * r) continue;
          final trade = math.min(u.hp, f.hp);
          u.hp -= trade;
          f.hp -= trade;
          if (f.hp <= 0) {
            f.alive = false;
            foesDefeated++;
          }
          events.add(CrowdEvent(CrowdEventKind.clash, f.x, f.z));
          if (u.hp <= 0) {
            u.alive = false;
            break;
          }
        }
      }
    }
  }

  // --- Test helpers ---
  Unit debugSpawnUnit(double x, double z, {bool champion = false}) {
    final u = _obtainUnit()!;
    u
      ..alive = true
      ..champion = champion
      ..hp = champion ? 12 : 1
      ..gateMask = 0
      ..x = x
      ..z = z
      ..drift = 0;
    return u;
  }

  Foe debugSpawnFoe(double x, double z, {int hp = 1}) {
    final f = foes.firstWhere((f) => !f.alive);
    f
      ..alive = true
      ..brute = hp > 1
      ..hp = hp
      ..x = x
      ..z = z;
    return f;
  }

  void debugStopFoes() => _foeTimer = 1e9;
}
