import 'dart:math' as math;

/// Power-ups found between hazard patterns.
enum PickupKind { shield, magnet, strider }

enum ThrustEventKind {
  coin,
  pickup,
  shieldBreak,
  striderBreak,
  striderEnd,
  crash,
  missileWarn,
  missileLaunch,
  stomp,
}

/// Something that happened during the last [ThrustWorld.update]; consumed by the renderer.
class ThrustEvent {
  const ThrustEvent(this.kind, this.x, this.y, {this.pickup});

  final ThrustEventKind kind;
  final double x;
  final double y;
  final PickupKind? pickup;
}

// ---------------------------------------------------------------------------
// Pattern library definitions (pattern-local metres: x from the pattern
// origin, y up from the floor).

/// A laser bar between two emitters. Static when [spinDeg] is 0, otherwise it
/// spins about its centre.
class LaserDef {
  const LaserDef(this.cx, this.cy, this.halfLen, this.angleDeg, [this.spinDeg = 0]);

  /// A static bar from (x0, y0) to (x1, y1).
  factory LaserDef.seg(double x0, double y0, double x1, double y1) {
    final dx = x1 - x0, dy = y1 - y0;
    return LaserDef(
      (x0 + x1) / 2,
      (y0 + y1) / 2,
      math.sqrt(dx * dx + dy * dy) / 2,
      math.atan2(dy, dx) * 180 / math.pi,
    );
  }

  final double cx, cy, halfLen, angleDeg;

  /// Degrees per second (positive = counter-clockwise).
  final double spinDeg;

  bool get rotating => spinDeg != 0;

  double get reachX => rotating ? halfLen : (math.cos(angleDeg * math.pi / 180) * halfLen).abs();

  LaserDef mirrored() => LaserDef(cx, ThrustWorld.height - cy, halfLen, -angleDeg, -spinDeg);
}

/// An electric gate: a vertical arc between two emitters that pulses on/off.
/// It is live while `(t + phase) % period < onTime`, where t is the time since
/// the hero entered the pattern's segment.
class GateDef {
  const GateDef(this.x, this.y0, this.y1, {this.period = 1.6, this.onTime = 0.8, this.phase = 0});

  final double x, y0, y1, period, onTime, phase;

  GateDef mirrored() => GateDef(
    x,
    ThrustWorld.height - y1,
    ThrustWorld.height - y0,
    period: period,
    onTime: onTime,
    phase: phase,
  );
}

/// A homing missile timed to cross the hero when it reaches pattern-local [atX].
class MissileDef {
  const MissileDef(this.atX);

  final double atX;
}

/// One entry of the deterministic pattern library.
class PatternDef {
  PatternDef(
    this.name, {
    this.minTier = 0,
    this.lasers = const [],
    this.gates = const [],
    this.missiles = const [],
    this.coins = const [],
  });

  final String name;
  final int minTier;
  final List<LaserDef> lasers;
  final List<GateDef> gates;
  final List<MissileDef> missiles;
  final List<(double, double)> coins;

  /// Length in metres: past every hazard, coin and missile crossing plus a margin
  /// wide enough that the hero has cleared everything when it leaves.
  late final double span = () {
    var m = 0.0;
    for (final l in lasers) {
      m = math.max(m, l.cx + l.reachX);
    }
    for (final g in gates) {
      m = math.max(m, g.x);
    }
    for (final s in missiles) {
      m = math.max(m, s.atX);
    }
    for (final c in coins) {
      m = math.max(m, c.$1);
    }
    return m + 1.2;
  }();

  @override
  String toString() => name;
}

// ------------------------------------------------------------- coin shapes

List<(double, double)> coinLine(double x0, double y0, double x1, double y1, int n) => [
  for (var i = 0; i < n; i++) (x0 + (x1 - x0) * i / (n - 1), y0 + (y1 - y0) * i / (n - 1)),
];

/// A parabolic arc from (x0, y0) rising by [h] at its middle and back down at x0 + [w].
List<(double, double)> coinArc(double x0, double y0, double w, double h, int n) => [
  for (var i = 0; i < n; i++) (x0 + w * i / (n - 1), y0 + h * (1 - math.pow(2 * i / (n - 1) - 1, 2))),
];

List<(double, double)> coinWave(double x0, double y0, double w, double amp, int n) => [
  for (var i = 0; i < n; i++) (x0 + w * i / (n - 1), y0 + amp * math.sin(i / (n - 1) * math.pi * 2)),
];

const Map<String, List<String>> _dotFont = {
  'G': ['###', '#..', '#.#', '#.#', '###'],
  'O': ['###', '#.#', '#.#', '#.#', '###'],
  'U': ['#.#', '#.#', '#.#', '#.#', '###'],
  'P': ['###', '#.#', '###', '#..', '#..'],
};

