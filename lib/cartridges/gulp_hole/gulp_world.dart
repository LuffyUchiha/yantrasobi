import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' show Vector2;

/// Pure-Dart rules for Gulp Hole. No Flutter/Flame imports, so every rule is
/// unit-testable and deterministic for a given seed.
///
/// The arena is a city grid much larger than the screen. Holes (the player and
/// a few rivals) roam the streets swallowing anything whose centre falls inside
/// them and whose footprint is small enough, growing level by level.

enum ObjTier {
  pebble('Pebble', 6, 1, 10, false),
  cone('Cone', 9, 2, 20, true),
  bench('Bench', 15, 4, 40, false),
  car('Car', 25, 8, 80, true),
  kiosk('Kiosk', 37, 14, 150, false),
  tree('Tree', 49, 22, 250, false),
  house('House', 70, 40, 500, false);

  const ObjTier(this.label, this.radius, this.xp, this.points, this.onRoad);
  final String label;

  /// Footprint radius in world units.
  final double radius;

  /// Growth gained by the hole that swallows it.
  final int xp;

  /// Score for the player.
  final int points;

  /// Placed on the streets rather than inside blocks.
  final bool onRoad;
}

enum GulpPhase { playing, won, lost }

enum GulpEventKind { swallow, levelUp, eatHole, playerEaten, respawn, timeUp, cityCleared }

/// Something that happened this tick, consumed by the renderer for SFX/FX.
class GulpEvent {
  const GulpEvent(this.kind, this.x, this.y, {this.byPlayer = false, this.tier, this.holeId = -1});
  final GulpEventKind kind;
  final double x;
  final double y;
  final bool byPlayer;
  final ObjTier? tier;
  final int holeId;
}

class CityObject {
  CityObject(this.id, this.tier, double x, double y, this.angle, this.variant)
    : pos = Vector2(x, y),
      radius = tier.radius;
  final int id;
  final ObjTier tier;
  final Vector2 pos;
  final double radius;

  /// Orientation in radians (cars follow their street).
  final double angle;

  /// Cosmetic variation (colour pick) for the renderer.
  final int variant;
  bool alive = true;

  /// Seconds left in the "falling in" animation after being swallowed.
  double sink = 0;

  /// Hole that swallowed this object (for the sink animation).
  int sinkHole = -1;
}

class Hole {
  Hole(this.id, this.name, {this.isPlayer = false});
  final int id;
  final String name;
  final bool isPlayer;
  final Vector2 pos = Vector2.zero();

  /// Current steering direction (length <= 1).
  final Vector2 steer = Vector2.zero();

  /// Rendered/physical radius; eases toward [targetRadius].
  double radius = GulpWorld.baseRadius;
  int xp = 0;
  int level = 0;
  int swallowed = 0;
  int holesEaten = 0;
  bool alive = true;
  double respawnTimer = 0;

  /// Grace time during which the hole cannot be eaten (round start for the
  /// player, a moment after respawning for rivals).
  double shield = 0;

  /// Fractional growth carried between swallows (rivals grow more slowly).
  double xpCarry = 0;

  // AI state.
  double thinkTimer = 0;

  /// Seconds spent chasing the player in the current hunt.
  double huntTime = 0;

  /// While positive, this rival ignores the player and feeds on objects.
  double huntCooldown = 0;
  double wanderTimer = 0;
  final Vector2 wander = Vector2(1, 0);
  CityObject? target;

  double get targetRadius => GulpWorld.radiusForLevel(level);
  double get speed => GulpWorld.baseSpeed + radius * 0.7;

  bool canSwallowObject(CityObject o) => o.radius <= radius * GulpWorld.swallowRatio;

  /// A hole can eat another hole that is at least 20% smaller than itself.
  bool canEatHole(Hole other) =>
      other.alive && other.shield <= 0 && other.radius <= radius * GulpWorld.holeEatRatio;
}

