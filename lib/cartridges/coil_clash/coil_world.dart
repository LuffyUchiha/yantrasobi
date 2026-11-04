import 'dart:math' as math;

/// Pure-Dart rules for Coil Clash: an arena of serpents that steer freely,
/// eat glowing orbs to grow and die when their head touches another body.
///
/// Multiplayer-ready: the world holds [CoilWorld.slots] player slots and every
/// action (local human, bot or a future remote peer) enters through
/// [CoilWorld.setInput]. The simulation only advances through the fixed
/// timestep [CoilWorld.step]; all randomness comes from seeded generators and
/// iteration order is by slot id, so two worlds fed the same inputs stay in
/// lockstep ([CoilWorld.stateHash]).

const double _tau = math.pi * 2;

/// Wraps [a] into (-pi, pi].
double wrapAngle(double a) {
  var r = a % _tau;
  if (r > math.pi) r -= _tau;
  return r;
}

/// One player's command: a desired heading (quantised to 4096 steps so it
/// packs into a small integer for a network transport) and a boost flag.
class CoilInput {
  const CoilInput({this.dir = 0, this.boost = false});

  factory CoilInput.fromAngle(double angle, {bool boost = false}) =>
      CoilInput(dir: ((angle / _tau) * dirSteps).round() % dirSteps, boost: boost);

  /// Inverse of [packed].
  factory CoilInput.unpack(int v) => CoilInput(dir: v & 0xFFF, boost: (v >> 12) & 1 == 1);

  static const int dirSteps = 4096;

  /// Desired heading in 1/4096ths of a full turn (0 = +x, clockwise on screen).
  final int dir;
  final bool boost;

  double get angle => dir * _tau / dirSteps;

  /// 13-bit wire format: heading in the low 12 bits, boost in bit 12.
  int get packed => (dir & 0xFFF) | (boost ? 1 << 12 : 0);

  @override
  bool operator ==(Object other) => other is CoilInput && other.dir == dir && other.boost == boost;

  @override
  int get hashCode => packed;
}

enum DeathCause { body, head, edge }

enum CoilEventKind { eat, death, respawn }

/// Something that happened during a step, consumed by the renderer for FX.
class CoilEvent {
  const CoilEvent(this.kind, this.player, this.x, this.y, {this.other = -1, this.cause});
  final CoilEventKind kind;
  final int player;
  final double x;
  final double y;

  /// For [CoilEventKind.death]: the serpent credited with the kill (-1 = none).
  final int other;
  final DeathCause? cause;
}

/// A serpent: a head plus a trail of body points spaced [CoilWorld.spacing]
/// apart, newest first, kept in a fixed ring buffer (no per-step allocation).
class Serpent {
  Serpent(this.id, {required this.isBot, required this.name, required this.hue});

  final int id;
  final bool isBot;
  final String name;
  final int hue;

  double x = 0, y = 0, heading = 0;
  double length = CoilWorld.startLength;
  double maxLength = CoilWorld.startLength;
  bool alive = false;
  bool boosting = false;
  int kills = 0;
  int deaths = 0;
  double respawnTimer = 0;
  CoilInput input = const CoilInput();
  DeathCause? lastCause;
  int lastKiller = -1;

  double _since = 0;
  double _burn = 0;
  bool _dying = false;
  DeathCause? _cause;
  int _killer = -1;

  final List<double> _px = List<double>.filled(CoilWorld.maxPoints, 0);
  final List<double> _py = List<double>.filled(CoilWorld.maxPoints, 0);
  int _newest = 0;
  int _count = 0;

  /// Number of body points (excluding the head).
  int get pointCount => _count;

  /// Body point [i], 0 = closest to the head.
  double pointX(int i) => _px[(_newest - i) % CoilWorld.maxPoints];
  double pointY(int i) => _py[(_newest - i) % CoilWorld.maxPoints];