/// A word spelled in coins with a 3x5 dot font; (x0, y0) is the bottom-left dot.
List<(double, double)> coinWord(String word, double x0, double y0, {double cell = 0.8}) {
  final out = <(double, double)>[];
  for (var i = 0; i < word.length; i++) {
    final glyph = _dotFont[word[i]]!;
    for (var row = 0; row < 5; row++) {
      for (var col = 0; col < 3; col++) {
        if (glyph[row][col] == '#') out.add((x0 + (i * 4 + col) * cell, y0 + (4 - row) * cell));
      }
    }
  }
  return out;
}

// ------------------------------------------------------------ live objects

class Laser {
  Laser(this.cx, this.cy, this.halfLen, this.angle0, this.spin, this.entryX, this.speed)
    : reach = spin != 0 ? halfLen : (math.cos(angle0) * halfLen).abs();

  final double cx, cy, halfLen, angle0;

  /// Radians per second.
  final double spin;

  /// Pattern clock: time = (hero distance - entryX) / speed.
  final double entryX, speed;
  final double reach;

  bool get rotating => spin != 0;
  double get minX => cx - reach;
  double get maxX => cx + reach;

  double angleAt(double heroX) => angle0 + spin * (heroX - entryX) / speed;

  /// Whether a hero circle at x = [heroX], y = [py] with radius [rr] touches the bar.
  bool hits(double heroX, double py, double rr) {
    final rx = heroX - cx;
    final lim = halfLen + rr + ThrustWorld.laserHalfWidth;
    if (rx.abs() > lim) return false;
    final ry = py - cy;
    if (ry.abs() > lim) return false;
    final a = angleAt(heroX);
    final c = math.cos(a), s = math.sin(a);
    var t = rx * c + ry * s;
    if (t > halfLen) t = halfLen;
    if (t < -halfLen) t = -halfLen;
    final qx = rx - c * t, qy = ry - s * t;
    final rad = rr + ThrustWorld.laserHalfWidth;
    return qx * qx + qy * qy < rad * rad;
  }
}

class Gate {
  Gate(this.x, this.y0, this.y1, this.period, this.onTime, this.phase, this.entryX, this.speed);

  final double x, y0, y1, period, onTime, phase, entryX, speed;

  double _cycle(double heroX) => ((heroX - entryX) / speed + phase) % period;

  bool onAt(double heroX) => _cycle(heroX) < onTime;

  /// Seconds until the gate next switches on (0 while it is on).
  double untilOn(double heroX) {
    final c = _cycle(heroX);
    return c < onTime ? 0 : period - c;
  }

  bool hits(double heroX, double py, double rr) {
    final rad = rr + ThrustWorld.gateHalfWidth;
    final dx = heroX - x;
    if (dx.abs() >= rad || !onAt(heroX)) return false;
    final dy = py < y0 ? y0 - py : (py > y1 ? py - y1 : 0.0);
    return dx * dx + dy * dy < rad * rad;
  }
}

class Missile {
  Missile(this.warnX, this.lockX, this.launchAtX);

  /// Hero distances at which the warning shows, the aim locks and it fires.
  final double warnX, lockX, launchAtX;

  /// Tracks the hero's height until locked.
  double y = 0;
  bool warned = false;
  bool locked = false;
  bool exploded = false;
  int launchTick = -1;
  double launchX = 0;

  bool get launched => launchTick >= 0;

  double xAt(int tick) => launchX - ThrustWorld.missileSpeed * ThrustWorld.dt * (tick - launchTick);
}

class Coin {
  Coin(this.x, this.y);

  double x, y;
}

class Pickup {
  Pickup(this.kind, this.x, this.y);

  final PickupKind kind;
  final double x, y;
}

/// The hero's vertical state. Its horizontal position is the run distance.
class HeroBody {
  double y = ThrustWorld.heroRadius;
  double vy = 0;
  bool grounded = true;

  /// One fixed step. Jetpack: holding thrusts against gravity. Strider: holding
  /// (or a tap) jumps while on the floor.
  static void stepBody(HeroBody b, bool hold, bool strider) {
    const dt = ThrustWorld.dt;
    if (strider) {
      if (hold && b.grounded) b.vy = ThrustWorld.striderJump;
      b.vy -= ThrustWorld.gravity * dt;
    } else {
      b.vy += (hold ? ThrustWorld.thrust - ThrustWorld.gravity : -ThrustWorld.gravity) * dt;
      if (b.vy > ThrustWorld.maxRise) b.vy = ThrustWorld.maxRise;
    }
    if (b.vy < -ThrustWorld.maxFall) b.vy = -ThrustWorld.maxFall;
    b.y += b.vy * dt;
    final r = strider ? ThrustWorld.striderRadius : ThrustWorld.heroRadius;
    if (b.y <= r) {
      b.y = r;
      if (b.vy < 0) b.vy = 0;
      b.grounded = true;
    } else {
      b.grounded = false;
    }
    if (b.y >= ThrustWorld.height - r) {
      b.y = ThrustWorld.height - r;
      if (b.vy > 0) b.vy = 0;
    }
  }
}

class _Segment {
  _Segment(this.entryX, this.speed);

  final double entryX, speed;
}

