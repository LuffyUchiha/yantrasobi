import 'dart:math' as math;

/// Which numbered set a player is shooting at.
enum BallGroup { open, solids, stripes }

/// Why a shot was a foul (gives the opponent ball-in-hand).
enum CueFoul { none, scratch, noContact, wrongBall, noRail }

enum CuePhase { aiming, rolling, over }

/// How the match ended.
enum CueEnd { none, eightLegal, eightEarly, eightFoul }

/// One player's turn: a single cue strike.
///
/// Every action (human drag, CPU, or a future remote peer) enters the rules
/// only through [CueWorld.submitMove] as one of these plain value objects.
/// [cueX]/[cueY] place the cue ball first and are only allowed with
/// ball-in-hand (including the break, which is played from behind the head
/// string).
class CueShot {
  const CueShot({required this.angle, required this.power, this.spin = 0, this.cueX, this.cueY});

  /// Shot direction in radians (table coordinates, y grows downwards).
  final double angle;

  /// Strike strength, 0 (exclusive) .. 1.
  final double power;

  /// Follow (+) or draw (-), -1 .. 1, applied when the cue ball first hits a ball.
  final double spin;
  final double? cueX;
  final double? cueY;

  bool get places => cueX != null && cueY != null;

  @override
  bool operator ==(Object other) =>
      other is CueShot &&
      other.angle == angle &&
      other.power == power &&
      other.spin == spin &&
      other.cueX == cueX &&
      other.cueY == cueY;

  @override
  int get hashCode => Object.hash(angle, power, spin, cueX, cueY);

  @override
  String toString() =>
      'CueShot(angle: ${angle.toStringAsFixed(4)}, power: ${power.toStringAsFixed(3)}, spin: $spin'
      '${places ? ', at: ${cueX!.toStringAsFixed(3)},${cueY!.toStringAsFixed(3)}' : ''})';
}

/// A ball on (or off) the table. Id 0 is the cue ball, 1-7 solids, 8 the
/// black, 9-15 stripes.
class CueBall {
  CueBall(this.id, this.x, this.y);

  final int id;
  double x, y;
  double vx = 0, vy = 0;
  bool potted = false;

  bool get moving => vx != 0 || vy != 0;
  double get speed => math.sqrt(vx * vx + vy * vy);

  CueBall copy() => CueBall(id, x, y)
    ..vx = vx
    ..vy = vy
    ..potted = potted;
}

/// What happened during the last resolved shot.
class ShotReport {
  ShotReport(this.player, this.isBreak);

  final int player;
  final bool isBreak;
  CueFoul foul = CueFoul.none;

  /// Balls dropped this shot in pocket order (0 = cue ball scratch).
  final List<int> potted = [];
  int firstContact = -1;
  bool railAfterContact = false;
  bool turnKept = false;
  BallGroup assigned = BallGroup.open;
  bool eightRespotted = false;
  CueEnd end = CueEnd.none;
}

/// Ray-cast result used for the aiming guideline.
class AimPreview {
  /// Object ball the cue ball strikes first, or -1 for a cushion.
  int hitBall = -1;

  /// Where the cue ball's centre is at first contact (the ghost ball).
  double ghostX = 0, ghostY = 0;

  /// Direction the struck ball leaves in (unit), when [hitBall] >= 0.
  double objDirX = 0, objDirY = 0;

  /// Stun-shot deflection of the cue ball (unit, may be zero for a full hit).
  double cueDirX = 0, cueDirY = 0;
}

/// Tiny portable PRNG (Park-Miller) so racks and CPU choices are identical on
/// every platform, including the web.
class CueRng {
  CueRng(int seed) : _s = (seed.abs() % 0x7ffffffe) + 1;

  int _s;

  int nextInt(int n) {
    _s = (_s * 48271) % 0x7fffffff;
    return _s % n;
  }

  double nextDouble() {
    _s = (_s * 48271) % 0x7fffffff;
    return (_s - 1) / 0x7ffffffe;
  }

  /// Roughly normal, mean 0, standard deviation ~1.
  double nextGaussian() => (nextDouble() + nextDouble() + nextDouble() + nextDouble() - 2) * 1.732;
}

/// Pure, deterministic rules and physics for a two-player 8-ball duel.
///
/// Table coordinates: x in [0, width] left to right, y in [0, height] top to
/// bottom (portrait). The rack sits on the foot spot near the top; shots
/// break from behind the head string near the bottom.
///
/// Turns enter through [submitMove]; the shot then rolls in fixed [stepDt]
/// ticks ([step], or [update] with an accumulator) until every ball rests,
/// when the rules resolve fouls, pots, groups and the next shooter.
class CueWorld {
  CueWorld({this.seed = 0, int firstPlayer = 0}) : current = firstPlayer, balls = List.generate(16, _blank) {
    _rack();
  }

  CueWorld._copy(CueWorld o)
    : seed = o.seed,
      current = o.current,
      balls = [for (final b in o.balls) b.copy()] {
    groups[0] = o.groups[0];
    groups[1] = o.groups[1];
    phase = o.phase;
    ballInHand = o.ballInHand;
    kitchenOnly = o.kitchenOnly;
    isBreak = o.isBreak;
    winner = o.winner;
    endReason = o.endReason;
    _tick = o._tick;
    shotsResolved = o.shotsResolved;
  }