  double get radius => 6.5 + 9.5 * ((length - CoilWorld.startLength) / 320).clamp(0.0, 1.0);

  /// Maximum turning speed in rad/s; long serpents turn more slowly.
  double get turnRate => 4.0 - 1.6 * ((length - CoilWorld.startLength) / 380).clamp(0.0, 1.0);

  void _push(double x, double y) {
    _newest = (_newest + 1) % CoilWorld.maxPoints;
    _px[_newest] = x;
    _py[_newest] = y;
    if (_count < CoilWorld.maxPoints) _count++;
  }

  void _trim() {
    final target = math.max(2, math.min(length.floor(), CoilWorld.maxPoints));
    if (_count > target) _count = target;
  }

  /// Lays the body out in a straight line behind the head.
  void _layOut(double x0, double y0, double h, double len) {
    x = x0;
    y = y0;
    heading = wrapAngle(h);
    length = len;
    maxLength = math.max(maxLength, len);
    _since = 0;
    _burn = 0;
    _count = 0;
    final n = math.max(2, math.min(len.floor(), CoilWorld.maxPoints));
    final c = math.cos(heading), s = math.sin(heading);
    for (var i = n; i >= 1; i--) {
      _push(x - c * CoilWorld.spacing * i, y - s * CoilWorld.spacing * i);
    }
  }
}

/// Uniform-grid spatial hash rebuilt with a counting sort (no allocation).
class SpatialHash {
  SpatialHash(this.half, this.cell, int capacity)
    : dim = (2 * half / cell).ceil() + 1,
      items = List<int>.filled(capacity, 0),
      _cellOf = List<int>.filled(capacity, 0) {
    start = List<int>.filled(dim * dim + 1, 0);
    _fill = List<int>.filled(dim * dim, 0);
  }

  final double half;
  final double cell;
  final int dim;
  late final List<int> start;
  late final List<int> _fill;
  final List<int> items;
  final List<int> _cellOf;

  int col(double v) {
    final c = ((v + half) / cell).floor();
    return c < 0 ? 0 : (c >= dim ? dim - 1 : c);
  }

  void build(int n, List<double> xs, List<double> ys) {
    final cells = dim * dim;
    for (var c = 0; c < cells; c++) {
      _fill[c] = 0;
    }
    for (var i = 0; i < n; i++) {
      final c = col(ys[i]) * dim + col(xs[i]);
      _cellOf[i] = c;
      _fill[c]++;
    }
    start[0] = 0;
    for (var c = 0; c < cells; c++) {
      start[c + 1] = start[c] + _fill[c];
      _fill[c] = start[c];
    }
    for (var i = 0; i < n; i++) {
      items[_fill[_cellOf[i]]++] = i;
    }
  }
}

class CoilWorld {
  CoilWorld({required this.seed, this.slots = 8, Set<int>? humans, this.localPlayer = 0})
    : _rng = math.Random(seed & 0x7fffffff) {
    final h = humans ?? {0};
    for (var i = 0; i < slots; i++) {
      final bot = !h.contains(i);
      serpents.add(
        Serpent(
          i,
          isBot: bot,
          name: i == localPlayer ? 'You' : (bot ? botNames[i % botNames.length] : 'Player ${i + 1}'),
          hue: i % 8,
        ),
      );
      ai.add(bot ? AiController((seed ^ (i * 0x9E3779B1)) & 0x7fffffff, skill: 0.45 + 0.07 * (i % 7)) : null);
    }
    _bx = List<double>.filled(slots * (maxPoints + 1), 0);
    _by = List<double>.filled(slots * (maxPoints + 1), 0);
    _bOwner = List<int>.filled(slots * (maxPoints + 1), 0);
    _bIdx = List<int>.filled(slots * (maxPoints + 1), 0);
    _bRad = List<double>.filled(slots * (maxPoints + 1), 0);
    bodyHash = SpatialHash(arenaRadius + 64, 32, slots * (maxPoints + 1));
    for (final s in serpents) {
      _spawn(s, s.isBot ? startLength + _rng.nextInt(12) : startLength);
    }
    while (orbCount < naturalOrbs) {
      _spawnNaturalOrb();
    }
    _buildBodies();
    orbHash.build(orbCount, ox, oy);
  }