/// The rules of Thrust Corridor: an endless side-scrolling corridor flown with
/// a hold-to-thrust jetpack. World units are metres; y = 0 is the floor.
///
/// Speed is piecewise constant: each hazard pattern owns a segment of track
/// (its lead-in gap plus its span) with one speed, fixed when it spawns and
/// growing with distance. Every hazard's clock is the hero's distance through
/// that segment, so a pattern behaves exactly as the [PatternValidator]
/// simulated it.
class ThrustWorld {
  ThrustWorld({int seed = 1, this.generate = true, double startSpeed = ThrustWorld.startSpeed})
    : _rng = math.Random(seed),
      speed = startSpeed,
      topSpeed = startSpeed;

  // Geometry and physics.
  static const double dt = 1 / 60;
  static const double height = 16;
  static const double heroRadius = 0.6;
  static const double striderRadius = 0.95;
  static const double gravity = 32;
  static const double thrust = 72;
  static const double maxRise = 14;
  static const double maxFall = 17;
  static const double striderJump = 16;
  static const double laserHalfWidth = 0.18;
  static const double gateHalfWidth = 0.22;

  // Speed ramp.
  static const double startSpeed = 6;
  static const double maxSpeed = 10.5;
  static const double rampPerMetre = 1 / 110;

  // Missiles.
  static const double missileSpeed = 18;
  static const double missileLead = 12;
  static const double missileRadius = 0.45;
  static const double warnTime = 1.2;
  static const double lockBefore = 0.3;

  // Spawning and pickups.
  static const double spawnAhead = 16;
  static const double introLength = 10;
  static const double coinRadius = 0.35;
  static const double pickupRadius = 0.7;
  static const double magnetRadius = 6;
  static const double magnetPull = 26;
  static const double magnetDuration = 8;
  static const double striderDuration = 8;
  static const double shieldGrace = 1.0;
  static const double striderGrace = 1.2;
  static const int coinValue = 5;

  /// The speed of the segment that starts at track distance [x].
  static double speedFor(double x) =>
      math.min(maxSpeed, ((startSpeed + x * rampPerMetre) * 4).floorToDouble() / 4);

  /// Hazard-free lead-in before a pattern at [v] m/s (about 0.9 s of travel).
  static double gapFor(double v) => math.max(5.0, 0.9 * v);

  static int _ticks(double seconds) => (seconds / dt).round();

  final math.Random _rng;
  final bool generate;

  int tick = 0;
  double distance = 0;
  double speed;
  double topSpeed;
  final HeroBody hero = HeroBody();

  /// Input: true while a finger is down.
  bool holding = false;
  bool _pressQueued = false;

  bool shield = false;
  int magnetEndTick = 0;
  int striderEndTick = 0;
  int graceEndTick = 0;
  bool _strider = false;

  int coins = 0;
  int pickupsTaken = 0;
  int hitsAbsorbed = 0;
  bool _over = false;
  String? crashedBy;

  final List<Laser> lasers = [];
  final List<Gate> gates = [];
  final List<Missile> missiles = [];
  final List<Coin> coinItems = [];
  final List<Pickup> pickups = [];
  final List<ThrustEvent> events = [];
  final List<_Segment> _segments = [];
  int _segIndex = 0;

  double _nextEntryX = introLength;
  int patternsSpawned = 0;
  int _lastPattern = -1;
  final List<String> spawnedNames = [];
  double _acc = 0;

  bool get isOver => _over;

  /// Endless score attack: there is no win or loss, only a final score.
  bool? get won => null;
  double get time => tick * dt;
  bool get inStrider => tick < striderEndTick;
  bool get magnetActive => tick < magnetEndTick;
  bool get ghost => tick < graceEndTick;
  double get radius => inStrider ? striderRadius : heroRadius;
  double get magnetLeft => math.max(0, (magnetEndTick - tick) * dt);
  double get striderLeft => math.max(0, (striderEndTick - tick) * dt);
  int get metres => distance.floor();
  int get score => metres + coins * coinValue;
  int get entityCount =>
      lasers.length + gates.length + missiles.length + coinItems.length + pickups.length + 1;

  // ---------------------------------------------------------------- input
  void press() {
    holding = true;
    _pressQueued = true;
  }

  void release() => holding = false;

  // ---------------------------------------------------------------- simulation
  /// Advances by real time [seconds] in fixed steps; clears [events] first.
  void update(double seconds) {
    events.clear();
    if (_over) return;
    _acc += math.min(seconds, 0.1);
    var n = 0;
    while (_acc >= dt - 1e-9 && n < 8) {
      step();
      _acc -= dt;
      n++;
    }
    if (_acc > dt) _acc = 0;
  }