class GulpWorld {
  GulpWorld({
    this.width = 1600,
    this.height = 2600,
    int seed = 1,
    this.rivalCount = 3,
    this.roundTime = 90,
    this.populate = true,
  }) : _rng = math.Random(seed) {
    player = Hole(0, 'You', isPlayer: true);
    holes.add(player);
    for (var i = 0; i < rivalCount; i++) {
      holes.add(Hole(i + 1, rivalNames[i % rivalNames.length]));
    }
    _placeHolesAtStart();
    if (populate) _scatterCity();
    for (final o in objects) {
      totalXp += o.tier.xp;
    }
  }

  static const double baseRadius = 22;
  static const double radiusPerLevel = 6;
  static const double swallowRatio = 0.9;
  static const double holeEatRatio = 0.8;
  static const double baseSpeed = 160;
  static const double rivalSpeedFactor = 0.9;
  static const double rivalRespawnDelay = 4;
  static const double cityWinShare = 0.6;

  /// Seconds at the start of a round during which the player cannot be eaten.
  static const double playerGraceTime = 20;

  /// Rivals only hunt the player when their radius is at least this much bigger...
  static const double huntSizeRatio = 1.35;

  /// ...and the player is within this distance.
  static const double huntRange = 220;

  /// Rivals gain this fraction of the growth the player would for the same meal.
  static const double rivalGrowthFactor = 0.7;

  /// Rivals stalk the player at this fraction of the player's speed, so an
  /// attentive player can always slip away.
  static const double huntSpeedFactor = 0.7;

  /// How far inside a rival the player's centre must be (in player radii from
  /// the rival's rim) before it is swallowed.
  static const double playerSwallowDepth = 0.7;

  /// A rival gives up a hunt on the player after this many seconds...
  static const double huntGiveUp = 2;

  /// ...and then leaves the player alone for this long.
  static const double huntRest = 6;

  /// Rivals (re)spawn at least this far from the player.
  static const double rivalMinSpawnDistance = 700;
  static const int blocksX = 4;
  static const int blocksY = 6;
  static const double roadWidth = 70;
  static const List<String> rivalNames = ['Mauve', 'Saffron', 'Teal'];

  static const Map<ObjTier, int> tierCounts = {
    ObjTier.pebble: 60,
    ObjTier.cone: 34,
    ObjTier.bench: 30,
    ObjTier.car: 28,
    ObjTier.kiosk: 16,
    ObjTier.tree: 22,
    ObjTier.house: 10,
  };

  /// Radius reached at [level].
  static double radiusForLevel(int level) => baseRadius + radiusPerLevel * level;

  /// Cumulative XP needed to reach [level].
  static int xpForLevel(int level) => 4 * level * (level + 1);

  final math.Random _rng;
  final double width;
  final double height;
  final int rivalCount;
  final double roundTime;
  final bool populate;

  late final Hole player;
  final List<Hole> holes = [];
  final List<CityObject> objects = [];
  final List<GulpEvent> events = [];

  /// Joystick input; length is clamped to 1.
  final Vector2 input = Vector2.zero();

  GulpPhase phase = GulpPhase.playing;
  int score = 0;
  int totalXp = 0;
  int playerXpFromCity = 0;
  double time = 0;
  int _nextId = 0;
  bool _endedByCity = false;

  /// The hole that swallowed the player, if the round ended that way.
  Hole? eatenBy;

  double get blockW => width / blocksX;
  double get blockH => height / blocksY;
  double get timeLeft => math.max(0, roundTime - time);
  bool get isOver => phase == GulpPhase.won || phase == GulpPhase.lost;
  bool get endedByCity => _endedByCity;
  int get aliveObjects {
    var n = 0;
    for (final o in objects) {
      if (o.alive) n++;
    }
    return n;
  }

  int get entityCount {
    var n = aliveObjects;
    for (final h in holes) {
      if (h.alive) n++;
    }
    return n;
  }

  Iterable<Hole> get rivals => holes.where((h) => !h.isPlayer);

  /// Share of the city's total XP that the player has swallowed (0..1).
  double get cityShare => totalXp == 0 ? 0 : playerXpFromCity / totalXp;

  /// 1-based size rank of the player among live holes (ties favour the player).
  int get playerRank {
    var rank = 1;
    for (final h in holes) {
      if (h.isPlayer || !h.alive) continue;
      if (_sizeKey(h) > _sizeKey(player)) rank++;
    }
    return rank;
  }