  // Tuning.
  static const double stepDt = 1 / 60;
  static const double arenaRadius = 1500;
  static const double spacing = 7;
  static const int maxPoints = 400;
  static const double startLength = 14;
  static const double baseSpeed = 140;
  static const double boostSpeed = 280;
  static const double minBoostLength = 20;
  static const double boostBurn = 5; // length per second
  static const double boostDropEvery = 1.25; // burned length per dropped orb
  static const double boostDropValue = 0.8;
  static const double deathDropValue = 1.2; // per orb, one orb every 2 points
  static const double respawnDelay = 3;
  static const double roundLength = 180;
  static const int aiEvery = 3;
  static const int orbCapacity = 2600;
  static const List<String> botNames = ['Nox', 'Quill', 'Rhea', 'Tamsin', 'Oro', 'Juno', 'Kestrel', 'Wren'];

  final int seed;
  final int slots;
  final int localPlayer;
  final math.Random _rng;
  final List<Serpent> serpents = [];

  /// Bot brains by slot (null = driven from outside via [setInput]).
  final List<AiController?> ai = [];

  /// Target number of orbs kept in the arena.
  int naturalOrbs = 700;

  int tick = 0;
  double get time => tick * stepDt;
  double _acc = 0;
  final List<CoilEvent> events = [];

  // Orbs: compact parallel arrays [0, orbCount).
  final List<double> ox = List<double>.filled(orbCapacity, 0);
  final List<double> oy = List<double>.filled(orbCapacity, 0);
  final List<double> ov = List<double>.filled(orbCapacity, 0);
  final List<int> ohue = List<int>.filled(orbCapacity, 0);
  final List<int> oborn = List<int>.filled(orbCapacity, 0);
  final List<bool> _oeaten = List<bool>.filled(orbCapacity, false);
  int orbCount = 0;

  // Flat body arrays (heads included with index -1) + their spatial hash.
  late final List<double> _bx, _by, _bRad;
  late final List<int> _bOwner, _bIdx;
  int _bodyCount = 0;
  late final SpatialHash bodyHash;
  final SpatialHash orbHash = SpatialHash(arenaRadius + 64, 64, orbCapacity);

  Serpent get local => serpents[localPlayer];
  bool get timeUp => tick * stepDt >= roundLength - 1e-9;
  double get timeLeft => math.max(0, roundLength - time);
  bool get isOver => timeUp || !local.alive;

  /// Local player won: the round ran out while they were alive and longest.
  bool get won => timeUp && local.alive && ranking().first == localPlayer;
  int get score => local.maxLength.floor() + local.kills * 50;
  int get entityCount => orbCount + serpents.where((s) => s.alive).length;

  /// Alive serpents by length (longest first; ties by kills, then slot id).
  List<int> ranking() {
    final ids = [
      for (final s in serpents)
        if (s.alive) s.id,
    ];
    ids.sort((a, b) {
      var d = serpents[b].length.compareTo(serpents[a].length);
      if (d == 0) d = serpents[b].kills.compareTo(serpents[a].kills);
      return d != 0 ? d : a.compareTo(b);
    });
    return ids;
  }

  /// 1-based rank among living serpents, or 0 when dead.
  int rankOf(int id) => serpents[id].alive ? ranking().indexOf(id) + 1 : 0;

  /// The only way any player acts on the world.
  void setInput(int player, CoilInput input) => serpents[player].input = input;

