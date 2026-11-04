import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' show Vector2;

/// Pure-Dart rules for Arrow Survivor. No Flutter/Flame imports, so every rule
/// is unit-testable and deterministic for a given seed.

enum EnemyKind { chaser, dasher, spitter, tank, boss }

enum SurvivorPhase { fighting, intermission, choosing, won, lost }

enum Upgrade {
  multishot('Split Shot', '+1 arrow per volley', 4),
  rapid('Quick Draw', 'Fire 18% faster', 5),
  pierce('Piercing Tips', 'Arrows pass through +1 enemy', 3),
  damage('Heavy Heads', '+30% arrow damage', 5),
  speed('Light Boots', '+12% move speed', 4),
  vitality('Iron Heart', '+25 max HP and full heal', 4),
  blades('Orbit Blade', '+1 blade circling you', 4),
  heal('Second Wind', 'Restore 50% HP', 99);

  const Upgrade(this.title, this.description, this.maxLevel);
  final String title;
  final String description;
  final int maxLevel;
}

/// Something that happened this tick, consumed by the renderer for SFX/FX.
enum SurvivorEventKind { shoot, hit, kill, hurt, pickup, waveClear, choose }

class SurvivorEvent {
  const SurvivorEvent(this.kind, this.x, this.y, [this.enemy]);
  final SurvivorEventKind kind;
  final double x;
  final double y;
  final EnemyKind? enemy;
}

class Player {
  Vector2 pos = Vector2.zero();
  double radius = 14;
  double maxHp = 100;
  double hp = 100;
  double speed = 170;
  double fireInterval = 0.55;
  double fireTimer = 0;
  double damage = 10;
  int arrows = 1;
  int pierce = 0;
  int blades = 0;
  double invulnerable = 0;
  Vector2 facing = Vector2(0, -1);
}

class Arrow {
  final Vector2 pos = Vector2.zero();
  final Vector2 vel = Vector2.zero();
  double damage = 0;
  int pierceLeft = 0;
  double life = 0;
  final Set<int> hit = {};
  bool alive = false;
}

class Enemy {
  Enemy(this.id, this.kind);
  final int id;
  final EnemyKind kind;
  final Vector2 pos = Vector2.zero();
  final Vector2 vel = Vector2.zero();
  double hp = 1;
  double maxHp = 1;
  double speed = 50;
  double radius = 12;
  double contactDamage = 10;
  double timer = 0;
  double dashTime = 0;
  double bladeCooldown = 0;
  double flash = 0;
  bool alive = true;
}

class Shot {
  final Vector2 pos = Vector2.zero();
  final Vector2 vel = Vector2.zero();
  double damage = 8;
  bool alive = true;
}

class Pickup {
  Pickup(this.pos);
  final Vector2 pos;
  double life = 9;
}

class SurvivorWorld {
  SurvivorWorld({required double width, required double height, int seed = 1, this.finalWave = 10})
    : _rng = math.Random(seed) {
    resize(width, height);
    player.pos.setValues(width / 2, height * 0.6);
    _beginWave(1);
  }

  final math.Random _rng;
  final int finalWave;

  double width = 0;
  double height = 0;
  final Player player = Player();
  final List<Enemy> enemies = [];
  final List<Arrow> _arrowPool = [];
  final List<Shot> shots = [];
  final List<Pickup> pickups = [];
  final List<SurvivorEvent> events = [];
  final Map<Upgrade, int> levels = {};

  /// Joystick input; length is clamped to 1.
  final Vector2 input = Vector2.zero();

  SurvivorPhase phase = SurvivorPhase.fighting;
  int wave = 0;
  int score = 0;
  int kills = 0;
  double time = 0;
  double bladeAngle = 0;
  double phaseTimer = 0;
  List<Upgrade> choices = const [];
  int _toSpawn = 0;
  double _spawnTimer = 0;
  int _nextId = 0;