  static double _sizeKey(Hole h) => h.xp + h.radius * 1e-3;

  // --- Setup -------------------------------------------------------------

  void _placeHolesAtStart() {
    player.pos.setValues(width / 2, height / 2);
    player.shield = playerGraceTime;
    final spots = [
      Vector2(width * 0.2, height * 0.15),
      Vector2(width * 0.8, height * 0.85),
      Vector2(width * 0.8, height * 0.15),
      Vector2(width * 0.2, height * 0.85),
    ];
    for (final h in rivals) {
      h.pos.setFrom(spots[(h.id - 1) % spots.length]);
      h.wanderTimer = _rng.nextDouble();
    }
  }

  /// Distance from (x, y) to the nearest road centre line on each axis.
  double _roadDistX(double x) {
    final m = x % blockW;
    return math.min(m, blockW - m);
  }

  double _roadDistY(double y) {
    final m = y % blockH;
    return math.min(m, blockH - m);
  }

  bool isRoad(double x, double y) => _roadDistX(x) < roadWidth / 2 || _roadDistY(y) < roadWidth / 2;

  void _scatterCity() {
    // Largest first so big buildings get room.
    for (final tier in ObjTier.values.reversed) {
      final n = tierCounts[tier]!;
      for (var i = 0; i < n; i++) {
        _tryPlace(tier);
      }
    }
  }

  void _tryPlace(ObjTier tier) {
    final r = tier.radius;
    for (var attempt = 0; attempt < 40; attempt++) {
      double x, y, angle = 0;
      if (tier.onRoad) {
        // Pick a street (vertical or horizontal) and a lane on it.
        final vertical = _rng.nextBool();
        final lane = (_rng.nextDouble() - 0.5) * (roadWidth - r * 1.2);
        if (vertical) {
          final k = 1 + _rng.nextInt(blocksX - 1);
          x = k * blockW + lane;
          y = r + _rng.nextDouble() * (height - 2 * r);
          angle = math.pi / 2;
        } else {
          final k = 1 + _rng.nextInt(blocksY - 1);
          y = k * blockH + lane;
          x = r + _rng.nextDouble() * (width - 2 * r);
        }
      } else {
        x = r + _rng.nextDouble() * (width - 2 * r);
        y = r + _rng.nextDouble() * (height - 2 * r);
        // Buildings and trees stay off the streets.
        final margin = roadWidth / 2 + (tier.index >= ObjTier.kiosk.index ? r * 0.75 : r * 0.3);
        if (_roadDistX(x) < margin || _roadDistY(y) < margin) continue;
        angle = (_rng.nextDouble() - 0.5) * 0.3;
      }
      final variant = _rng.nextInt(4);
      if (!_isFree(x, y, r)) continue;
      objects.add(CityObject(_nextId++, tier, x, y, angle, variant));
      return;
    }
  }

  bool _isFree(double x, double y, double r) {
    for (final h in holes) {
      final dx = h.pos.x - x, dy = h.pos.y - y;
      final min = r + 70;
      if (dx * dx + dy * dy < min * min) return false;
    }
    for (final o in objects) {
      final dx = o.pos.x - x, dy = o.pos.y - y;
      final min = r + o.radius + 4;
      if (dx * dx + dy * dy < min * min) return false;
    }
    return true;
  }

  // --- Simulation ---------------------------------------------------------

  /// Advances the simulation. Large steps are subdivided for stable collisions.
  void update(double dt) {
    events.clear();
    if (isOver) {
      _updateSinking(dt);
      return;
    }
    var remaining = math.min(dt, 0.25);
    while (remaining > 1e-9) {
      final step = math.min(remaining, 1 / 60);
      _step(step);
      remaining -= step;
      if (isOver) break;
    }
  }