  /// Advances in fixed [stepDt] steps; events cover all steps of this call.
  void update(double dt) {
    events.clear();
    if (timeUp) return;
    _acc += math.min(dt, 0.25);
    while (_acc >= stepDt && !timeUp) {
      _acc -= stepDt;
      step();
    }
  }

  /// One fixed simulation step.
  void step() {
    if (timeUp) return;
    if (events.length > 512) events.clear();
    tick++;
    for (var i = 0; i < slots; i++) {
      final c = ai[i];
      if (c != null && serpents[i].alive && (tick + i) % aiEvery == 0) setInput(i, c.decide(this, i));
    }
    for (final s in serpents) {
      if (s.alive) _move(s);
    }
    _buildBodies();
    for (final s in serpents) {
      if (s.alive) _checkDeath(s);
    }
    for (final s in serpents) {
      if (s._dying) _die(s);
    }
    for (final s in serpents) {
      if (s.alive) _eat(s);
    }
    _compactOrbs();
    var spawned = 0;
    while (orbCount < naturalOrbs && spawned < 6) {
      _spawnNaturalOrb();
      spawned++;
    }
    for (final s in serpents) {
      if (!s.alive && s.isBot) {
        s.respawnTimer -= stepDt;
        if (s.respawnTimer <= 0) {
          _spawn(s, startLength + _rng.nextInt(8));
          events.add(CoilEvent(CoilEventKind.respawn, s.id, s.x, s.y));
        }
      }
    }
    orbHash.build(orbCount, ox, oy);
  }

  void _move(Serpent s) {
    final diff = wrapAngle(s.input.angle - s.heading);
    final maxTurn = s.turnRate * stepDt;
    s.heading = wrapAngle(s.heading + diff.clamp(-maxTurn, maxTurn));
    var speed = baseSpeed;
    s.boosting = s.input.boost && s.length > minBoostLength;
    if (s.boosting) {
      speed = boostSpeed;
      const burn = boostBurn * stepDt;
      s.length -= burn;
      s._burn += burn;
      if (s._burn >= boostDropEvery) {
        s._burn -= boostDropEvery;
        final t = math.max(0, s._count - 1);
        _addOrb(s.pointX(t), s.pointY(t), boostDropValue, s.hue);
      }
    }
    final c = math.cos(s.heading), sn = math.sin(s.heading);
    final d = speed * stepDt;
    s.x += c * d;
    s.y += sn * d;
    s._since += d;
    while (s._since >= spacing) {
      final over = s._since - spacing;
      s._push(s.x - c * over, s.y - sn * over);
      s._since -= spacing;
    }
    s._trim();
  }

  void _buildBodies() {
    var n = 0;
    for (final s in serpents) {
      if (!s.alive) continue;
      final r = s.radius;
      _bx[n] = s.x;
      _by[n] = s.y;
      _bOwner[n] = s.id;
      _bIdx[n] = -1;
      _bRad[n] = r;
      n++;
      for (var i = 0; i < s._count; i++) {
        _bx[n] = s.pointX(i);
        _by[n] = s.pointY(i);
        _bOwner[n] = s.id;
        _bIdx[n] = i;
        _bRad[n] = r;
        n++;
      }
    }
    _bodyCount = n;
    bodyHash.build(n, _bx, _by);
  }