  /// Exactly one fixed step.
  void step() {
    if (_over) return;
    tick++;
    while (_segIndex < _segments.length && distance >= _segments[_segIndex].entryX) {
      speed = _segments[_segIndex++].speed;
    }
    if (speed > topSpeed) topSpeed = speed;
    distance += speed * dt;

    final strider = tick < striderEndTick;
    if (_strider && !strider) {
      _strider = false;
      events.add(ThrustEvent(ThrustEventKind.striderEnd, distance, hero.y));
    }
    final wasGrounded = hero.grounded;
    HeroBody.stepBody(hero, holding || _pressQueued, strider);
    _pressQueued = false;
    if (strider && hero.grounded && !wasGrounded) {
      events.add(ThrustEvent(ThrustEventKind.stomp, distance, hero.y));
    }

    if (generate) _generate();
    _updateMissiles();
    if (tick >= graceEndTick) _checkHits();
    _collect();
    if (tick % 30 == 0) _cull();
    if (_segIndex > 16) {
      _segments.removeRange(0, _segIndex);
      _segIndex = 0;
    }
  }

  void _updateMissiles() {
    for (final m in missiles) {
      if (m.exploded) continue;
      if (!m.warned && distance >= m.warnX) {
        m.warned = true;
        events.add(ThrustEvent(ThrustEventKind.missileWarn, distance, hero.y));
      }
      if (!m.locked) {
        m.y = hero.y;
        if (distance >= m.lockX) m.locked = true;
      }
      if (!m.launched && distance >= m.launchAtX) {
        m.launchTick = tick;
        m.launchX = distance + missileLead;
        events.add(ThrustEvent(ThrustEventKind.missileLaunch, m.launchX, m.y));
      }
    }
  }

  void _checkHits() {
    final r = radius;
    final y = hero.y;
    for (final l in lasers) {
      if (l.hits(distance, y, r)) return _hit('a laser');
    }
    for (final g in gates) {
      if (g.hits(distance, y, r)) return _hit('an electric gate');
    }
    for (final m in missiles) {
      if (m.exploded || !m.launched) continue;
      final dx = m.xAt(tick) - distance, dy = m.y - y;
      final rad = r + missileRadius;
      if (dx * dx + dy * dy < rad * rad) {
        m.exploded = true;
        return _hit('a missile');
      }
    }
  }

  void _hit(String cause) {
    if (_strider) {
      _strider = false;
      striderEndTick = tick;
      graceEndTick = tick + _ticks(striderGrace);
      hitsAbsorbed++;
      events.add(ThrustEvent(ThrustEventKind.striderBreak, distance, hero.y));
      return;
    }
    if (shield) {
      shield = false;
      graceEndTick = tick + _ticks(shieldGrace);
      hitsAbsorbed++;
      events.add(ThrustEvent(ThrustEventKind.shieldBreak, distance, hero.y));
      return;
    }
    _over = true;
    crashedBy = cause;
    events.add(ThrustEvent(ThrustEventKind.crash, distance, hero.y));
  }

