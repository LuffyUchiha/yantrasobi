import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' show Vector2;

/// Pure-Dart rules for Edge Dash. No Flutter/Flame imports: every rule is
/// unit-testable and the simulation is deterministic for a given seed because
/// it advances in fixed steps.
///
/// The hero never walks. A swipe becomes an instant dash along a segment; every
/// foe whose body touches that segment is cut down (segment-vs-circle test),
/// except shieldbearers struck head-on and the boss outside its weak spot.

enum FoeKind { walker, archer, shieldbearer, bomber, boss }

enum DashPhase { fighting, intermission, won, lost }

enum DashEventKind {
  dash,
  slice,
  multiKill,
  blocked,
  bossHit,
  bossDown,
  blast,
  hurt,
  shot,
  waveStart,
  waveClear,
  heal,
}

/// Something that happened, consumed (and cleared) by the renderer for FX/SFX.
class DashEvent {
  const DashEvent(this.kind, this.x, this.y, {this.x2 = 0, this.y2 = 0, this.count = 0, this.foe});
  final DashEventKind kind;
  final double x;
  final double y;
  final double x2;
  final double y2;
  final int count;
  final FoeKind? foe;
}

class Foe {
  Foe(this.id, this.kind);
  final int id;
  final FoeKind kind;
  final Vector2 pos = Vector2.zero();

  /// Unit vector the foe looks along. For shieldbearers this is where the
  /// shield points; it turns toward the hero at a limited rate.
  final Vector2 facing = Vector2(0, 1);
  double radius = 13;
  double speed = 38;
  int hp = 1;
  int maxHp = 1;
  double timer = 0;
  double timer2 = 0;
  double stun = 0;
  double flash = 0;
  bool alive = true;

  /// Boss only: centre angle of the rotating weak-spot arc and its spin.
  double weakAngle = 0;
  double weakSpin = 1.1;
  double hitCooldown = 0;

  int get points => switch (kind) {
    FoeKind.walker => 10,
    FoeKind.archer => 15,
    FoeKind.bomber => 15,
    FoeKind.shieldbearer => 25,
    FoeKind.boss => 0,
  };
}

/// A slow enemy projectile.
class Bolt {
  Bolt(double x, double y, double vx, double vy) : pos = Vector2(x, y), vel = Vector2(vx, vy);
  final Vector2 pos;
  final Vector2 vel;
  double radius = 5;
  bool alive = true;
}

/// Explosion left by a slain bomber. Dashing through it while [active] hurts.
class Blast {
  Blast(double x, double y) : pos = Vector2(x, y);
  final Vector2 pos;
  double age = 0;
  bool get active => age < DashWorld.blastWindow;
}

/// The resolved geometry of a dash, computed without changing the world.
class DashPlan {
  final Vector2 from = Vector2.zero();
  final Vector2 to = Vector2.zero();
  final Vector2 dir = Vector2.zero();

  /// The swipe this plan was made from, so it can be replayed with [DashWorld.dash].
  double dx = 0;
  double dy = 0;

  /// Whether the swipe was long enough to dash at all.
  bool valid = false;
  double length = 0;
  final List<Foe> sliced = [];

  /// A shieldbearer hit head-on, or the boss, which stops the dash.
  Foe? blockedBy;
  bool bossWeakHit = false;
  bool crossesBlast = false;
}

class DashWorld {
  DashWorld({required double width, required double height, int seed = 1, int startWave = 1})
    : _rng = math.Random(seed) {
    resize(width, height);
    hero.setValues(width / 2, height / 2);
    _beginWave(startWave);
  }

  static const double heroRadius = 12;
  static const double bladeHalfWidth = 6;
  static const double dashCooldown = 0.15;
  static const double maxDashFraction = 0.4;
  static const double minDash = 10;
  static const double invulnTime = 1.0;
  static const double comboWindow = 1.0;
  static const double blastRadius = 64;
  static const double blastWindow = 0.3;

  /// A shield blocks when the dash heads into its face within 60 degrees.
  static const double shieldCos = 0.5;
  static const double shieldTurnRate = 1.5;
  static const double bossWeakHalfArc = 0.55;
  static const int maxHearts = 3;
  static const int finalWave = 12;
  static const int bossWave = 13;
  static const double step = 1 / 60;
  static const double _recoil = 10;