  void _checkDeath(Serpent s) {
    final r = s.radius;
    final edge = arenaRadius - r;
    if (s.x * s.x + s.y * s.y > edge * edge) {
      _markDying(s, DeathCause.edge, -1);
      return;
    }
    final h = bodyHash;
    final cx = h.col(s.x), cy = h.col(s.y);
    for (var gy = math.max(0, cy - 1); gy <= math.min(h.dim - 1, cy + 1); gy++) {
      for (var gx = math.max(0, cx - 1); gx <= math.min(h.dim - 1, cx + 1); gx++) {
        final c = gy * h.dim + gx;
        for (var k = h.start[c]; k < h.start[c + 1]; k++) {
          final e = h.items[k];
          final o = _bOwner[e];
          if (o == s.id) continue;
          final idx = _bIdx[e];
          if (idx == 0) continue; // neck: covered by the head-to-head rule
          final dx = _bx[e] - s.x, dy = _by[e] - s.y;
          final d2 = dx * dx + dy * dy;
          final other = serpents[o];
          if (idx < 0) {
            final reach = (r + _bRad[e]) * 0.8;
            if (d2 < reach * reach && s.length <= other.length + 1e-6) {
              _markDying(s, DeathCause.head, s.length < other.length - 1e-6 ? o : -1);
              return;
            }
          } else {
            final reach = (r + _bRad[e]) * 0.7;
            if (d2 < reach * reach) {
              _markDying(s, DeathCause.body, o);
              return;
            }
          }
        }
      }
    }
  }

  void _markDying(Serpent s, DeathCause cause, int killer) {
    s._dying = true;
    s._cause = cause;
    s._killer = killer;
  }

  void _die(Serpent s) {
    s._dying = false;
    s.alive = false;
    s.boosting = false;
    s.deaths++;
    s.lastCause = s._cause;
    s.lastKiller = s._killer;
    s.respawnTimer = respawnDelay;
    final r = s.radius;
    for (var i = -1; i < s._count; i += 2) {
      var x = i < 0 ? s.x : s.pointX(i);
      var y = i < 0 ? s.y : s.pointY(i);
      x += (_rng.nextDouble() - 0.5) * r;
      y += (_rng.nextDouble() - 0.5) * r;
      final d = math.sqrt(x * x + y * y);
      const lim = arenaRadius - 14;
      if (d > lim) {
        x *= lim / d;
        y *= lim / d;
      }
      _addOrb(x, y, deathDropValue, s.hue);
    }
    if (s._killer >= 0) serpents[s._killer].kills++;
    events.add(CoilEvent(CoilEventKind.death, s.id, s.x, s.y, other: s._killer, cause: s._cause));
    s._count = 0;
  }

  void _eat(Serpent s) {
    final reach = s.radius + 14;
    final r2 = reach * reach;
    final h = orbHash;
    final cx = h.col(s.x), cy = h.col(s.y);
    for (var gy = math.max(0, cy - 1); gy <= math.min(h.dim - 1, cy + 1); gy++) {
      for (var gx = math.max(0, cx - 1); gx <= math.min(h.dim - 1, cx + 1); gx++) {
        final c = gy * h.dim + gx;
        for (var k = h.start[c]; k < h.start[c + 1]; k++) {
          final o = h.items[k];
          if (o >= orbCount || _oeaten[o]) continue;
          final dx = ox[o] - s.x, dy = oy[o] - s.y;
          if (dx * dx + dy * dy < r2) {
            _oeaten[o] = true;
            s.length = math.min(maxPoints.toDouble(), s.length + ov[o]);
            if (s.length > s.maxLength) s.maxLength = s.length;
            events.add(CoilEvent(CoilEventKind.eat, s.id, ox[o], oy[o], other: ohue[o]));
          }
        }
      }
    }
  }

  void _compactOrbs() {
    var w = 0;
    for (var i = 0; i < orbCount; i++) {
      if (_oeaten[i]) {
        _oeaten[i] = false;
        continue;
      }
      if (w != i) {
        ox[w] = ox[i];
        oy[w] = oy[i];
        ov[w] = ov[i];
        ohue[w] = ohue[i];
        oborn[w] = oborn[i];
      }
      w++;
    }
    orbCount = w;
  }

  void _addOrb(double x, double y, double value, int hue) {
    if (orbCount >= orbCapacity) return;
    ox[orbCount] = x;
    oy[orbCount] = y;
    ov[orbCount] = value;
    ohue[orbCount] = hue;
    oborn[orbCount] = tick;
    _oeaten[orbCount] = false;
    orbCount++;
  }