  static CueBall _blank(int id) => CueBall(id, 0, 0);

  // ------------------------------------------------------------ constants
  static const double width = 10;
  static const double height = 20;
  static const double ballRadius = 0.32;
  static const double stepDt = 1 / 120;
  static const int substeps = 2;

  /// Cue ball speed at full power (units / second).
  static const double maxShotSpeed = 28;

  /// Rolling resistance: constant deceleration plus a light linear drag.
  static const double rollDecel = 4;
  static const double rollDrag = 0.25;
  static const double sleepSpeed = 0.04;
  static const double cushionRestitution = 0.78;

  /// How much of the impact a full follow/draw spin turns into cue ball run.
  static const double spinTransfer = 0.55;

  /// Balls placed with ball-in-hand after a break foul must sit at or below this line.
  static const double kitchenY = height * 0.75;
  static const double headSpotY = height * 0.78;
  static const double footSpotY = height * 0.25;

  /// Pocket mouths: distance from each corner kept free of cushion, and half
  /// the width of each side-pocket mouth.
  static const double cornerGap = 0.85;
  static const double sideGap = 0.55;

  /// Safety cap: a shot is forced to rest after this many ticks.
  static const int maxShotTicks = 120 * 40;

  static const List<double> pocketX = [-0.12, width + 0.12, -0.32, width + 0.32, -0.12, width + 0.12];
  static const List<double> pocketY = [-0.12, -0.12, height / 2, height / 2, height + 0.12, height + 0.12];
  static const List<double> pocketCapture = [0.62, 0.62, 0.6, 0.6, 0.62, 0.62];

  /// Cushion segments (x1, y1, x2, y2) along the table edge, broken by the six pocket mouths.
  static const List<double> cushions = [
    cornerGap, 0, width - cornerGap, 0, // top
    cornerGap, height, width - cornerGap, height, // bottom
    0, cornerGap, 0, height / 2 - sideGap, // left upper
    0, height / 2 + sideGap, 0, height - cornerGap, // left lower
    width, cornerGap, width, height / 2 - sideGap, // right upper
    width, height / 2 + sideGap, width, height - cornerGap, // right lower
  ];

  static final double _dragPerStep = math.exp(-rollDrag * stepDt);

  static BallGroup groupOf(int id) => id >= 1 && id <= 7
      ? BallGroup.solids
      : id >= 9 && id <= 15
      ? BallGroup.stripes
      : BallGroup.open;

  // ---------------------------------------------------------------- state
  final int seed;
  final List<CueBall> balls;
  final List<BallGroup> groups = [BallGroup.open, BallGroup.open];
  final List<CueShot> history = [];

  /// Whose shot it is.
  int current;
  CuePhase phase = CuePhase.aiming;

  /// The shooter may (re)place the cue ball as part of their move.
  bool ballInHand = true;

  /// Ball-in-hand is restricted to behind the head string (break and break fouls).
  bool kitchenOnly = true;
  bool isBreak = true;
  int? winner;
  CueEnd endReason = CueEnd.none;
  ShotReport? lastReport;

  /// Number of shots that have finished rolling.
  int shotsResolved = 0;

  int _tick = 0;
  int get tick => _tick;
  int get turnNumber => history.length;

  // Event counters, polled by the renderer for sounds and effects.
  int ballClicks = 0;
  int cushionHits = 0;
  int pots = 0;
  double lastPotX = 0, lastPotY = 0;

  // Per-shot tracking.
  int _shooter = 0;
  bool _wasOnEight = false;
  int _firstContact = -1;
  bool _rail = false;
  double _spin = 0;
  bool _spinUsed = false;
  int _shotTicks = 0;
  ShotReport? _report;
  double _acc = 0;

  CueBall get cue => balls[0];
  bool get isOver => winner != null;

  /// Player 0 (the local player) won.
  bool get won => winner == 0;

  /// Player 0's own group balls already pocketed.
  int get score => pottedOf(0);

  int get entityCount {
    var n = 0;
    for (final b in balls) {
      if (!b.potted) n++;
    }
    return n;
  }