  Iterable<Arrow> get arrows => _arrowPool.where((a) => a.alive);
  bool get isOver => phase == SurvivorPhase.won || phase == SurvivorPhase.lost;
  int get entityCount => enemies.length + arrows.length + shots.length + pickups.length + 1;
  int get remainingInWave => _toSpawn + enemies.length;

  void resize(double w, double h) {
    width = w;
    height = h;
    player.pos.x = player.pos.x.clamp(player.radius, math.max(player.radius, w - player.radius));
    player.pos.y = player.pos.y.clamp(player.radius, math.max(player.radius, h - player.radius));
  }

  static int waveSize(int wave) => wave % 5 == 0 ? 4 + 2 * wave : 5 + 3 * wave;

  void _beginWave(int n) {
    wave = n;
    _toSpawn = waveSize(n);
    _spawnTimer = 0.6;
    phase = SurvivorPhase.fighting;
  }

  /// Advances the simulation. Large steps are subdivided for stable collisions.
  void update(double dt) {
    events.clear();
    if (isOver) return;
    var remaining = math.min(dt, 0.25);
    while (remaining > 0) {
      final step = math.min(remaining, 1 / 60);
      _step(step);
      remaining -= step;
      if (isOver) break;
    }
  }

  void _step(double dt) {
    time += dt;
    switch (phase) {
      case SurvivorPhase.choosing:
      case SurvivorPhase.won:
      case SurvivorPhase.lost:
        return;
      case SurvivorPhase.intermission:
        phaseTimer -= dt;
        _movePlayer(dt);
        _updatePickups(dt);
        if (phaseTimer <= 0) {
          if (wave >= finalWave) {
            phase = SurvivorPhase.won;
          } else {
            choices = _rollChoices();
            phase = SurvivorPhase.choosing;
          }
        }
        return;
      case SurvivorPhase.fighting:
        break;
    }
    _movePlayer(dt);
    _spawn(dt);
    _fire(dt);
    _updateArrows(dt);
    _updateEnemies(dt);
    _updateBlades(dt);
    _updateShots(dt);
    _updatePickups(dt);
    enemies.removeWhere((e) => !e.alive);
    if (player.hp <= 0) {
      player.hp = 0;
      phase = SurvivorPhase.lost;
      return;
    }
    if (_toSpawn == 0 && enemies.isEmpty) {
      score += 100 * wave;
      events.add(SurvivorEvent(SurvivorEventKind.waveClear, player.pos.x, player.pos.y));
      shots.clear();
      phase = SurvivorPhase.intermission;
      phaseTimer = 1.2;
    }
  }

  void _movePlayer(double dt) {
    final p = player;
    if (input.length2 > 1) input.normalize();
    if (input.length2 > 0.0004) {
      p.pos.addScaled(input, p.speed * dt);
      p.facing.setFrom(input.normalized());
    }
    p.pos.x = p.pos.x.clamp(p.radius, width - p.radius);
    p.pos.y = p.pos.y.clamp(p.radius, height - p.radius);
    if (p.invulnerable > 0) p.invulnerable -= dt;
  }

  void _spawn(double dt) {
    if (_toSpawn <= 0) return;
    _spawnTimer -= dt;
    if (_spawnTimer > 0) return;
    _spawnTimer = math.max(0.3, 1.1 - 0.07 * wave);
    final isBossWave = wave % 5 == 0;
    final kind = isBossWave && _toSpawn == waveSize(wave) ? EnemyKind.boss : _pickKind();
    enemies.add(_makeEnemy(kind));
    _toSpawn--;
  }

  EnemyKind _pickKind() {
    final pool = <EnemyKind>[EnemyKind.chaser, EnemyKind.chaser];
    if (wave >= 2) pool.add(EnemyKind.dasher);
    if (wave >= 3) pool.add(EnemyKind.spitter);
    if (wave >= 4) pool.add(EnemyKind.tank);
    return pool[_rng.nextInt(pool.length)];
  }