  void _spawnNaturalOrb() {
    final a = _rng.nextDouble() * _tau;
    final d = (arenaRadius - 40) * math.sqrt(_rng.nextDouble());
    final big = _rng.nextInt(10) == 0;
    _addOrb(math.cos(a) * d, math.sin(a) * d, big ? 2.5 : 1, _rng.nextInt(8));
  }

  /// Places [s] at the safest of several random spots, heading roughly inward.
  void _spawn(Serpent s, double len) {
    var bx = 0.0, by = 0.0, best = -1.0;
    for (var t = 0; t < 8; t++) {
      final a = _rng.nextDouble() * _tau;
      final d = arenaRadius * 0.72 * math.sqrt(_rng.nextDouble());
      final x = math.cos(a) * d, y = math.sin(a) * d;
      var near = double.infinity;
      for (final o in serpents) {
        if (!o.alive || o.id == s.id) continue;
        for (var i = -1; i < o._count; i += 6) {
          final px = i < 0 ? o.x : o.pointX(i), py = i < 0 ? o.y : o.pointY(i);
          final dd = (px - x) * (px - x) + (py - y) * (py - y);
          if (dd < near) near = dd;
        }
      }
      if (near > best) {
        best = near;
        bx = x;
        by = y;
      }
    }
    final inward = math.atan2(-by, -bx) + (_rng.nextDouble() - 0.5) * 1.6;
    s.alive = true;
    s._dying = false;
    s.boosting = false;
    s._layOut(bx, by, inward, len);
    s.maxLength = s.isBot ? len : math.max(s.maxLength, len);
    s.input = CoilInput.fromAngle(s.heading);
  }

  // ---- Queries used by AI and the renderer -------------------------------

  /// Whether a circle of radius [r] at (x, y) overlaps the arena edge or any
  /// serpent other than [exclude].
  bool hazardAt(double x, double y, double r, int exclude) {
    final edge = arenaRadius - r - 6;
    if (x * x + y * y > edge * edge) return true;
    final h = bodyHash;
    final cx = h.col(x), cy = h.col(y);
    for (var gy = math.max(0, cy - 1); gy <= math.min(h.dim - 1, cy + 1); gy++) {
      for (var gx = math.max(0, cx - 1); gx <= math.min(h.dim - 1, cx + 1); gx++) {
        final c = gy * h.dim + gx;
        for (var k = h.start[c]; k < h.start[c + 1]; k++) {
          final e = h.items[k];
          if (e >= _bodyCount || _bOwner[e] == exclude || !serpents[_bOwner[e]].alive) continue;
          final dx = _bx[e] - x, dy = _by[e] - y;
          final reach = r + _bRad[e] + 4;
          if (dx * dx + dy * dy < reach * reach) return true;
        }
      }
    }
    return false;
  }

  /// Free distance along a straight ray (sampled every 10 units) up to [look].
  double rayClearance(double x, double y, double angle, double look, double r, int exclude) {
    final c = math.cos(angle), s = math.sin(angle);
    for (var d = 10.0; d <= look; d += 10) {
      if (hazardAt(x + c * d, y + s * d, r, exclude)) return d - 10;
    }
    return look;
  }

  /// Free distance along the curved path [s] would follow while turning
  /// toward [angle] at its own turn rate (sampled every 10 units).
  double pathClearance(Serpent s, double angle, double look) {
    final speed = s.boosting ? boostSpeed : baseSpeed;
    final maxTurn = s.turnRate * 10 / speed;
    var x = s.x, y = s.y, h = s.heading;
    final r = s.radius;
    for (var d = 10.0; d <= look; d += 10) {
      h += wrapAngle(angle - h).clamp(-maxTurn, maxTurn);
      x += math.cos(h) * 10;
      y += math.sin(h) * 10;
      if (hazardAt(x, y, r, s.id)) return d - 10;
      // Rival heads that would win a head-on clash, extrapolated in time.
      final t = d / speed;
      for (final o in serpents) {
        if (!o.alive || o.id == s.id || o.length < s.length - 1e-6) continue;
        final v = (o.boosting ? boostSpeed : baseSpeed) * t;
        final dx = o.x + math.cos(o.heading) * v - x, dy = o.y + math.sin(o.heading) * v - y;
        final reach = r + o.radius + 10;
        if (dx * dx + dy * dy < reach * reach) return d - 10;
      }
    }
    return look;
  }