  void _step(double dt) {
    time += dt;
    _updateSinking(dt);
    if (input.length2 > 1) input.normalize();
    player.steer.setFrom(input);
    for (final h in holes) {
      if (!h.alive) {
        h.respawnTimer -= dt;
        if (h.respawnTimer <= 0) _respawn(h);
        continue;
      }
      if (h.shield > 0) h.shield -= dt;
      if (!h.isPlayer) _think(h, dt);
      _move(h, dt);
    }
    for (final h in holes) {
      if (h.alive) _swallowObjects(h);
    }
    _holeInteractions();
    if (phase == GulpPhase.lost) return;
    if (cityShare >= cityWinShare) {
      _endedByCity = true;
      phase = GulpPhase.won;
      events.add(GulpEvent(GulpEventKind.cityCleared, player.pos.x, player.pos.y, byPlayer: true));
      return;
    }
    if (time >= roundTime) {
      time = roundTime;
      phase = playerRank == 1 ? GulpPhase.won : GulpPhase.lost;
      events.add(GulpEvent(GulpEventKind.timeUp, player.pos.x, player.pos.y, byPlayer: true));
    }
  }

  void _updateSinking(double dt) {
    for (final o in objects) {
      if (o.sink <= 0) continue;
      o.sink -= dt;
      if (o.sinkHole >= 0 && o.sinkHole < holes.length) {
        final h = holes[o.sinkHole];
        // Slide toward the centre of the hole as it falls.
        final k = math.min(1.0, dt * 10);
        o.pos.x += (h.pos.x - o.pos.x) * k;
        o.pos.y += (h.pos.y - o.pos.y) * k;
      }
    }
  }

  void _move(Hole h, double dt) {
    final s = h.steer;
    if (s.length2 > 1) s.normalize();
    final speed = h.isPlayer ? h.speed : h.speed * (h.huntTime > 0 ? huntSpeedFactor : rivalSpeedFactor);
    if (s.length2 > 0.0004) h.pos.addScaled(s, speed * dt);
    // Ease radius toward the level's size.
    h.radius += (h.targetRadius - h.radius) * math.min(1.0, dt * 5);
    // Objects too big to swallow block the hole's centre a little.
    for (final o in objects) {
      if (!o.alive || h.canSwallowObject(o)) continue;
      final block = o.radius * 0.7;
      final dx = h.pos.x - o.pos.x, dy = h.pos.y - o.pos.y;
      final d2 = dx * dx + dy * dy;
      if (d2 < block * block) {
        final d = math.sqrt(d2);
        if (d < 1e-6) {
          h.pos.x = o.pos.x + block;
        } else {
          h.pos.x = o.pos.x + dx / d * block;
          h.pos.y = o.pos.y + dy / d * block;
        }
      }
    }
    _clamp(h);
  }

  void _clamp(Hole h) {
    final r = math.min(h.radius, math.min(width, height) / 2);
    h.pos.x = h.pos.x.clamp(r, width - r);
    h.pos.y = h.pos.y.clamp(r, height - r);
  }

  void _swallowObjects(Hole h) {
    final r2 = h.radius * h.radius;
    for (final o in objects) {
      if (!o.alive) continue;
      final dx = o.pos.x - h.pos.x, dy = o.pos.y - h.pos.y;
      if (dx * dx + dy * dy >= r2) continue;
      if (!h.canSwallowObject(o)) continue;
      o
        ..alive = false
        ..sink = 0.35
        ..sinkHole = h.id;
      h.swallowed++;
      if (h.isPlayer) {
        score += o.tier.points;
        playerXpFromCity += o.tier.xp;
      }
      events.add(
        GulpEvent(GulpEventKind.swallow, o.pos.x, o.pos.y, byPlayer: h.isPlayer, tier: o.tier, holeId: h.id),
      );
      _gainXp(h, o.tier.xp);
    }
  }

  void _gainXp(Hole h, int xp) {
    if (h.isPlayer) {
      h.xp += xp;
    } else {
      h.xpCarry += xp * rivalGrowthFactor;
      final whole = (h.xpCarry + 1e-9).floor(); // tolerate float drift
      h.xpCarry -= whole;
      h.xp += whole;
    }
    var leveled = false;
    while (h.xp >= xpForLevel(h.level + 1)) {
      h.level++;
      leveled = true;
    }
    if (leveled) {
      if (h.isPlayer) score += 50 * h.level;
      events.add(GulpEvent(GulpEventKind.levelUp, h.pos.x, h.pos.y, byPlayer: h.isPlayer, holeId: h.id));
    }
  }