  bool get anyMoving {
    for (final b in balls) {
      if (!b.potted && b.moving) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- setup
  void _rack() {
    final rng = CueRng(seed);
    const d = ballRadius * 2 + 0.01;
    final rowH = d * math.sqrt(3) / 2;
    final spots = <List<double>>[];
    for (var row = 0; row < 5; row++) {
      for (var k = 0; k <= row; k++) {
        spots.add([width / 2 + (k - row / 2) * d, footSpotY - row * rowH]);
      }
    }
    // Apex: 1; middle of row 3: the 8; back corners: one solid, one stripe.
    final order = List<int>.filled(15, 0);
    order[0] = 1;
    order[4] = 8;
    final cornerSolid = 2 + rng.nextInt(6);
    final cornerStripe = 9 + rng.nextInt(7);
    final solidLeft = rng.nextInt(2) == 0;
    order[10] = solidLeft ? cornerSolid : cornerStripe;
    order[14] = solidLeft ? cornerStripe : cornerSolid;
    final rest = [
      for (var id = 2; id <= 15; id++)
        if (id != 8 && id != cornerSolid && id != cornerStripe) id,
    ];
    for (var i = rest.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = rest[i];
      rest[i] = rest[j];
      rest[j] = t;
    }
    var r = 0;
    for (var i = 0; i < 15; i++) {
      if (order[i] == 0) order[i] = rest[r++];
    }
    for (var i = 0; i < 15; i++) {
      final b = balls[order[i]];
      b.x = spots[i][0];
      b.y = spots[i][1];
    }
    cue
      ..x = width / 2
      ..y = headSpotY;
  }

  // ---------------------------------------------------------------- rules helpers
  /// Group balls of [player] still on the table (0 while the table is open).
  int remainingOf(int player) {
    final g = groups[player];
    if (g == BallGroup.open) return 7;
    var n = 0;
    for (var id = 1; id <= 15; id++) {
      if (groupOf(id) == g && !balls[id].potted) n++;
    }
    return n;
  }

  int pottedOf(int player) => groups[player] == BallGroup.open ? 0 : 7 - remainingOf(player);

  /// [player] has cleared their group and now shoots at the 8.
  bool onEight(int player) => groups[player] != BallGroup.open && remainingOf(player) == 0;

  /// Balls [player] may legally strike first.
  List<int> legalTargets(int player) {
    final out = <int>[];
    if (isBreak) {
      for (var id = 1; id <= 15; id++) {
        if (!balls[id].potted) out.add(id);
      }
      return out;
    }
    final g = groups[player];
    if (onEight(player)) {
      if (!balls[8].potted) out.add(8);
      return out;
    }
    for (var id = 1; id <= 15; id++) {
      if (id == 8 || balls[id].potted) continue;
      if (g == BallGroup.open || groupOf(id) == g) out.add(id);
    }
    return out;
  }

  bool _legalFirst(int player, int id) {
    if (id <= 0) return false;
    if (isBreak) return true;
    if (onEight(player)) return id == 8;
    if (id == 8) return false;
    final g = groups[player];
    return g == BallGroup.open || groupOf(id) == g;
  }

  /// Whether the cue ball may be put down at (x, y) with the current ball-in-hand.
  bool canPlaceCue(double x, double y) {
    if (!x.isFinite || !y.isFinite) return false;
    const r = ballRadius;
    if (x < r || x > width - r || y < r || y > height - r) return false;
    if (kitchenOnly && y < kitchenY) return false;
    return _spotFree(x, y, 0);
  }

  bool _spotFree(double x, double y, int ignore) {
    const minD2 = 4 * ballRadius * ballRadius - 1e-9;
    for (final b in balls) {
      if (b.id == ignore || b.potted) continue;
      final dx = b.x - x, dy = b.y - y;
      if (dx * dx + dy * dy < minD2) return false;
    }
    for (var p = 0; p < 6; p++) {
      final dx = pocketX[p] - x, dy = pocketY[p] - y;
      final lim = pocketCapture[p] + 0.05;
      if (dx * dx + dy * dy < lim * lim) return false;
    }
    return true;
  }

  /// Deterministic spiral search for a free spot near (x, y).
  void _placeNear(CueBall b, double x, double y, {bool kitchen = false}) {
    b.potted = false;
    b.vx = 0;
    b.vy = 0;
    for (var ring = 0; ring < 60; ring++) {
      final rad = ring * 0.2;
      final n = ring == 0 ? 1 : 6 * ring;
      for (var k = 0; k < n; k++) {
        final a = k * math.pi * 2 / n;
        final px = x + math.cos(a) * rad, py = y + math.sin(a) * rad;
        const r = ballRadius;
        if (px < r || px > width - r || py < r || py > height - r) continue;
        if (kitchen && py < kitchenY) continue;
        if (_spotFree(px, py, b.id)) {
          b.x = px;
          b.y = py;
          return;
        }
      }
    }
    b.x = x;
    b.y = y;
  }

  // ---------------------------------------------------------------- moves
  /// Plays [shot] for [player]. Returns false (and changes nothing) when it is
  /// not that player's turn, a shot is still rolling, the match is over, or the
  /// move is malformed (bad power/spin or an illegal cue placement).
  bool submitMove(int player, CueShot shot) {
    if (phase != CuePhase.aiming || player != current || winner != null) return false;
    if (!shot.angle.isFinite || !shot.power.isFinite || shot.power <= 0 || shot.power > 1) return false;
    if (!shot.spin.isFinite || shot.spin.abs() > 1) return false;
    if (shot.places) {
      if (!ballInHand || !canPlaceCue(shot.cueX!, shot.cueY!)) return false;
      cue
        ..x = shot.cueX!
        ..y = shot.cueY!;
    }
    history.add(shot);
    _shooter = player;
    _wasOnEight = onEight(player);
    _firstContact = -1;
    _rail = false;
    _spin = shot.spin;
    _spinUsed = false;
    _shotTicks = 0;
    _report = ShotReport(player, isBreak);
    ballInHand = false;
    final v = shot.power * maxShotSpeed;
    cue
      ..vx = math.cos(shot.angle) * v
      ..vy = math.sin(shot.angle) * v;
    phase = CuePhase.rolling;
    return true;
  }

  /// Runs the current shot to rest (fast path used by the CPU and tests).
  void runUntilRest() {
    while (phase == CuePhase.rolling) {
      step();
    }
  }

  /// Plays [shot] on a copy of this world and returns that copy after every
  /// ball has stopped (its [lastReport] describes the outcome), or null when
  /// the move would be rejected. This world is not changed.
  CueWorld? simulateShot(CueShot shot) {
    final w = CueWorld._copy(this);
    if (!w.submitMove(current, shot)) return null;
    w.runUntilRest();
    return w;
  }

  /// Copy of the table state without the move history.
  CueWorld copy() => CueWorld._copy(this);

  /// Advances the rolling shot by real time [dt] through fixed steps.
  void update(double dt, {int maxSteps = 24}) {
    if (phase != CuePhase.rolling) {
      _acc = 0;
      return;
    }
    _acc += dt;
    var n = 0;
    while (_acc >= stepDt && n < maxSteps && phase == CuePhase.rolling) {
      _acc -= stepDt;
      step();
      n++;
    }
    if (n >= maxSteps) _acc = 0;
  }

  // ---------------------------------------------------------------- physics
  /// One fixed simulation tick. Does nothing unless a shot is rolling.
  void step() {
    if (phase != CuePhase.rolling) return;
    _tick++;
    _shotTicks++;
    const h = stepDt / substeps;
    for (var s = 0; s < substeps; s++) {
      for (final b in balls) {
        if (b.potted || !b.moving) continue;
        b.x += b.vx * h;
        b.y += b.vy * h;
      }
      for (final b in balls) {
        if (b.potted || !b.moving) continue;
        _cushion(b);
      }
      _collideAll();
      for (final b in balls) {
        if (b.potted || !b.moving) continue;
        _pocketCheck(b);
      }
    }
    for (final b in balls) {
      if (b.potted || !b.moving) continue;
      applyFriction(b, stepDt);
    }
    if (!anyMoving || _shotTicks >= maxShotTicks) {
      for (final b in balls) {
        b.vx = 0;
        b.vy = 0;
      }
      _resolve();
    }
  }

  /// Rolling friction for one tick of length [dt]; snaps to rest below [sleepSpeed].
  static void applyFriction(CueBall b, double dt) {
    final sp = b.speed;
    if (sp == 0) return;
    final drag = dt == stepDt ? _dragPerStep : math.exp(-rollDrag * dt);
    final ns = sp * drag - rollDecel * dt;
    if (ns <= sleepSpeed) {
      b.vx = 0;
      b.vy = 0;
      return;
    }
    final k = ns / sp;
    b.vx *= k;
    b.vy *= k;
  }

  void _collideAll() {
    for (var i = 0; i < 15; i++) {
      final a = balls[i];
      if (a.potted) continue;
      for (var j = i + 1; j < 16; j++) {
        final b = balls[j];
        if (b.potted || (!a.moving && !b.moving)) continue;
        final cueVx = a.vx, cueVy = a.vy;
        final impulse = resolvePair(a, b);
        if (impulse < 0) continue;
        if (impulse > 0) ballClicks++;
        if (a.id == 0 && _firstContact < 0) {
          _firstContact = b.id;
          if (_spin != 0 && !_spinUsed) {
            _spinUsed = true;
            final sp = math.sqrt(cueVx * cueVx + cueVy * cueVy);
            if (sp > 0) {
              final k = _spin * spinTransfer * impulse / sp;
              a.vx += cueVx * k;
              a.vy += cueVy * k;
            }
          }
        }
      }
    }
  }

  /// Equal-mass, perfectly elastic collision between two touching balls.
  ///
  /// Returns -1 when they do not overlap, otherwise the normal speed exchanged
  /// (0 when overlapping but already separating, after nudging them apart).
  static double resolvePair(CueBall a, CueBall b) {
    const minD = ballRadius * 2;
    var dx = b.x - a.x, dy = b.y - a.y;
    final d2 = dx * dx + dy * dy;
    if (d2 >= minD * minD) return -1;
    var d = math.sqrt(d2);
    if (d < 1e-9) {
      dx = 1;
      dy = 0;
      d = 1;
    } else {
      dx /= d;
      dy /= d;
    }
    // Push apart so they just touch.
    final push = (minD - (d2 < 1e-18 ? 0 : d)) / 2;
    a.x -= dx * push;
    a.y -= dy * push;
    b.x += dx * push;
    b.y += dy * push;
    final rel = (a.vx - b.vx) * dx + (a.vy - b.vy) * dy;
    if (rel <= 0) return 0;
    a.vx -= rel * dx;
    a.vy -= rel * dy;
    b.vx += rel * dx;
    b.vy += rel * dy;
    return rel;
  }

  void _cushion(CueBall b) {
    for (var s = 0; s < cushions.length; s += 4) {
      final ax = cushions[s], ay = cushions[s + 1], bx = cushions[s + 2], by = cushions[s + 3];
      if (reflectOffSegment(b, ax, ay, bx, by)) {
        cushionHits++;
        if (_firstContact >= 0) _rail = true;
      }
    }
  }

  /// Bounces [b] off the segment (ax, ay)-(bx, by) (rounded ends act as pocket jaws).
  static bool reflectOffSegment(CueBall b, double ax, double ay, double bx, double by) {
    final sx = bx - ax, sy = by - ay;
    final len2 = sx * sx + sy * sy;
    var t = ((b.x - ax) * sx + (b.y - ay) * sy) / len2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final cx = ax + sx * t, cy = ay + sy * t;
    var nx = b.x - cx, ny = b.y - cy;
    final d2 = nx * nx + ny * ny;
    if (d2 >= ballRadius * ballRadius) return false;
    final d = math.sqrt(d2);
    if (d < 1e-9) {
      // Centre exactly on the cushion line: push back towards the table centre.
      nx = width / 2 - cx;
      ny = height / 2 - cy;
      final l = math.sqrt(nx * nx + ny * ny);
      nx /= l;
      ny /= l;
    } else {
      nx /= d;
      ny /= d;
    }
    b.x = cx + nx * ballRadius;
    b.y = cy + ny * ballRadius;
    final vn = b.vx * nx + b.vy * ny;
    if (vn >= 0) return false;
    b.vx -= (1 + cushionRestitution) * vn * nx;
    b.vy -= (1 + cushionRestitution) * vn * ny;
    return true;
  }

  void _pocketCheck(CueBall b) {
    const r = ballRadius;
    var hit = -1;
    for (var p = 0; p < 6; p++) {
      final dx = b.x - pocketX[p], dy = b.y - pocketY[p];
      final c = pocketCapture[p];
      if (dx * dx + dy * dy < c * c) {
        hit = p;
        break;
      }
    }
    if (hit < 0 && (b.x < -r || b.x > width + r || b.y < -r || b.y > height + r)) {
      // Escaped through a mouth: credit the nearest pocket.
      var best = double.infinity;
      for (var p = 0; p < 6; p++) {
        final dx = b.x - pocketX[p], dy = b.y - pocketY[p];
        final d2 = dx * dx + dy * dy;
        if (d2 < best) {
          best = d2;
          hit = p;
        }
      }
    }
    if (hit < 0) return;
    b
      ..potted = true
      ..vx = 0
      ..vy = 0
      ..x = pocketX[hit]
      ..y = pocketY[hit];
    pots++;
    lastPotX = pocketX[hit];
    lastPotY = pocketY[hit];
    _report?.potted.add(b.id);
  }

  // ---------------------------------------------------------------- resolution
  void _resolve() {
    final p = _shooter, opp = 1 - p;
    final rep = _report ?? ShotReport(p, isBreak);
    final wasBreak = isBreak;
    final wasOpen = groups[p] == BallGroup.open;
    rep.firstContact = _firstContact;
    rep.railAfterContact = _rail;
    final cuePotted = cue.potted;
    var objectPots = 0;
    var firstObject = -1;
    var ownPots = 0;
    var eight = false;
    for (final id in rep.potted) {
      if (id == 0) continue;
      if (id == 8) {
        eight = true;
        continue;
      }
      objectPots++;
      if (firstObject < 0) firstObject = id;
      if (!wasOpen && groupOf(id) == groups[p]) ownPots++;
    }
    var foul = CueFoul.none;
    if (cuePotted) {
      foul = CueFoul.scratch;
    } else if (_firstContact < 0) {
      foul = CueFoul.noContact;
    } else if (!_legalFirst(p, _firstContact)) {
      foul = CueFoul.wrongBall;
    } else if (!wasBreak && objectPots == 0 && !eight && !_rail) {
      foul = CueFoul.noRail;
    }
    rep.foul = foul;
    shotsResolved++;
    lastReport = rep;
    _report = null;

    if (eight) {
      if (wasBreak) {
        _placeNear(balls[8], width / 2, footSpotY);
        rep.eightRespotted = true;
      } else {
        final legal = foul == CueFoul.none && _wasOnEight;
        winner = legal ? p : opp;
        endReason = legal
            ? CueEnd.eightLegal
            : foul != CueFoul.none
            ? CueEnd.eightFoul
            : CueEnd.eightEarly;
        rep.end = endReason;
        phase = CuePhase.over;
        return;
      }
    }

    if (!wasBreak && foul == CueFoul.none && wasOpen && firstObject > 0) {
      groups[p] = groupOf(firstObject);
      groups[opp] = groups[p] == BallGroup.solids ? BallGroup.stripes : BallGroup.solids;
      rep.assigned = groups[p];
    }

    var keep = false;
    if (foul == CueFoul.none) {
      keep = wasBreak || wasOpen ? objectPots > 0 : ownPots > 0;
    }
    rep.turnKept = keep;
    isBreak = false;
    if (foul != CueFoul.none) {
      current = opp;
      ballInHand = true;
      kitchenOnly = wasBreak;
      if (cuePotted || !canPlaceCue(cue.x, cue.y)) {
        _placeNear(cue, width / 2, headSpotY, kitchen: kitchenOnly);
      }
    } else {
      kitchenOnly = false;
      if (!keep) current = opp;
    }
    phase = CuePhase.aiming;
  }

  // ---------------------------------------------------------------- aiming
  /// Casts the cue ball along [angle] from its spot (or from [fromX], [fromY])
  /// and fills [out] with the first ball or cushion it would reach.
  void previewAim(double angle, AimPreview out, {double? fromX, double? fromY}) {
    final ox = fromX ?? cue.x, oy = fromY ?? cue.y;
    final dx = math.cos(angle), dy = math.sin(angle);
    const r = ballRadius;
    // Cushion: the inset rectangle the ball centre can reach.
    var best = double.infinity;
    if (dx > 1e-9) best = math.min(best, (width - r - ox) / dx);
    if (dx < -1e-9) best = math.min(best, (r - ox) / dx);
    if (dy > 1e-9) best = math.min(best, (height - r - oy) / dy);
    if (dy < -1e-9) best = math.min(best, (r - oy) / dy);
    if (best < 0) best = 0;
    var hit = -1;
    const rr = 4 * r * r;
    for (final b in balls) {
      if (b.id == 0 || b.potted) continue;
      final fx = ox - b.x, fy = oy - b.y;
      final bq = fx * dx + fy * dy;
      final c = fx * fx + fy * fy - rr;
      final disc = bq * bq - c;
      if (disc < 0) continue;
      final t = -bq - math.sqrt(disc);
      if (t >= -1e-9 && t < best) {
        best = math.max(0, t);
        hit = b.id;
      }
    }
    out
      ..hitBall = hit
      ..ghostX = ox + dx * best
      ..ghostY = oy + dy * best;
    if (hit >= 0) {
      final b = balls[hit];
      var nx = b.x - out.ghostX, ny = b.y - out.ghostY;
      final l = math.sqrt(nx * nx + ny * ny);
      nx /= l;
      ny /= l;
      out
        ..objDirX = nx
        ..objDirY = ny;
      final vn = dx * nx + dy * ny;
      var tx = dx - vn * nx, ty = dy - vn * ny;
      final tl = math.sqrt(tx * tx + ty * ty);
      if (tl > 1e-6) {
        tx /= tl;
        ty /= tl;
      } else {
        tx = 0;
        ty = 0;
      }
      out
        ..cueDirX = tx
        ..cueDirY = ty;
    } else {
      out
        ..objDirX = 0
        ..objDirY = 0
        ..cueDirX = 0
        ..cueDirY = 0;
    }
  }

  /// Whether the straight path of a ball from (ax, ay) to (bx, by) misses every
  /// ball other than [skipA] and [skipB].
  bool pathClear(double ax, double ay, double bx, double by, int skipA, int skipB) {
    final sx = bx - ax, sy = by - ay;
    final len2 = sx * sx + sy * sy;
    const lim = 4 * ballRadius * ballRadius * 0.98;
    for (final b in balls) {
      if (b.potted || b.id == skipA || b.id == skipB) continue;
      var t = len2 > 0 ? ((b.x - ax) * sx + (b.y - ay) * sy) / len2 : 0.0;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final cx = ax + sx * t - b.x, cy = ay + sy * t - b.y;
      if (cx * cx + cy * cy < lim) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- sync
  /// Cheap fingerprint of the full rules state for lockstep desync checks.
  int stateHash() {
    var h = 17;
    void mix(int v) => h = (h * 31 + v) & 0x3fffffff;
    int r(double v) => (v * 1000).round();
    mix(_tick);
    mix(history.length);
    mix(current);
    mix(phase.index);
    mix(groups[0].index);
    mix(groups[1].index);
    mix(ballInHand ? 1 : 0);
    mix(kitchenOnly ? 1 : 0);
    mix(isBreak ? 1 : 0);
    mix(winner ?? -1);
    for (final b in balls) {
      mix(b.potted ? 1 : 0);
      mix(r(b.x));
      mix(r(b.y));
      mix(r(b.vx));
      mix(r(b.vy));
    }
    return h;
  }

  // ---------------------------------------------------------------- debug
  /// Test helper: puts ball [id] at (x, y) with a velocity (un-pots it).
  void debugPlace(int id, double x, double y, [double vx = 0, double vy = 0]) {
    balls[id]
      ..x = x
      ..y = y
      ..vx = vx
      ..vy = vy
      ..potted = false;
  }

  /// Test helper: takes ball [id] off the table.
  void debugRemove(int id) {
    balls[id]
      ..potted = true
      ..vx = 0
      ..vy = 0
      ..x = -5
      ..y = -5;
  }

  /// Test helper: clears the table except the cue ball and [keep].
  void debugClearExcept(List<int> keep) {
    for (var id = 1; id <= 15; id++) {
      if (!keep.contains(id)) debugRemove(id);
    }
  }

  /// Test helper: skips the break and sets groups / shooter directly.
  void debugSetup({required int shooter, BallGroup p0 = BallGroup.open, bool inHand = false}) {
    isBreak = false;
    kitchenOnly = false;
    ballInHand = inHand;
    current = shooter;
    groups[0] = p0;
    groups[1] = p0 == BallGroup.open
        ? BallGroup.open
        : p0 == BallGroup.solids
        ? BallGroup.stripes
        : BallGroup.solids;
  }

  /// Test helper: lets a world in motion (balls placed with velocity) roll
  /// as if a shot by the current player was struck.
  void debugRoll() {
    _shooter = current;
    _wasOnEight = onEight(current);
    _firstContact = -1;
    _rail = false;
    _spin = 0;
    _spinUsed = false;
    _shotTicks = 0;
    _report = ShotReport(current, isBreak);
    phase = CuePhase.rolling;
  }
}

// =================================================================== CPU

enum CpuLevel { easy, normal, hard }

/// Tuning for one CPU difficulty: how many candidate shots it simulates and
/// how shaky its cue arm is.
class CpuProfile {
  const CpuProfile({
    required this.samples,
    required this.aimNoise,
    required this.powerNoise,
    required this.lookAhead,
    required this.placesCue,
  });

  final int samples;

  /// Standard deviation of the executed angle error (radians).
  final double aimNoise;
  final double powerNoise;

  /// Weighs the opponent's follow-up chances when the turn passes.
  final bool lookAhead;

  /// Uses ball-in-hand to set up a straight shot (otherwise shoots from where the cue ball lies).
  final bool placesCue;

  static const easy = CpuProfile(
    samples: 5,
    aimNoise: 0.05,
    powerNoise: 0.1,
    lookAhead: false,
    placesCue: false,
  );
  static const normal = CpuProfile(
    samples: 14,
    aimNoise: 0.016,
    powerNoise: 0.04,
    lookAhead: false,
    placesCue: true,
  );
  static const hard = CpuProfile(
    samples: 34,
    aimNoise: 0.004,
    powerNoise: 0.015,
    lookAhead: true,
    placesCue: true,
  );

  static CpuProfile of(CpuLevel level) => switch (level) {
    CpuLevel.easy => easy,
    CpuLevel.normal => normal,
    CpuLevel.hard => hard,
  };
}

class _Candidate {
  _Candidate(this.shot, this.heuristic);
  final CueShot shot;
  final double heuristic;
}

/// A CPU player: samples candidate shots, plays each on a copy of the table
/// with [CueWorld.simulateShot], scores the outcomes and returns the best
/// move (with difficulty-dependent aim noise) for [CueWorld.submitMove].
class AiController {
  AiController({required this.player, this.level = CpuLevel.normal, int seed = 0})
    : profile = CpuProfile.of(level),
      _rng = CueRng(seed * 7919 + player * 131 + 17);

  final int player;
  final CpuLevel level;
  final CpuProfile profile;
  final CueRng _rng;

  /// Number of shots simulated by the last [think] call.
  int lastSamples = 0;

  /// Picks this player's next move, or null when it is not their turn.
  CueShot? think(CueWorld w) {
    if (w.phase != CuePhase.aiming || w.current != player || w.isOver) return null;
    lastSamples = 0;
    if (w.isBreak) return _break(w);
    final candidates = _candidates(w);
    CueShot? best;
    var bestScore = double.negativeInfinity;
    for (final c in candidates) {
      final after = w.simulateShot(c.shot);
      lastSamples++;
      if (after == null) continue;
      final s = _score(after) + c.heuristic * 0.01;
      if (s > bestScore) {
        bestScore = s;
        best = c.shot;
      }
    }
    best ??= CueShot(angle: _rng.nextDouble() * math.pi * 2, power: 0.5);
    return _noisy(best);
  }

  CueShot _noisy(CueShot s) {
    final a = s.angle + _rng.nextGaussian() * profile.aimNoise;
    final p = (s.power * (1 + _rng.nextGaussian() * profile.powerNoise)).clamp(0.05, 1.0);
    return CueShot(angle: a, power: p, spin: s.spin, cueX: s.cueX, cueY: s.cueY);
  }

  CueShot _break(CueWorld w) {
    // Break from slightly off-centre for a livelier spread, straight at the apex.
    final dx = (_rng.nextDouble() - 0.5) * 2.4;
    final cx = CueWorld.width / 2 + dx, cy = CueWorld.headSpotY;
    final apex = w.balls[1];
    final a = math.atan2(apex.y - cy, apex.x - cx);
    final power = level == CpuLevel.easy ? 0.8 : 1.0;
    lastSamples = 0;
    return _noisy(CueShot(angle: a, power: power, cueX: cx, cueY: cy));
  }

  List<_Candidate> _candidates(CueWorld w) {
    final geo = <_Candidate>[];
    final targets = w.legalTargets(player);
    final places = w.ballInHand && profile.placesCue;
    for (final id in targets) {
      final b = w.balls[id];
      for (var p = 0; p < 6; p++) {
        final px = CueWorld.pocketX[p], py = CueWorld.pocketY[p];
        var ux = px - b.x, uy = py - b.y;
        final dist = math.sqrt(ux * ux + uy * uy);
        ux /= dist;
        uy /= dist;
        final gx = b.x - ux * CueWorld.ballRadius * 2, gy = b.y - uy * CueWorld.ballRadius * 2;
        if (!w.pathClear(b.x, b.y, px, py, id, 0)) continue;
        if (places) {
          // Straight-in shot from a spot behind the ghost ball.
          for (final back in const [1.6, 3.2]) {
            final cx = gx - ux * back, cy = gy - uy * back;
            if (!w.canPlaceCue(cx, cy)) continue;
            if (!w.pathClear(cx, cy, gx, gy, id, 0)) continue;
            final power = _power(back, dist, 1);
            geo.add(
              _Candidate(
                CueShot(angle: math.atan2(uy, ux), power: power, cueX: cx, cueY: cy),
                3 - dist * 0.05 - back * 0.1,
              ),
            );
          }
        }
        final cx = w.cue.x, cy = w.cue.y;
        var ax = gx - cx, ay = gy - cy;
        final len = math.sqrt(ax * ax + ay * ay);
        if (len < 1e-6) continue;
        ax /= len;
        ay /= len;
        final cut = ax * ux + ay * uy;
        if (cut < 0.2) continue;
        if (!w.pathClear(cx, cy, gx, gy, id, 0)) continue;
        final angle = math.atan2(ay, ax);
        final power = _power(len, dist, cut);
        final h = cut * 2 - (len + dist) * 0.05;
        geo.add(_Candidate(CueShot(angle: angle, power: power), h));
        geo.add(_Candidate(CueShot(angle: angle, power: math.min(1, power * 1.35)), h - 0.3));
        if (profile.lookAhead) {
          geo.add(_Candidate(CueShot(angle: angle, power: power, spin: -0.6), h - 0.4));
          geo.add(_Candidate(CueShot(angle: angle, power: power, spin: 0.6), h - 0.4));
        }
      }
    }
    geo.sort((a, b) => b.heuristic.compareTo(a.heuristic));
    final n = profile.samples;
    final out = <_Candidate>[];
    final geoCount = math.min(geo.length, (n * 0.75).ceil());
    for (var i = 0; i < geoCount; i++) {
      out.add(geo[i]);
    }
    // Safety / exploration shots: aim at legal balls with varied cut and power.
    while (out.length < n) {
      CueShot shot;
      if (targets.isNotEmpty && _rng.nextDouble() < 0.7) {
        final b = w.balls[targets[_rng.nextInt(targets.length)]];
        final base = math.atan2(b.y - w.cue.y, b.x - w.cue.x);
        shot = CueShot(
          angle: base + (_rng.nextDouble() - 0.5) * 0.12,
          power: 0.25 + _rng.nextDouble() * 0.5,
        );
      } else {
        shot = CueShot(angle: _rng.nextDouble() * math.pi * 2, power: 0.3 + _rng.nextDouble() * 0.6);
      }
      out.add(_Candidate(shot, -5));
    }
    return out;
  }

  /// Rough strike strength to send an object ball [objDist] after the cue
  /// ball travels [cueDist] and transfers [cut] of its speed.
  static double _power(double cueDist, double objDist, double cut) {
    final vObj = math.sqrt(2 * CueWorld.rollDecel * (objDist + 0.6)) * 1.25 + 1.2;
    final vCue = math.sqrt(math.pow(vObj / math.max(cut, 0.25), 2) + 2 * CueWorld.rollDecel * cueDist);
    return (vCue / CueWorld.maxShotSpeed).clamp(0.12, 1.0);
  }

  double _score(CueWorld after) {
    final r = after.lastReport!;
    if (after.winner != null) return after.winner == player ? 100000 : -100000;
    var s = 0.0;
    final mine = after.groups[player];
    for (final id in r.potted) {
      if (id == 0 || id == 8) continue;
      if (mine == BallGroup.open || CueWorld.groupOf(id) == mine) {
        s += 40;
      } else {
        s -= 25;
      }
    }
    if (r.foul != CueFoul.none) s -= 150;
    if (after.current == player) {
      s += 120 + 8 * math.min(6, openShots(after, player));
    } else if (profile.lookAhead) {
      s -= after.ballInHand ? 60 : 7 * math.min(6, openShots(after, 1 - player));
    }
    return s;
  }

  /// Number of makeable (clear, not too thin) pots [who] has from the current cue position.
  static int openShots(CueWorld w, int who) {
    var n = 0;
    final cx = w.cue.x, cy = w.cue.y;
    for (final id in w.legalTargets(who)) {
      final b = w.balls[id];
      for (var p = 0; p < 6; p++) {
        final px = CueWorld.pocketX[p], py = CueWorld.pocketY[p];
        var ux = px - b.x, uy = py - b.y;
        final dist = math.sqrt(ux * ux + uy * uy);
        ux /= dist;
        uy /= dist;
        final gx = b.x - ux * CueWorld.ballRadius * 2, gy = b.y - uy * CueWorld.ballRadius * 2;
        var ax = gx - cx, ay = gy - cy;
        final len = math.sqrt(ax * ax + ay * ay);
        if (len < 1e-6) continue;
        if ((ax * ux + ay * uy) / len < 0.5) continue;
        if (!w.pathClear(b.x, b.y, px, py, id, 0)) continue;
        if (!w.pathClear(cx, cy, gx, gy, id, 0)) continue;
        n++;
      }
    }
    return n;
  }
}