  final math.Random _rng;
  double width = 0;
  double height = 0;

  final Vector2 hero = Vector2.zero();
  int hearts = maxHearts;
  double invulnerable = 0;
  double cooldown = 0;

  final List<Foe> foes = [];
  final List<Bolt> bolts = [];
  final List<Blast> blasts = [];
  final List<FoeKind> _queue = [];
  final List<DashEvent> events = [];

  DashPhase phase = DashPhase.fighting;
  int wave = 1;
  int score = 0;
  int kills = 0;
  int dashes = 0;
  int bestMultiKill = 0;
  int combo = 0;
  double comboTimer = 0;
  double time = 0;
  double _phaseTimer = 0;
  double _spawnTimer = 0;
  double _acc = 0;
  int _nextId = 1;

  bool get isOver => phase == DashPhase.won || phase == DashPhase.lost;
  bool get won => phase == DashPhase.won;
  bool get isBossWave => wave == bossWave;
  double get maxDash => width * maxDashFraction;
  int get entityCount => foes.length + bolts.length + blasts.length + 1;
  int get remainingInWave => foes.length + _queue.length;
  Foe? get boss {
    for (final f in foes) {
      if (f.kind == FoeKind.boss) return f;
    }
    return null;
  }

  void resize(double w, double h) {
    width = math.max(120, w);
    height = math.max(160, h);
    _clampInside(hero, heroRadius);
    for (final f in foes) {
      _clampInside(f.pos, f.radius);
    }
  }

  void _clampInside(Vector2 p, double r) {
    p.x = p.x.clamp(r, math.max(r, width - r)).toDouble();
    p.y = p.y.clamp(r, math.max(r, height - r)).toDouble();
  }

  void _emit(DashEvent e) {
    if (events.length > 256) events.removeRange(0, 128);
    events.add(e);
  }

  // ------------------------------------------------------------------ waves

  /// Foes of wave [n] (bosses excluded), in a fixed order before shuffling.
  static List<FoeKind> waveRoster(int n) {
    final walkers = 3 + n + n ~/ 3;
    final archers = n >= 3 ? 1 + (n - 3) ~/ 3 : 0;
    final bombers = n >= 4 ? 1 + (n - 4) ~/ 3 : 0;
    final shields = n >= 5 ? 1 + (n - 5) ~/ 3 : 0;
    return [
      for (var i = 0; i < walkers; i++) FoeKind.walker,
      for (var i = 0; i < archers; i++) FoeKind.archer,
      for (var i = 0; i < bombers; i++) FoeKind.bomber,
      for (var i = 0; i < shields; i++) FoeKind.shieldbearer,
    ];
  }

  static double spawnInterval(int n) => math.max(0.45, 1.3 - 0.06 * n);

  void _beginWave(int n) {
    wave = n;
    phase = DashPhase.fighting;
    bolts.clear();
    _queue.clear();
    if (n >= bossWave) {
      final b = _makeFoe(FoeKind.boss);
      final top = hero.y > height / 2;
      b.pos.setValues(width / 2, top ? b.radius + 24 : height - b.radius - 24);
      foes.add(b);
    } else {
      final roster = waveRoster(n);
      // Fisher-Yates with the world RNG, but keep the first two as walkers so
      // every wave opens gently.
      for (var i = roster.length - 1; i > 2; i--) {
        final j = 2 + _rng.nextInt(i - 1);
        final t = roster[i];
        roster[i] = roster[j];
        roster[j] = t;
      }
      _queue.addAll(roster);
    }
    _spawnTimer = 1.0;
    _emit(DashEvent(DashEventKind.waveStart, width / 2, height / 2, count: n));
  }

  Foe _makeFoe(FoeKind kind) {
    final f = Foe(_nextId++, kind);
    final scale = 1 + 0.04 * (math.min(wave, finalWave) - 1);
    switch (kind) {
      case FoeKind.walker:
        f.radius = 13;
        f.speed = 42 * scale;
      case FoeKind.archer:
        f.radius = 12;
        f.speed = 45 * scale;
        f.timer = 1.6 + _rng.nextDouble() * 0.8;
      case FoeKind.shieldbearer:
        f.radius = 15;
        f.speed = 32 * scale;
      case FoeKind.bomber:
        f.radius = 12;
        f.speed = 55 * scale;
      case FoeKind.boss:
        f.radius = 46;
        f.speed = 22;
        f.hp = 6;
        f.maxHp = 6;
        f.timer = 2.5;
        f.timer2 = 5;
        f.weakAngle = _rng.nextDouble() * math.pi * 2;
    }
    return f;
  }