  void _holeInteractions() {
    for (var i = 0; i < holes.length; i++) {
      final a = holes[i];
      if (!a.alive) continue;
      for (var j = i + 1; j < holes.length; j++) {
        final b = holes[j];
        if (!b.alive || !a.alive) continue;
        final dx = b.pos.x - a.pos.x, dy = b.pos.y - a.pos.y;
        final d = math.sqrt(dx * dx + dy * dy);
        final big = a.radius >= b.radius ? a : b;
        final small = identical(big, a) ? b : a;
        // A hole is gulped once it is mostly inside the bigger one; the player
        // must be swallowed deeper still, so grazing a rival is survivable.
        final depth = small.isPlayer ? playerSwallowDepth : 0.3;
        if (big.canEatHole(small) && d < big.radius - small.radius * depth) {
          _eatHole(big, small);
          if (phase == GulpPhase.lost) return;
          continue;
        }
        // Holes of similar size jostle apart instead of overlapping.
        final min = (a.radius + b.radius) * 0.8;
        if (d < min && !big.canEatHole(small)) {
          final nx = d > 1e-6 ? dx / d : 1.0, ny = d > 1e-6 ? dy / d : 0.0;
          final push = (min - d) * 0.5;
          a.pos.x -= nx * push;
          a.pos.y -= ny * push;
          b.pos.x += nx * push;
          b.pos.y += ny * push;
          _clamp(a);
          _clamp(b);
        }
      }
    }
  }

  void _eatHole(Hole eater, Hole victim) {
    victim.alive = false;
    eater.holesEaten++;
    events.add(
      GulpEvent(
        GulpEventKind.eatHole,
        victim.pos.x,
        victim.pos.y,
        byPlayer: eater.isPlayer,
        holeId: victim.id,
      ),
    );
    if (eater.isPlayer) score += 300 + victim.xp * 5;
    _gainXp(eater, 6 + victim.xp ~/ 2);
    if (victim.isPlayer) {
      eatenBy = eater;
      phase = GulpPhase.lost;
      events.add(GulpEvent(GulpEventKind.playerEaten, victim.pos.x, victim.pos.y, holeId: eater.id));
      return;
    }
    victim
      ..respawnTimer = rivalRespawnDelay
      ..huntTime = 0;
  }