  void _collect() {
    final r = radius;
    final reach = r + coinRadius;
    final magnet = tick < magnetEndTick;
    for (var i = coinItems.length - 1; i >= 0; i--) {
      final c = coinItems[i];
      var dx = c.x - distance;
      if (dx > magnetRadius + 1 || dx < -3) continue;
      var dy = c.y - hero.y;
      if (magnet) {
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < magnetRadius && d > 1e-6) {
          final s = math.min(d, magnetPull * dt) / d;
          c.x -= dx * s;
          c.y -= dy * s;
          dx = c.x - distance;
          dy = c.y - hero.y;
        }
      }
      if (dx * dx + dy * dy < reach * reach) {
        coinItems.removeAt(i);
        coins++;
        events.add(ThrustEvent(ThrustEventKind.coin, c.x, c.y));
      }
    }
    final pr = r + pickupRadius;
    for (var i = pickups.length - 1; i >= 0; i--) {
      final p = pickups[i];
      final dx = p.x - distance, dy = p.y - hero.y;
      if (dx * dx + dy * dy < pr * pr) {
        pickups.removeAt(i);
        _apply(p.kind);
        events.add(ThrustEvent(ThrustEventKind.pickup, p.x, p.y, pickup: p.kind));
      }
    }
  }

  void _apply(PickupKind kind) {
    pickupsTaken++;
    switch (kind) {
      case PickupKind.shield:
        shield = true;
      case PickupKind.magnet:
        magnetEndTick = tick + _ticks(magnetDuration);
      case PickupKind.strider:
        striderEndTick = tick + _ticks(striderDuration);
        _strider = true;
    }
  }

  void _cull() {
    final behind = distance - 12;
    lasers.removeWhere((l) => l.maxX < behind);
    gates.removeWhere((g) => g.x < behind);
    missiles.removeWhere((m) => m.exploded || (m.launched && m.xAt(tick) < distance - 14));
    coinItems.removeWhere((c) => c.x < behind);
    pickups.removeWhere((p) => p.x < behind);
  }

  // ---------------------------------------------------------------- generation
  static int tierFor(double x) => x < 120 ? 0 : (x < 350 ? 1 : 2);

  void _generate() {
    while (distance + spawnAhead >= _nextEntryX) {
      _spawnNext();
    }
  }

  void _spawnNext() {
    final entry = _nextEntryX;
    final v = speedFor(entry);
    final gap = gapFor(v);
    final x0 = entry + gap;
    final tier = tierFor(x0);
    final lib = patternLibrary;
    var idx = _rng.nextInt(lib.length);
    final mirrored = _rng.nextBool();
    final extra = _rng.nextDouble();
    final extraY = 3 + _rng.nextDouble() * 10;
    final kindRoll = _rng.nextDouble();
    var chosen = -1;
    for (var tries = 0; tries < lib.length; tries++) {
      final p = lib[idx];
      if (p.minTier <= tier && idx != _lastPattern && PatternValidator.check(p, v, mirrored)) {
        chosen = idx;
        break;
      }
      idx = (idx + 1) % lib.length;
    }
    if (chosen < 0) chosen = lib.length - 1; // the coin-only breather is always passable
    final p = lib[chosen];
    _lastPattern = chosen;
    spawnPattern(p, x0, v, mirrored: mirrored);
    // Extras in the lead-in gap: a pickup every third pattern, otherwise maybe coins.
    final mid = entry + gap / 2;
    if (patternsSpawned % 3 == 2) {
      final kind = kindRoll < 0.4
          ? PickupKind.shield
          : (kindRoll < 0.72 ? PickupKind.magnet : PickupKind.strider);
      pickups.add(Pickup(kind, mid, extraY));
    } else if (extra < 0.6) {
      for (var i = 0; i < 5; i++) {
        coinItems.add(Coin(mid - 2 + i, extraY));
      }
    }
    patternsSpawned++;
    spawnedNames.add(p.name);
    if (spawnedNames.length > 64) spawnedNames.removeAt(0);
    _nextEntryX = x0 + p.span;
  }

  /// Places [p] with its origin at track distance [x0], run at [v] m/s from its
  /// entry point `x0 - gapFor(v)` onward.
  void spawnPattern(PatternDef p, double x0, double v, {bool mirrored = false}) {
    final entryX = x0 - gapFor(v);
    _segments.add(_Segment(entryX, v));
    const toRad = math.pi / 180;
    for (var d in p.lasers) {
      if (mirrored) d = d.mirrored();
      lasers.add(Laser(x0 + d.cx, d.cy, d.halfLen, d.angleDeg * toRad, d.spinDeg * toRad, entryX, v));
    }
    for (var g in p.gates) {
      if (mirrored) g = g.mirrored();
      gates.add(Gate(x0 + g.x, g.y0, g.y1, g.period, g.onTime, g.phase, entryX, v));
    }
    for (final s in p.missiles) {
      final hitX = x0 + s.atX;
      final flight = missileLead / (missileSpeed + v);
      final launchAt = hitX - v * flight;
      missiles.add(Missile(launchAt - v * warnTime, launchAt - v * lockBefore, launchAt));
    }
    final n = lasers.length, gn = gates.length;
    for (final c in p.coins) {
      final x = x0 + c.$1;
      final y = mirrored ? height - c.$2 : c.$2;
      if (y < coinRadius || y > height - coinRadius) continue;
      if (_coinBlocked(x, y, n - p.lasers.length, n, gn - p.gates.length, gn)) continue;
      coinItems.add(Coin(x, y));
    }
  }

  bool _coinBlocked(double x, double y, int l0, int l1, int g0, int g1) {
    for (var i = l0; i < l1; i++) {
      final l = lasers[i];
      if (l.rotating) {
        final dx = x - l.cx, dy = y - l.cy;
        if (dx * dx + dy * dy < math.pow(l.halfLen + 0.7, 2)) return true;
      } else if (l.hits(x, y, coinRadius + 0.25)) {
        return true;
      }
    }
    for (var i = g0; i < g1; i++) {
      final g = gates[i];
      if ((x - g.x).abs() < 0.9 && y > g.y0 - 0.9 && y < g.y1 + 0.9) return true;
    }
    return false;
  }

  /// Fills [out] with the hero's distance after 0..out.length-1 more steps,
  /// using exactly the arithmetic of [step].
  void predictDistances(List<double> out) {
    var d = distance, v = speed, si = _segIndex;
    out[0] = d;
    for (var k = 1; k < out.length; k++) {
      while (si < _segments.length && d >= _segments[si].entryX) {
        v = _segments[si++].speed;
      }
      d += v * dt;
      out[k] = d;
    }
  }

  // ---------------------------------------------------------------- debug helpers
  void debugClear() {
    lasers.clear();
    gates.clear();
    missiles.clear();
    coinItems.clear();
    pickups.clear();
  }

  void debugSetHero(double y, [double vy = 0]) {
    hero
      ..y = y
      ..vy = vy
      ..grounded = y <= heroRadius + 1e-9;
  }

  Laser injectLaser(LaserDef d, {double ahead = 6}) {
    const toRad = math.pi / 180;
    final l = Laser(
      distance + ahead + d.cx,
      d.cy,
      d.halfLen,
      d.angleDeg * toRad,
      d.spinDeg * toRad,
      distance,
      speed,
    );
    lasers.add(l);
    return l;
  }

  Gate injectGate(GateDef d, {double ahead = 6}) {
    final g = Gate(distance + ahead + d.x, d.y0, d.y1, d.period, d.onTime, d.phase, distance, speed);
    gates.add(g);
    return g;
  }

  /// A missile timed (at the current speed) to cross the hero [ahead] metres on.
  Missile injectMissile({double ahead = 20}) {
    final hitX = distance + ahead;
    final launchAt = hitX - speed * missileLead / (missileSpeed + speed);
    final m = Missile(launchAt - speed * warnTime, launchAt - speed * lockBefore, launchAt);
    missiles.add(m);
    return m;
  }

  Coin injectCoin(double ahead, double y) {
    final c = Coin(distance + ahead, y);
    coinItems.add(c);
    return c;
  }

  void injectPickup(PickupKind kind, double ahead, double y) =>
      pickups.add(Pickup(kind, distance + ahead, y));
}