  Enemy _makeEnemy(EnemyKind kind) {
    final e = Enemy(_nextId++, kind);
    final w = wave.toDouble();
    switch (kind) {
      case EnemyKind.chaser:
        e
          ..maxHp = 20 + 5 * w
          ..speed = 58 + 3 * w
          ..radius = 12
          ..contactDamage = 10;
      case EnemyKind.dasher:
        e
          ..maxHp = 12 + 3 * w
          ..speed = 45
          ..radius = 10
          ..contactDamage = 12
          ..timer = 1.5 + _rng.nextDouble();
      case EnemyKind.spitter:
        e
          ..maxHp = 18 + 4 * w
          ..speed = 55
          ..radius = 12
          ..contactDamage = 8
          ..timer = 1.5 + _rng.nextDouble();
      case EnemyKind.tank:
        e
          ..maxHp = 80 + 12 * w
          ..speed = 36
          ..radius = 20
          ..contactDamage = 20;
      case EnemyKind.boss:
        e
          ..maxHp = 450 * w / 5 + 150
          ..speed = 42
          ..radius = 34
          ..contactDamage = 25
          ..timer = 2.5;
    }
    e.hp = e.maxHp;
    // Spawn on an edge, away from the player.
    for (var attempt = 0; attempt < 8; attempt++) {
      final side = _rng.nextInt(4);
      final t = _rng.nextDouble();
      switch (side) {
        case 0:
          e.pos.setValues(t * width, e.radius);
        case 1:
          e.pos.setValues(t * width, height - e.radius);
        case 2:
          e.pos.setValues(e.radius, t * height);
        default:
          e.pos.setValues(width - e.radius, t * height);
      }
      if (e.pos.distanceTo(player.pos) > 180) break;
    }
    return e;
  }