  void _respawn(Hole h) {
    h
      ..alive = true
      ..xp = 0
      ..xpCarry = 0
      ..huntTime = 0
      ..huntCooldown = 0
      ..level = 0
      ..radius = baseRadius
      ..shield = 2
      ..target = null;
    h.steer.setZero();
    // Respawn at a random spot far from the player (the farthest candidate
    // wins if no early pick clears the minimum distance).
    var bestX = 0.0, bestY = 0.0, bestD = -1.0;
    for (var attempt = 0; attempt < 30; attempt++) {
      final x = baseRadius + _rng.nextDouble() * (width - 2 * baseRadius);
      final y = baseRadius + _rng.nextDouble() * (height - 2 * baseRadius);
      final dx = x - player.pos.x, dy = y - player.pos.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > bestD) {
        bestD = d;
        bestX = x;
        bestY = y;
      }
      if (d >= rivalMinSpawnDistance) break;
    }
    h.pos.setValues(bestX, bestY);
    events.add(GulpEvent(GulpEventKind.respawn, h.pos.x, h.pos.y, holeId: h.id));
  }

  // --- Rival AI -----------------------------------------------------------

  void _think(Hole h, double dt) {
    // Threats and prey first: flee bigger holes, chase smaller ones nearby.
    Hole? threat;
    var threatD = double.infinity;
    for (final o in holes) {
      if (identical(o, h) || !o.alive) continue;
      final d = o.pos.distanceTo(h.pos);
      if (o.canEatHole(h) && d < o.radius * 2.5 + 120 && d < threatD) {
        threat = o;
        threatD = d;
      }
    }
    if (h.huntCooldown > 0) h.huntCooldown -= dt;
    final prey = huntTargetFor(h);
    if (prey != null && prey.isPlayer) {
      h.huntTime += dt;
      if (h.huntTime > huntGiveUp) {
        h
          ..huntTime = 0
          ..huntCooldown = huntRest;
      }
    } else {
      h.huntTime = 0;
    }
    if (threat != null) {
      h.steer
        ..setValues(h.pos.x - threat.pos.x, h.pos.y - threat.pos.y)
        ..normalize();
      return;
    }
    if (prey != null) {
      h.steer
        ..setValues(prey.pos.x - h.pos.x, prey.pos.y - h.pos.y)
        ..normalize();
      return;
    }
    h.thinkTimer -= dt;
    final t = h.target;
    if (h.thinkTimer <= 0 || t == null || !t.alive) {
      h.thinkTimer = 0.4 + _rng.nextDouble() * 0.4;
      h.target = _pickTarget(h);
    }
    final target = h.target;
    if (target != null) {
      h.steer.setValues(target.pos.x - h.pos.x, target.pos.y - h.pos.y);
      if (h.steer.length2 > 1e-6) h.steer.normalize();
      return;
    }
    h.wanderTimer -= dt;
    if (h.wanderTimer <= 0) {
      h.wanderTimer = 1.5 + _rng.nextDouble() * 1.5;
      final a = _rng.nextDouble() * math.pi * 2;
      h.wander.setValues(math.cos(a), math.sin(a));
    }
    h.steer.setFrom(h.wander);
  }

  /// The hole a rival [h] wants to chase, if any. Rivals hunt each other when
  /// they can eat them and are close, but only hunt the player when they are
  /// at least [huntSizeRatio] bigger, the player is within [huntRange] and the
  /// player's start-of-round grace is over; otherwise they go for objects.
  Hole? huntTargetFor(Hole h) {
    Hole? prey;
    var preyD = double.infinity;
    for (final o in holes) {
      if (identical(o, h) || !o.alive || !h.canEatHole(o)) continue;
      final d = o.pos.distanceTo(h.pos);
      if (o.isPlayer) {
        if (h.huntCooldown > 0 || h.radius < o.radius * huntSizeRatio || d > huntRange) continue;
        if (_otherHunter(h)) continue; // only one rival stalks the player at a time
      } else if (d > 320) {
        continue;
      }
      if (d < preyD) {
        prey = o;
        preyD = d;
      }
    }
    return prey;
  }

  bool _otherHunter(Hole h) {
    for (final o in holes) {
      if (!identical(o, h) && !o.isPlayer && o.alive && o.huntTime > 0) return true;
    }
    return false;
  }

  /// Nearest edible object, weighted toward juicier ones.
  CityObject? _pickTarget(Hole h) {
    CityObject? best;
    var bestScore = double.infinity;
    for (final o in objects) {
      if (!o.alive || !h.canSwallowObject(o)) continue;
      final d = o.pos.distanceTo(h.pos);
      if (d > 700) continue;
      final s = d / (1 + o.tier.xp * 0.25);
      if (s < bestScore) {
        bestScore = s;
        best = o;
      }
    }
    return best;
  }

  // --- Test helpers -------------------------------------------------------

  /// Places an object directly (used by tests).
  CityObject debugAddObject(ObjTier tier, double x, double y) {
    final o = CityObject(_nextId++, tier, x, y, 0, 0);
    objects.add(o);
    totalXp += tier.xp;
    return o;
  }

  /// Removes every object (used by tests to get an empty city).
  void debugClearCity() {
    objects.clear();
    totalXp = 0;
    playerXpFromCity = 0;
  }

  /// Ends the player's start-of-round grace early.
  void debugEndGrace() => player.shield = 0;

  /// Forces a hole to a level and snaps its radius.
  void debugSetLevel(Hole h, int level) {
    h
      ..level = level
      ..xp = xpForLevel(level)
      ..radius = radiusForLevel(level);
  }

  /// Takes the rivals out of play (no respawn) so they do not interfere with a test.
  void debugDisableRivals() {
    for (final h in rivals) {
      h
        ..alive = false
        ..respawnTimer = double.infinity;
    }
  }
}