  void _spawnFromEdge(FoeKind kind) {
    final f = _makeFoe(kind);
    final r = f.radius;
    var x = 0.0;
    var y = 0.0;
    for (var attempt = 0; attempt < 6; attempt++) {
      switch (_rng.nextInt(4)) {
        case 0:
          x = r + _rng.nextDouble() * (width - 2 * r);
          y = r;
        case 1:
          x = r + _rng.nextDouble() * (width - 2 * r);
          y = height - r;
        case 2:
          x = r;
          y = r + _rng.nextDouble() * (height - 2 * r);
        default:
          x = width - r;
          y = r + _rng.nextDouble() * (height - 2 * r);
      }
      final dx = x - hero.x;
      final dy = y - hero.y;
      if (dx * dx + dy * dy > 150 * 150) break;
    }
    f.pos.setValues(x, y);
    _faceHero(f, 1e9);
    foes.add(f);
  }

  // ----------------------------------------------------------------- update

  void update(double dt) {
    // Long hitches are capped so a resumed app never fast-forwards much.
    _acc += math.min(dt, 2.0);
    while (_acc >= step) {
      _acc -= step;
      _step(step);
    }
  }

  void _step(double dt) {
    if (isOver) return;
    time += dt;
    if (cooldown > 0) cooldown = math.max(0, cooldown - dt);
    if (invulnerable > 0) invulnerable = math.max(0, invulnerable - dt);
    if (comboTimer > 0) {
      comboTimer -= dt;
      if (comboTimer <= 0) {
        comboTimer = 0;
        combo = 0;
      }
    }
    for (final b in blasts) {
      b.age += dt;
    }
    blasts.removeWhere((b) => b.age >= 0.5);

    if (phase == DashPhase.intermission) {
      _phaseTimer -= dt;
      if (_phaseTimer <= 0) _beginWave(wave + 1);
      return;
    }

    if (_queue.isNotEmpty) {
      _spawnTimer -= dt;
      if (_spawnTimer <= 0) {
        _spawnFromEdge(_queue.removeAt(0));
        _spawnTimer = spawnInterval(wave);
      }
    }

    // Index loop: the boss may summon minions while foes update.
    for (var i = 0; i < foes.length; i++) {
      _updateFoe(foes[i], dt);
    }
    _contacts();
    _updateBolts(dt);
    foes.removeWhere((f) => !f.alive);

    if (phase == DashPhase.fighting && _queue.isEmpty && foes.isEmpty && !isBossWave && !debugHoldWave) {
      score += 50 * wave;
      bolts.clear();
      _emit(DashEvent(DashEventKind.waveClear, width / 2, height / 2, count: wave));
      if (wave % 4 == 0 && hearts < maxHearts) {
        hearts++;
        _emit(DashEvent(DashEventKind.heal, hero.x, hero.y));
      }
      phase = DashPhase.intermission;
      _phaseTimer = 1.6;
    }
  }