  /// Index of the most attractive orb within [radius] of (x, y), or -1.
  int bestOrbNear(double x, double y, double radius, double heading) {
    final h = orbHash;
    final span = (radius / h.cell).ceil();
    final cx = h.col(x), cy = h.col(y);
    final r2 = radius * radius;
    var best = -1;
    var bestScore = 0.0;
    for (var gy = math.max(0, cy - span); gy <= math.min(h.dim - 1, cy + span); gy++) {
      for (var gx = math.max(0, cx - span); gx <= math.min(h.dim - 1, cx + span); gx++) {
        final c = gy * h.dim + gx;
        for (var k = h.start[c]; k < h.start[c + 1]; k++) {
          final o = h.items[k];
          if (o >= orbCount) continue;
          final dx = ox[o] - x, dy = oy[o] - y;
          final d2 = dx * dx + dy * dy;
          if (d2 > r2) continue;
          final d = math.sqrt(d2);
          final facing = d < 1e-6 ? 1.0 : (dx * math.cos(heading) + dy * math.sin(heading)) / d;
          final sc = ov[o] / (d + 40) * (1.4 + facing);
          if (sc > bestScore) {
            bestScore = sc;
            best = o;
          }
        }
      }
    }
    return best;
  }

  /// Cheap lockstep checksum of the simulation state.
  int stateHash() {
    var h = 17;
    void mix(int v) => h = (h * 31 + (v & 0x3fffffff)) & 0x3fffffff;
    mix(tick);
    for (final s in serpents) {
      mix(s.alive ? 1 : 0);
      mix(s.kills);
      mix(s.deaths);
      if (!s.alive) continue;
      mix((s.x * 8).round());
      mix((s.y * 8).round());
      mix((s.heading * 1000).round());
      mix((s.length * 100).round());
      mix(s._count);
      mix(s.input.packed);
    }
    mix(orbCount);
    var sx = 0, sy = 0;
    for (var i = 0; i < orbCount; i++) {
      sx += (ox[i] * 4).round();
      sy += (oy[i] * 4).round();
    }
    mix(sx);
    mix(sy);
    return h;
  }

  // ---- Debug helpers for tests -------------------------------------------

  /// Puts [id] alive at (x, y) facing [heading], body laid straight behind.
  void debugPlace(int id, double x, double y, double heading, {double length = startLength}) {
    final s = serpents[id];
    s.alive = true;
    s._dying = false;
    s._layOut(x, y, heading, length);
    s.input = CoilInput.fromAngle(heading);
    _buildBodies();
  }

  void debugKill(int id) {
    final s = serpents[id];
    if (!s.alive) return;
    _markDying(s, DeathCause.edge, -1);
    _die(s);
    _buildBodies();
  }

  /// Removes a serpent from play without dropping orbs or respawning.
  void debugRemove(int id) {
    final s = serpents[id];
    s.alive = false;
    s._count = 0;
    s.respawnTimer = 1e9;
    _buildBodies();
  }

  void debugSetLength(int id, double length) {
    final s = serpents[id];
    s.length = length;
    if (length > s.maxLength) s.maxLength = length;
  }

  void debugSetTick(int t) => tick = t;

  void debugClearOrbs() {
    orbCount = 0;
    orbHash.build(0, ox, oy);
  }

  void debugAddOrb(double x, double y, double value) {
    _addOrb(x, y, value, 0);
    orbHash.build(orbCount, ox, oy);
  }
}