  Enemy? nearestEnemy() {
    Enemy? best;
    var bestD = double.infinity;
    for (final e in enemies) {
      if (!e.alive) continue;
      final d = e.pos.distanceToSquared(player.pos);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    return best;
  }

  Arrow _obtainArrow() {
    for (final a in _arrowPool) {
      if (!a.alive) return a;
    }
    final a = Arrow();
    _arrowPool.add(a);
    return a;
  }

  /// Size of the arrow pool (live + recycled), exposed for pooling tests.
  int get arrowPoolSize => _arrowPool.length;

  void _fire(double dt) {
    final p = player;
    p.fireTimer -= dt;
    if (p.fireTimer > 0) return;
    final target = nearestEnemy();
    if (target == null) return;
    p.fireTimer = p.fireInterval;
    final dir = (target.pos - p.pos);
    if (dir.length2 == 0) dir.setValues(0, -1);
    dir.normalize();
    p.facing.setFrom(dir);
    final base = math.atan2(dir.y, dir.x);
    const spread = 0.18;
    for (var i = 0; i < p.arrows; i++) {
      final angle = base + (i - (p.arrows - 1) / 2) * spread;
      final a = _obtainArrow()
        ..alive = true
        ..damage = p.damage
        ..pierceLeft = p.pierce
        ..life = 1.6;
      a.hit.clear();
      a.pos.setFrom(p.pos);
      a.vel.setValues(math.cos(angle) * 520, math.sin(angle) * 520);
    }
    events.add(SurvivorEvent(SurvivorEventKind.shoot, p.pos.x, p.pos.y));
  }

  void _updateArrows(double dt) {
    for (final a in _arrowPool) {
      if (!a.alive) continue;
      a.pos.addScaled(a.vel, dt);
      a.life -= dt;
      if (a.life <= 0 || a.pos.x < -20 || a.pos.y < -20 || a.pos.x > width + 20 || a.pos.y > height + 20) {
        a.alive = false;
        continue;
      }
      for (final e in enemies) {
        if (!e.alive || a.hit.contains(e.id)) continue;
        final r = e.radius + 4;
        if (a.pos.distanceToSquared(e.pos) <= r * r) {
          a.hit.add(e.id);
          _damage(e, a.damage);
          if (a.pierceLeft <= 0) {
            a.alive = false;
            break;
          }
          a.pierceLeft--;
        }
      }
    }
  }

  void _damage(Enemy e, double amount) {
    e.hp -= amount;
    e.flash = 0.1;
    if (e.hp <= 0 && e.alive) {
      e.alive = false;
      kills++;
      score += switch (e.kind) {
        EnemyKind.chaser => 10,
        EnemyKind.dasher => 15,
        EnemyKind.spitter => 20,
        EnemyKind.tank => 30,
        EnemyKind.boss => 250,
      };
      events.add(SurvivorEvent(SurvivorEventKind.kill, e.pos.x, e.pos.y, e.kind));
      final dropChance = e.kind == EnemyKind.boss ? 1.0 : 0.06;
      if (_rng.nextDouble() < dropChance) pickups.add(Pickup(e.pos.clone()));
    } else {
      events.add(SurvivorEvent(SurvivorEventKind.hit, e.pos.x, e.pos.y, e.kind));
    }
  }

  void _updateEnemies(double dt) {
    final p = player;
    for (final e in enemies) {
      if (!e.alive) continue;
      if (e.flash > 0) e.flash -= dt;
      final toPlayer = p.pos - e.pos;
      final dist = toPlayer.length;
      final dir = dist > 0 ? toPlayer / dist : Vector2(0, 1);
      var speed = e.speed;
      switch (e.kind) {
        case EnemyKind.dasher:
          e.timer -= dt;
          if (e.dashTime > 0) {
            e.dashTime -= dt;
            e.pos.addScaled(e.vel, dt);
            speed = 0;
          } else if (e.timer <= 0) {
            e.timer = 2.4;
            e.dashTime = 0.4;
            e.vel.setFrom(dir * 300);
          }
        case EnemyKind.spitter:
          if (dist < 170) speed = -e.speed * 0.7;
          if (dist < 230 && dist > 150) speed = 0;
          e.timer -= dt;
          if (e.timer <= 0) {
            e.timer = 2.2;
            _spawnShot(e.pos, dir, 170, 8);
          }
        case EnemyKind.boss:
          e.timer -= dt;
          if (e.timer <= 0) {
            e.timer = 3.0;
            for (var i = 0; i < 12; i++) {
              final ang = i * math.pi / 6 + time;
              _spawnShot(e.pos, Vector2(math.cos(ang), math.sin(ang)), 150, 12);
            }
          }
        case EnemyKind.chaser:
        case EnemyKind.tank:
          break;
      }
      e.pos.addScaled(dir, speed * dt);
      e.pos.x = e.pos.x.clamp(e.radius, width - e.radius);
      e.pos.y = e.pos.y.clamp(e.radius, height - e.radius);
      final touch = e.radius + p.radius;
      if (dist < touch) {
        _hurtPlayer(e.contactDamage);
        // Separate so contact damage is not applied every frame.
        if (dist > 0) e.pos.addScaled(dir, -(touch - dist + 6));
      }
    }
    // Light separation so crowds do not collapse into one blob.
    for (var i = 0; i < enemies.length; i++) {
      final a = enemies[i];
      for (var j = i + 1; j < enemies.length; j++) {
        final b = enemies[j];
        final d = b.pos - a.pos;
        final min = a.radius + b.radius;
        final l2 = d.length2;
        if (l2 > 0 && l2 < min * min) {
          final l = math.sqrt(l2);
          final push = d * ((min - l) / l * 0.5);
          a.pos.sub(push);
          b.pos.add(push);
        }
      }
    }
  }

  void _spawnShot(Vector2 from, Vector2 dir, double speed, double damage) {
    final s = Shot()
      ..damage = damage
      ..alive = true;
    s.pos.setFrom(from);
    s.vel.setFrom(dir.normalized() * speed);
    shots.add(s);
  }

  void _updateShots(double dt) {
    final p = player;
    for (final s in shots) {
      s.pos.addScaled(s.vel, dt);
      if (s.pos.x < -10 || s.pos.y < -10 || s.pos.x > width + 10 || s.pos.y > height + 10) {
        s.alive = false;
      } else if (s.pos.distanceTo(p.pos) < p.radius + 5) {
        s.alive = false;
        _hurtPlayer(s.damage);
      }
    }
    shots.removeWhere((s) => !s.alive);
  }

  void _hurtPlayer(double amount) {
    final p = player;
    if (p.invulnerable > 0) return;
    p.hp -= amount;
    p.invulnerable = 0.6;
    events.add(SurvivorEvent(SurvivorEventKind.hurt, p.pos.x, p.pos.y));
  }

  static const double bladeOrbit = 54;

  Vector2 bladePosition(int i) {
    final ang = bladeAngle + i * 2 * math.pi / math.max(1, player.blades);
    return player.pos + Vector2(math.cos(ang), math.sin(ang)) * bladeOrbit;
  }

  void _updateBlades(double dt) {
    if (player.blades == 0) return;
    bladeAngle += dt * 3.2;
    for (final e in enemies) {
      if (e.bladeCooldown > 0) e.bladeCooldown -= dt;
    }
    for (var i = 0; i < player.blades; i++) {
      final bp = bladePosition(i);
      for (final e in enemies) {
        if (!e.alive || e.bladeCooldown > 0) continue;
        final r = e.radius + 9;
        if (bp.distanceToSquared(e.pos) <= r * r) {
          e.bladeCooldown = 0.35;
          _damage(e, 6 + player.damage * 0.6);
        }
      }
    }
  }

  void _updatePickups(double dt) {
    final p = player;
    for (final k in pickups) {
      k.life -= dt;
      if (k.pos.distanceTo(p.pos) < p.radius + 12) {
        k.life = 0;
        p.hp = math.min(p.maxHp, p.hp + 20);
        events.add(SurvivorEvent(SurvivorEventKind.pickup, k.pos.x, k.pos.y));
      }
    }
    pickups.removeWhere((k) => k.life <= 0);
  }

  List<Upgrade> _rollChoices() {
    final available = Upgrade.values.where((u) => (levels[u] ?? 0) < u.maxLevel && u != Upgrade.heal).toList()
      ..shuffle(_rng);
    final picks = available.take(2).toList();
    // Third card is a heal when hurt, otherwise another upgrade.
    if (player.hp < player.maxHp * 0.6 || available.length < 3) {
      picks.add(Upgrade.heal);
    } else {
      picks.add(available[2]);
    }
    return picks;
  }

  /// Applies the chosen upgrade card and starts the next wave.
  void choose(int index) {
    if (phase != SurvivorPhase.choosing || index < 0 || index >= choices.length) return;
    applyUpgrade(choices[index]);
    events.add(SurvivorEvent(SurvivorEventKind.choose, player.pos.x, player.pos.y));
    choices = const [];
    _beginWave(wave + 1);
  }

  void applyUpgrade(Upgrade u) {
    levels[u] = (levels[u] ?? 0) + 1;
    final p = player;
    switch (u) {
      case Upgrade.multishot:
        p.arrows++;
      case Upgrade.rapid:
        p.fireInterval *= 0.82;
      case Upgrade.pierce:
        p.pierce++;
      case Upgrade.damage:
        p.damage *= 1.3;
      case Upgrade.speed:
        p.speed *= 1.12;
      case Upgrade.vitality:
        p.maxHp += 25;
        p.hp = p.maxHp;
      case Upgrade.blades:
        p.blades++;
      case Upgrade.heal:
        p.hp = math.min(p.maxHp, p.hp + p.maxHp * 0.5);
    }
  }

  // --- Test helpers -------------------------------------------------------

  /// Places an enemy directly (used by tests and tutorials).
  Enemy debugSpawn(EnemyKind kind, double x, double y) {
    final e = _makeEnemy(kind);
    e.pos.setValues(x, y);
    enemies.add(e);
    return e;
  }

  /// Clears pending spawns so tests can control the wave contents.
  void debugClearSpawnQueue() => _toSpawn = 0;
}