// ---------------------------------------------------------------- the library

final List<PatternDef> patternLibrary = [
  PatternDef('post', lasers: [LaserDef.seg(2, 0, 2, 8.5)], coins: coinArc(0, 10.2, 5, 2, 7)),
  PatternDef('beam', lasers: [LaserDef.seg(2, 7.5, 2, 16)], coins: coinLine(0, 2.5, 5, 2.5, 6)),
  PatternDef(
    'slalom',
    lasers: [LaserDef.seg(1, 0, 1, 7.5), LaserDef.seg(9, 8.5, 9, 16), LaserDef.seg(17, 0, 17, 7.5)],
    coins: [...coinLine(3, 10.5, 7, 6, 5), ...coinLine(11, 6, 15, 10.5, 5)],
  ),
  PatternDef('ramp', lasers: [LaserDef.seg(1, 3, 8, 10)], coins: coinLine(0, 1.6, 9, 1.6, 8)),
  PatternDef(
    'windmill',
    lasers: [const LaserDef(4, 8, 3.5, 90, 100)],
    coins: [...coinLine(0, 14.6, 8, 14.6, 7), ...coinLine(0, 1.4, 8, 1.4, 7)],
  ),
  PatternDef('stinger', missiles: [const MissileDef(5)], coins: coinWave(0, 8, 10, 3, 9)),
  PatternDef(
    'chevron',
    minTier: 1,
    lasers: [LaserDef.seg(0, 3, 4, 9), LaserDef.seg(4, 9, 8, 3)],
    coins: coinArc(0, 11, 8, 2.5, 7),
  ),
  PatternDef(
    'twin rotors',
    minTier: 1,
    lasers: [const LaserDef(3, 4.5, 3, 90, 150), const LaserDef(11, 11.5, 3, 0, -150)],
    coins: coinLine(0, 12.5, 6, 12.5, 5),
  ),
  PatternDef(
    'squeeze',
    minTier: 1,
    lasers: [
      LaserDef.seg(2, 0, 2, 6),
      LaserDef.seg(2, 10, 2, 16),
      LaserDef.seg(10, 0, 10, 3),
      LaserDef.seg(10, 7, 10, 16),
    ],
    coins: coinLine(2, 8, 10, 5, 7),
  ),
  PatternDef(
    'gate pair',
    minTier: 1,
    gates: [
      const GateDef(3, 0, 8.5, period: 2.4, onTime: 0.8),
      const GateDef(3, 7.5, 16, period: 2.4, onTime: 0.8, phase: 1.2),
    ],
    coins: coinLine(5, 8, 9, 8, 4),
  ),
  PatternDef(
    'channel',
    minTier: 1,
    lasers: [LaserDef.seg(0, 4, 14, 4), LaserDef.seg(0, 12, 14, 12)],
    gates: [const GateDef(7, 4.4, 11.6)],
    coins: coinLine(1, 8, 13, 8, 10),
  ),
  PatternDef(
    'roof run',
    minTier: 1,
    lasers: [LaserDef.seg(0, 10.5, 12, 10.5)],
    missiles: [const MissileDef(6)],
    coins: coinLine(0, 13.5, 12, 13.5, 9),
  ),
  PatternDef(
    'big spinner',
    minTier: 2,
    lasers: [const LaserDef(6, 8, 6, 90, 70)],
    coins: coinLine(0, 15.2, 12, 15.2, 9),
  ),
  PatternDef(
    'crossfire',
    minTier: 2,
    lasers: [const LaserDef(5, 8, 4, 0, 110), const LaserDef(5, 8, 4, 90, 110)],
    coins: coinLine(0, 1.4, 10, 1.4, 8),
  ),
  PatternDef(
    'gate field',
    minTier: 2,
    gates: [
      const GateDef(2, 0, 6.5, period: 1.2, onTime: 0.6),
      const GateDef(8, 5, 11, period: 1.2, onTime: 0.6, phase: 0.6),
      const GateDef(14, 9.5, 16, period: 1.2, onTime: 0.6),
    ],
  ),
  PatternDef(
    'stairs',
    minTier: 2,
    lasers: [
      const LaserDef(2, 4, 2, 0, 200),
      const LaserDef(8, 8, 2, 0, -200),
      const LaserDef(14, 12, 2, 0, 200),
    ],
  ),
  PatternDef(
    'volley',
    minTier: 2,
    missiles: [const MissileDef(3), const MissileDef(10), const MissileDef(17)],
    coins: coinWave(0, 8, 17, 4, 12),
  ),
  // The breather must stay last: it is the generator's fallback.
  PatternDef('go', coins: coinWord('GO', 0, 6.4)),
];