/// Bot brain: seeks orbs, steers around bodies with look-ahead rays and
/// sometimes cuts in front of smaller rivals. Produces a [CoilInput] that the
/// caller feeds through [CoilWorld.setInput], exactly like a human's.
class AiController {
  AiController(int seed, {this.skill = 0.7}) : _rng = math.Random(seed);

  /// 0..1: search radius, aggression and boost appetite.
  final double skill;
  final math.Random _rng;
  double _wander = 0;
  int _wanderTicks = 0;

  static const List<double> _offsets = [-1.6, -1.15, -0.75, -0.4, -0.15, 0, 0.15, 0.4, 0.75, 1.15, 1.6];

  CoilInput decide(CoilWorld w, int id) {
    final s = w.serpents[id];
    if (!s.alive) return s.input;
    var tx = 0.0, ty = 0.0;
    var wantBoost = false;
    var have = false;
    // 1. Cut off a clearly smaller rival nearby.
    Serpent? prey;
    var preyD = 200 + 80 * skill;
    for (final o in w.serpents) {
      if (o.id == id || !o.alive || o.length * 1.3 > s.length) continue;
      final d = math.sqrt((o.x - s.x) * (o.x - s.x) + (o.y - s.y) * (o.y - s.y));
      if (d < preyD) {
        preyD = d;
        prey = o;
      }
    }
    if (prey != null && _rng.nextDouble() < skill) {
      final lead = 50 + prey.radius * 4;
      tx = prey.x + math.cos(prey.heading) * lead;
      ty = prey.y + math.sin(prey.heading) * lead;
      wantBoost = preyD < 170 && s.length > 40 && skill > 0.55;
      have = true;
    }
    // 2. Nearby orbs.
    if (!have) {
      final o = w.bestOrbNear(s.x, s.y, 120 + 180 * skill, s.heading);
      if (o >= 0 && _rng.nextDouble() < 0.6 + 0.4 * skill) {
        tx = w.ox[o];
        ty = w.oy[o];
        have = true;
      }
    }
    // 3. Wander, drifting back toward the middle when far out.
    if (!have) {
      if (--_wanderTicks <= 0) {
        _wander = _rng.nextDouble() * math.pi * 2;
        _wanderTicks = 15 + _rng.nextInt(30);
      }
      var a = _wander;
      if (s.x * s.x + s.y * s.y > math.pow(CoilWorld.arenaRadius * 0.6, 2)) a = math.atan2(-s.y, -s.x);
      tx = s.x + math.cos(a) * 100;
      ty = s.y + math.sin(a) * 100;
    }
    var desired = math.atan2(ty - s.y, tx - s.x);
    final speed = s.boosting ? CoilWorld.boostSpeed : CoilWorld.baseSpeed;
    final look = 60 + speed / s.turnRate + s.radius * 2 + 30 * skill;
    // Too close to the rim: head back toward the middle whatever the target.
    final rim = CoilWorld.arenaRadius - look - 60;
    if (s.x * s.x + s.y * s.y > rim * rim) {
      desired = math.atan2(-s.y, -s.x);
      wantBoost = false;
    }
    var bestA = desired;
    var bestScore = double.negativeInfinity;
    var bestClear = 0.0;
    for (var k = -1; k < _offsets.length; k++) {
      final a = k < 0 ? desired : s.heading + _offsets[k];
      final clear = w.pathClearance(s, a, look);
      final sc = clear / look * 4 + math.cos(wrapAngle(a - desired)) - wrapAngle(a - s.heading).abs() * 0.15;
      if (sc > bestScore) {
        bestScore = sc;
        bestA = a;
        bestClear = clear;
      }
    }
    final boost = wantBoost && bestClear >= look * 0.8 && s.length > CoilWorld.minBoostLength + 8;
    return CoilInput.fromAngle(bestA, boost: boost);
  }
}