  void _faceHero(Foe f, double maxTurn) {
    final dx = hero.x - f.pos.x;
    final dy = hero.y - f.pos.y;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < 1e-6) return;
    final target = math.atan2(dy, dx);
    final cur = math.atan2(f.facing.y, f.facing.x);
    var diff = _wrap(target - cur);
    if (diff.abs() > maxTurn) diff = diff.sign * maxTurn;
    final a = cur + diff;
    f.facing.setValues(math.cos(a), math.sin(a));
  }

  static double _wrap(double a) {
    var x = a % (math.pi * 2);
    if (x > math.pi) x -= math.pi * 2;
    if (x < -math.pi) x += math.pi * 2;
    return x;
  }

  void _updateFoe(Foe f, double dt) {
    if (f.flash > 0) f.flash -= dt;
    if (f.hitCooldown > 0) f.hitCooldown -= dt;
    if (f.kind == FoeKind.boss) f.weakAngle = _wrap(f.weakAngle + f.weakSpin * dt);
    if (f.stun > 0) {
      f.stun -= dt;
      return;
    }
    _faceHero(f, f.kind == FoeKind.shieldbearer ? shieldTurnRate * dt : 1e9);
    final dx = hero.x - f.pos.x;
    final dy = hero.y - f.pos.y;
    final dist = math.sqrt(dx * dx + dy * dy);
    final ux = dist > 1e-6 ? dx / dist : 0.0;
    final uy = dist > 1e-6 ? dy / dist : 0.0;
    var move = 0.0;
    switch (f.kind) {
      case FoeKind.walker:
      case FoeKind.bomber:
      case FoeKind.shieldbearer:
        move = f.speed;
      case FoeKind.archer:
        if (dist > 230) {
          move = f.speed;
        } else if (dist < 140) {
          move = -f.speed;
        }
        f.timer -= dt;
        if (f.timer <= 0 && dist < 340) {
          _fire(f.pos.x + ux * f.radius, f.pos.y + uy * f.radius, ux, uy, 120);
          f.timer = 2.3 + _rng.nextDouble() * 0.6;
        }
      case FoeKind.boss:
        if (dist > f.radius + 80) move = f.speed;
        f.timer -= dt;
        if (f.timer <= 0) {
          const n = 10;
          final off = _rng.nextDouble() * math.pi * 2;
          for (var i = 0; i < n; i++) {
            final a = off + i * math.pi * 2 / n;
            final cx = math.cos(a);
            final cy = math.sin(a);
            _fire(f.pos.x + cx * f.radius, f.pos.y + cy * f.radius, cx, cy, 90);
          }
          f.timer = 3.4;
        }
        f.timer2 -= dt;
        if (f.timer2 <= 0) {
          _spawnFromEdge(FoeKind.walker);
          _spawnFromEdge(f.hp <= 3 ? FoeKind.bomber : FoeKind.walker);
          f.timer2 = 7;
        }
    }
    f.pos.x += ux * move * dt;
    f.pos.y += uy * move * dt;
    _clampInside(f.pos, f.radius);
  }

  void _fire(double x, double y, double ux, double uy, double speed) {
    bolts.add(Bolt(x, y, ux * speed, uy * speed));
    _emit(DashEvent(DashEventKind.shot, x, y));
  }

  void _contacts() {
    for (final f in foes) {
      if (!f.alive) continue;
      final dx = f.pos.x - hero.x;
      final dy = f.pos.y - hero.y;
      final reach = f.radius + heroRadius;
      final d2 = dx * dx + dy * dy;
      if (d2 >= reach * reach) continue;
      if (!_hurt()) continue;
      final d = math.max(1e-6, math.sqrt(d2));
      if (f.kind == FoeKind.boss) {
        // The hero is thrown clear of the boss.
        final push = f.radius + heroRadius + 40;
        hero.setValues(f.pos.x - dx / d * push, f.pos.y - dy / d * push);
        _clampInside(hero, heroRadius);
      } else if (f.kind == FoeKind.bomber) {
        // A bomber that reaches you detonates (no score).
        f.alive = false;
        _addBlast(f.pos.x, f.pos.y);
      } else {
        f.pos.x += dx / d * 40;
        f.pos.y += dy / d * 40;
        f.stun = 0.3;
        _clampInside(f.pos, f.radius);
      }
    }
  }

  void _updateBolts(double dt) {
    final reach = heroRadius;
    for (final b in bolts) {
      b.pos.x += b.vel.x * dt;
      b.pos.y += b.vel.y * dt;
      if (b.pos.x < -20 || b.pos.y < -20 || b.pos.x > width + 20 || b.pos.y > height + 20) {
        b.alive = false;
        continue;
      }
      final dx = b.pos.x - hero.x;
      final dy = b.pos.y - hero.y;
      final r = reach + b.radius;
      if (dx * dx + dy * dy < r * r && _hurt()) b.alive = false;
    }
    bolts.removeWhere((b) => !b.alive);
  }

  /// Costs a heart unless invulnerable. Returns whether it did.
  bool _hurt() {
    if (invulnerable > 0 || isOver) return false;
    hearts--;
    invulnerable = invulnTime;
    combo = 0;
    comboTimer = 0;
    _emit(DashEvent(DashEventKind.hurt, hero.x, hero.y, count: hearts));
    if (hearts <= 0) {
      hearts = 0;
      phase = DashPhase.lost;
    }
    return true;
  }

  // ------------------------------------------------------------------- dash

  /// Whether a shield facing [facing] stops a dash travelling along [dir]
  /// (both unit vectors): only a head-on strike within 60 degrees is blocked;
  /// side and rear strikes cut through.
  static bool shieldBlocks(Vector2 dir, Vector2 facing) => dir.dot(facing) < -shieldCos;

  /// Whether a dash entering the boss at [x],[y] lands in its weak-spot arc.
  static bool inWeakArc(Foe boss, double x, double y) {
    final a = math.atan2(y - boss.pos.y, x - boss.pos.x);
    return _wrap(a - boss.weakAngle).abs() <= bossWeakHalfArc;
  }

  /// Shortest distance from point (px,py) to the segment a-b.
  static double segmentPointDistance(double ax, double ay, double bx, double by, double px, double py) {
    final vx = bx - ax;
    final vy = by - ay;
    final l2 = vx * vx + vy * vy;
    var t = l2 > 0 ? ((px - ax) * vx + (py - ay) * vy) / l2 : 0.0;
    t = t.clamp(0.0, 1.0);
    final cx = ax + vx * t - px;
    final cy = ay + vy * t - py;
    return math.sqrt(cx * cx + cy * cy);
  }

  static double _rayLimit(double p, double u, double lo, double hi) {
    if (u > 1e-9) return math.max(0, (hi - p) / u);
    if (u < -1e-9) return math.max(0, (lo - p) / u);
    return double.infinity;
  }

  /// Resolves the dash a swipe of ([dx],[dy]) would make, without applying it:
  /// the length is clamped to [maxDash] and to the arena, then foes along the
  /// segment are collected in order until a shield or the boss stops it.
  DashPlan planDash(double dx, double dy) {
    final plan = DashPlan()
      ..dx = dx
      ..dy = dy;
    plan.from.setFrom(hero);
    plan.to.setFrom(hero);
    final raw = math.sqrt(dx * dx + dy * dy);
    if (raw < minDash) return plan;
    final ux = dx / raw;
    final uy = dy / raw;
    plan.dir.setValues(ux, uy);
    var len = math.min(raw, maxDash);
    len = math.min(len, _rayLimit(hero.x, ux, heroRadius, width - heroRadius));
    len = math.min(len, _rayLimit(hero.y, uy, heroRadius, height - heroRadius));
    plan.valid = true;

    final hits = <(Foe, double)>[];
    for (final f in foes) {
      if (!f.alive) continue;
      final rad = f.radius + bladeHalfWidth;
      final rx = f.pos.x - hero.x;
      final ry = f.pos.y - hero.y;
      final proj = rx * ux + ry * uy;
      final t = proj.clamp(0.0, len);
      final cx = hero.x + ux * t - f.pos.x;
      final cy = hero.y + uy * t - f.pos.y;
      if (cx * cx + cy * cy > rad * rad) continue;
      final perp2 = math.max(0.0, rx * rx + ry * ry - proj * proj);
      final entry = math.max(0.0, proj - math.sqrt(math.max(0.0, rad * rad - perp2)));
      hits.add((f, entry));
    }
    hits.sort((a, b) => a.$2.compareTo(b.$2));
    var end = len;
    for (final (f, entry) in hits) {
      if (f.kind == FoeKind.boss) {
        plan.blockedBy = f;
        plan.bossWeakHit = f.hitCooldown <= 0 && inWeakArc(f, hero.x + ux * entry, hero.y + uy * entry);
        end = math.max(0, entry - _recoil);
        break;
      }
      if (f.kind == FoeKind.shieldbearer && shieldBlocks(plan.dir, f.facing)) {
        plan.blockedBy = f;
        end = math.max(0, entry - _recoil);
        break;
      }
      plan.sliced.add(f);
    }
    plan.length = end;
    plan.to.setValues(hero.x + ux * end, hero.y + uy * end);
    for (final b in blasts) {
      if (!b.active) continue;
      if (segmentPointDistance(plan.from.x, plan.from.y, plan.to.x, plan.to.y, b.pos.x, b.pos.y) <=
          blastRadius) {
        plan.crossesBlast = true;
        break;
      }
    }
    return plan;
  }

  /// Dashes along the swipe ([dx],[dy]). Returns false if on cooldown, the
  /// run is over or the swipe is too short.
  bool dash(double dx, double dy) {
    if (isOver || cooldown > 0) return false;
    final plan = planDash(dx, dy);
    if (!plan.valid) return false;
    hero.setFrom(plan.to);
    cooldown = dashCooldown;
    dashes++;
    _emit(
      DashEvent(
        DashEventKind.dash,
        plan.from.x,
        plan.from.y,
        x2: plan.to.x,
        y2: plan.to.y,
        count: plan.sliced.length,
      ),
    );
    // Any dash inside the combo window keeps the combo alive.
    if (comboTimer > 0) comboTimer = comboWindow;
    if (plan.crossesBlast) _hurt();
    if (isOver) return true;

    final blocker = plan.blockedBy;
    if (blocker != null) {
      if (blocker.kind == FoeKind.boss && plan.bossWeakHit) {
        blocker.hp--;
        blocker.flash = 0.25;
        blocker.hitCooldown = 0.5;
        blocker.weakSpin = -blocker.weakSpin * 1.15;
        score += 150 * math.max(1, combo);
        _emit(DashEvent(DashEventKind.bossHit, plan.to.x, plan.to.y, count: blocker.hp));
        if (blocker.hp <= 0) {
          blocker.alive = false;
          score += 1500;
          kills++;
          _emit(DashEvent(DashEventKind.bossDown, blocker.pos.x, blocker.pos.y));
          foes.removeWhere((f) => !f.alive);
          bolts.clear();
          phase = DashPhase.won;
          return true;
        }
      } else {
        blocker.flash = 0.15;
        if (blocker.kind != FoeKind.boss) {
          blocker.pos.x += plan.dir.x * 26;
          blocker.pos.y += plan.dir.y * 26;
          blocker.stun = 0.4;
          _clampInside(blocker.pos, blocker.radius);
        }
        _emit(DashEvent(DashEventKind.blocked, plan.to.x, plan.to.y, foe: blocker.kind));
      }
    }

    var killed = 0;
    var base = 0;
    final pending = <Foe>[];
    void kill(Foe f) {
      f.alive = false;
      killed++;
      base += f.points;
      _emit(DashEvent(DashEventKind.slice, f.pos.x, f.pos.y, foe: f.kind));
      if (f.kind == FoeKind.bomber) pending.add(f);
    }

    for (final f in plan.sliced) {
      if (f.alive) kill(f);
    }
    // Bomber chain reactions: blasts cut down nearby foes (never the boss).
    while (pending.isNotEmpty) {
      final b = pending.removeLast();
      _addBlast(b.pos.x, b.pos.y);
      for (final f in foes) {
        if (!f.alive || f.kind == FoeKind.boss) continue;
        final r = blastRadius + f.radius;
        if (f.pos.distanceToSquared(b.pos) <= r * r) kill(f);
      }
    }
    if (killed > 0) {
      combo = math.min(combo + 1, 9);
      comboTimer = comboWindow;
      score += base * killed * combo;
      kills += killed;
      if (killed > bestMultiKill) bestMultiKill = killed;
      if (killed >= 2) {
        _emit(DashEvent(DashEventKind.multiKill, plan.to.x, plan.to.y, count: killed));
      }
      foes.removeWhere((f) => !f.alive);
    }
    return true;
  }

  void _addBlast(double x, double y) {
    blasts.add(Blast(x, y));
    _emit(DashEvent(DashEventKind.blast, x, y));
  }

  /// Score multiplier the next killing dash of [killCount] foes would get.
  int nextMultiplier(int killCount) => killCount * math.min(combo + 1, 9);

  // ------------------------------------------------------------ test helpers

  /// When true an empty arena does not count as a cleared wave.
  bool debugHoldWave = false;

  /// Empties the spawn queue so tests can place foes by hand.
  void debugClearSpawnQueue() => _queue.clear();

  Foe debugSpawn(FoeKind kind, double x, double y) {
    final f = _makeFoe(kind);
    f.pos.setValues(x, y);
    _faceHero(f, 1e9);
    foes.add(f);
    return f;
  }

  Bolt debugBolt(double x, double y, double vx, double vy) {
    final b = Bolt(x, y, vx, vy);
    bolts.add(b);
    return b;
  }

  /// Jumps straight to wave [n] (13 = boss) with a fresh roster.
  void debugStartWave(int n) {
    foes.clear();
    _beginWave(n);
  }
}