// ---------------------------------------------------------------- planner

class PlanResult {
  const PlanResult(this.survived, this.ticks, this.actions);

  /// True when some hold/release sequence avoids every hit over the horizon.
  final bool survived;

  /// Ticks the chosen sequence stays unhit.
  final int ticks;

  /// One hold flag per [ThrustPlanner.block] ticks.
  final List<bool> actions;
}

class _Node {
  _Node(this.y, this.vy, this.grounded, this.parent, this.hold, this.locks);

  final double y, vy;
  final bool grounded;
  final int parent;
  final bool hold;
  final List<double>? locks;
}

class _PlanMissile {
  _PlanMissile(this.lockK, this.launchK, this.launchX, this.y, this.slot);

  final int lockK, launchK;
  final double launchX, y;

  /// Index into a node's lock list, or -1 when the aim is already locked.
  final int slot;
}

/// A breadth-first search over hold/release sequences, replaying the world's
/// exact fixed-step physics against every hazard's future (missiles lock onto
/// each candidate path's own height). States are merged on a (height,
/// velocity) grid, so a found path is real while a miss is conservative.
class ThrustPlanner {
  ThrustPlanner._();

  static const int block = 4;
  static const double yCell = 0.4;
  static const double vyCell = 1.5;
  static const double margin = 0.06;

  static PlanResult plan(ThrustWorld w, int horizonTicks) {
    final blocks = math.max(1, (horizonTicks + block - 1) ~/ block);
    final n = blocks * block;
    final xs = List<double>.filled(n + 1, 0);
    w.predictDistances(xs);

    // Hazards near the hero on each future tick.
    const reach = ThrustWorld.striderRadius + 0.5;
    final nearLasers = List<List<Laser>?>.filled(n + 1, null);
    final nearGates = List<List<Gate>?>.filled(n + 1, null);
    for (var k = 1; k <= n; k++) {
      final x = xs[k];
      for (final l in w.lasers) {
        if (x > l.minX - reach && x < l.maxX + reach) (nearLasers[k] ??= []).add(l);
      }
      for (final g in w.gates) {
        if ((x - g.x).abs() < reach) (nearGates[k] ??= []).add(g);
      }
    }
    final ms = <_PlanMissile>[];
    var slots = 0;
    for (final m in w.missiles) {
      if (m.exploded) continue;
      var lockK = -1, launchK = -1;
      if (!m.locked) {
        for (var k = 1; k <= n; k++) {
          if (xs[k] >= m.lockX) {
            lockK = k;
            break;
          }
        }
        if (lockK < 0) continue;
      }
      double launchX;
      if (m.launched) {
        launchK = m.launchTick - w.tick;
        launchX = m.launchX;
      } else {
        for (var k = 1; k <= n; k++) {
          if (xs[k] >= m.launchAtX) {
            launchK = k;
            break;
          }
        }
        if (launchK < 0) continue;
        launchX = xs[launchK] + ThrustWorld.missileLead;
      }
      ms.add(_PlanMissile(lockK, launchK, launchX, m.y, m.locked ? -1 : slots++));
    }

    bool hit(int k, double y, double r, List<double>? locks) {
      if (w.tick + k < w.graceEndTick) return false;
      final x = xs[k];
      final rr = r + margin;
      final ls = nearLasers[k];
      if (ls != null) {
        for (final l in ls) {
          if (l.hits(x, y, rr)) return true;
        }
      }
      final gs = nearGates[k];
      if (gs != null) {
        for (final g in gs) {
          if (g.hits(x, y, rr)) return true;
        }
      }
      for (final m in ms) {
        if (k < m.launchK) continue;
        final mx = m.launchX - ThrustWorld.missileSpeed * ThrustWorld.dt * (k - m.launchK);
        final dx = mx - x;
        final rad = rr + ThrustWorld.missileRadius;
        if (dx.abs() >= rad) continue;
        final dy = (m.slot >= 0 ? locks![m.slot] : m.y) - y;
        if (dx * dx + dy * dy < rad * rad) return true;
      }
      return false;
    }

    final ny = (ThrustWorld.height / yCell).ceil() + 1;
    final nv = ((ThrustWorld.maxFall + ThrustWorld.striderJump) / vyCell).ceil() + 2;
    final stamp = List<int>.filled(ny * nv * 2, -1);
    final body = HeroBody();
    final levels = <List<_Node>>[
      [
        _Node(
          w.hero.y,
          w.hero.vy,
          w.hero.grounded,
          -1,
          false,
          slots > 0 ? List<double>.filled(slots, w.hero.y) : null,
        ),
      ],
    ];
    var survived = true;
    for (var d = 0; d < blocks; d++) {
      final frontier = levels.last;
      final next = <_Node>[];
      for (var pi = 0; pi < frontier.length; pi++) {
        final node = frontier[pi];
        for (var a = 0; a < 2; a++) {
          final hold = a == 1;
          body
            ..y = node.y
            ..vy = node.vy
            ..grounded = node.grounded;
          var locks = node.locks;
          var copied = false;
          var dead = false;
          for (var j = 1; j <= block; j++) {
            final k = d * block + j;
            final strider = w.tick + k < w.striderEndTick;
            HeroBody.stepBody(body, hold, strider);
            for (final m in ms) {
              if (m.slot >= 0 && m.lockK == k) {
                if (!copied) {
                  locks = List<double>.of(locks!);
                  copied = true;
                }
                locks![m.slot] = body.y;
              }
            }
            if (hit(k, body.y, strider ? ThrustWorld.striderRadius : ThrustWorld.heroRadius, locks)) {
              dead = true;
              break;
            }
          }
          if (dead) continue;
          final yi = (body.y / yCell).floor().clamp(0, ny - 1);
          final vi = ((body.vy + ThrustWorld.maxFall) / vyCell).floor().clamp(0, nv - 1);
          final key = (yi * nv + vi) * 2 + (body.grounded ? 1 : 0);
          if (stamp[key] == d) continue;
          stamp[key] = d;
          next.add(_Node(body.y, body.vy, body.grounded, pi, hold, locks));
        }
      }
      if (next.isEmpty) {
        survived = false;
        break;
      }
      levels.add(next);
    }

    // Prefer ending mid-corridor and calm, which keeps the most options open.
    final last = levels.last;
    var best = 0;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < last.length; i++) {
      final s = -(last[i].y - ThrustWorld.height / 2).abs() - 0.08 * last[i].vy.abs();
      if (s > bestScore) {
        bestScore = s;
        best = i;
      }
    }
    final depth = levels.length - 1;
    final actions = List<bool>.filled(depth, false);
    var idx = best;
    for (var d = depth; d > 0; d--) {
      final node = levels[d][idx];
      actions[d - 1] = node.hold;
      idx = node.parent;
    }
    return PlanResult(survived, depth * block, actions);
  }
}

/// Follows [ThrustPlanner] plans, replanning every [replanEvery] ticks.
class ThrustAutopilot {
  ThrustAutopilot({this.horizonTicks = 96, this.replanEvery = 12});

  final int horizonTicks;
  final int replanEvery;
  List<bool> _plan = const [];
  int _planTick = -1 << 30;

  /// Whether to hold for the next step.
  bool decide(ThrustWorld w) {
    if (w.tick - _planTick >= replanEvery || w.tick < _planTick) {
      _plan = ThrustPlanner.plan(w, horizonTicks).actions;
      _planTick = w.tick;
    }
    final i = (w.tick - _planTick) ~/ ThrustPlanner.block;
    return i < _plan.length && _plan[i];
  }
}

// ---------------------------------------------------------------- validator

/// Proves a pattern has a collision-free vertical path at a given speed.
///
/// The hero enters the pattern's lead-in gap from each of several extreme
/// states (on the floor, on the ceiling, mid-air at rest, diving, climbing)
/// and the planner must find a thrust schedule through the whole pattern,
/// using the real thrust/gravity limits and the pattern's hazard clocks.
class PatternValidator {
  PatternValidator._();

  static final Map<String, bool> _cache = {};

  static const List<(double, double)> entryStates = [
    (ThrustWorld.heroRadius, 0),
    (ThrustWorld.height - ThrustWorld.heroRadius, 0),
    (ThrustWorld.height / 2, 0),
    (ThrustWorld.height / 2, -ThrustWorld.maxFall),
    (ThrustWorld.height / 2, ThrustWorld.maxRise),
  ];

  /// Cached [feasible]; speeds come from [ThrustWorld.speedFor] so the cache stays small.
  static bool check(PatternDef p, double speed, bool mirrored) =>
      _cache.putIfAbsent('${p.name}|$mirrored|$speed', () => feasible(p, speed, mirrored: mirrored));

  static bool feasible(PatternDef p, double speed, {bool mirrored = false}) {
    final gap = ThrustWorld.gapFor(speed);
    final ticks = ((gap + p.span + 0.5) / (speed * ThrustWorld.dt)).ceil();
    for (final (y, vy) in entryStates) {
      final w = ThrustWorld(generate: false, startSpeed: speed)
        ..spawnPattern(p, gap, speed, mirrored: mirrored)
        ..debugSetHero(y, vy);
      if (!ThrustPlanner.plan(w, ticks).survived) return false;
    }
    return true;
  }
}
