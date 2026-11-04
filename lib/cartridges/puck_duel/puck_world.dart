import 'dart:math' as math;

/// One player's command for a single simulation tick: where their mallet
/// should head, in table units.
///
/// Every action (human touch, CPU, or a future remote peer) enters the rules
/// only through [PuckWorld.setInput] as one of these plain value objects.
class PuckInput {
  const PuckInput(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) => other is PuckInput && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'PuckInput($x, $y)';
}

/// A round paddle owned by one player.
class Mallet {
  Mallet(this.x, this.y) : targetX = x, targetY = y;

  double x, y;

  /// Velocity over the last tick (units / second), used when striking the puck.
  double vx = 0, vy = 0;
  double targetX, targetY;
}

/// Pure, deterministic rules for a two-player table-puck duel.
///
/// Table coordinates: x in [0, width] left to right, y in [0, height] top to
/// bottom. Player 0 owns the bottom half and defends the goal at y = height;
/// player 1 owns the top half and defends the goal at y = 0.
///
/// The simulation advances only through fixed [stepDt] ticks ([step]);
/// [update] feeds them from a frame-time accumulator.
class PuckWorld {
  PuckWorld({int seed = 0, this.winScore = defaultWinScore})
    : mallets = [Mallet(width / 2, height - 2.2), Mallet(width / 2, 2.2)] {
    final first = math.Random(seed).nextBool() ? 0 : 1;
    _servePuck(first);
  }

  static const double width = 10;
  static const double height = 17;
  static const double malletRadius = 0.8;
  static const double puckRadius = 0.5;

  /// Goal mouth width (35 % of the table width), centred on each short wall.
  static const double goalWidth = width * 0.35;
  static const double goalLeft = (width - goalWidth) / 2;
  static const double goalRight = (width + goalWidth) / 2;

  static const double stepDt = 1 / 120;
  static const int defaultWinScore = 7;

  /// Mallet speed cap (units / second) for every player.
  static const double malletMaxSpeed = 24;

  /// Puck speed cap (units / second).
  static const double puckMaxSpeed = 28;

  /// Exponential air drag on the puck (per second).
  static const double friction = 0.25;
  static const double wallRestitution = 0.88;
  static const double malletRestitution = 0.85;

  /// Ticks the puck sits still after a goal before play resumes.
  static const int serveTicks = 84;

  /// Ticks the puck may linger in one half before it is handed to the other
  /// player (an anti-stall shot clock).
  static const int shotClockTicks = 7 * 120;

  static final double _dragPerStep = math.exp(-friction * stepDt);

  final int winScore;
  final List<Mallet> mallets;
  final List<int> scores = [0, 0];

  double puckX = width / 2, puckY = height / 2;
  double puckVx = 0, puckVy = 0;

  int _tick = 0;
  int get tick => _tick;

  /// Remaining ticks of the post-goal pause; the puck is frozen while > 0.
  int serveTimer = 0;

  /// Index of the winner once someone reaches [winScore].
  int? winner;

  // Event counters, polled by the renderer for sounds and effects.
  int malletHits = 0;
  int wallHits = 0;
  int goals = 0;
  int lastScorer = -1;
  int turnovers = 0;

  /// Ticks the puck has spent in its current half ([lingerSide]) since play resumed.
  int lingerTicks = 0;
  int lingerSide = 0;

  double _acc = 0;

  bool get isOver => winner != null;

  /// Player 0 (the local / bottom player) won.
  bool get won => winner == 0;

  /// Goals scored by player 0.
  int get score => scores[0];

  int get entityCount => 3;

  // ------------------------------------------------------------------ bounds
  static double minYFor(int player) => player == 0 ? height / 2 + malletRadius : malletRadius;
  static double maxYFor(int player) => player == 0 ? height - malletRadius : height / 2 - malletRadius;
  static double get minX => malletRadius;
  static double get maxX => width - malletRadius;

  // ------------------------------------------------------------------ input
  /// Sets where [player]'s mallet heads from the next tick on. Coordinates are
  /// quantised to 1/1000 unit so a lockstep transport can ship them exactly.
  void setInput(int player, PuckInput input) {
    final m = mallets[player];
    m.targetX = _q(input.x.clamp(minX, maxX));
    m.targetY = _q(input.y.clamp(minYFor(player), maxYFor(player)));
  }

  static double _q(double v) => (v * 1000).roundToDouble() / 1000;

  // ------------------------------------------------------------------ time
  /// Advances by real frame time; [ais] pick their input right before each tick.
  void update(double dt, [List<AiController> ais = const []]) {
    if (isOver) return;
    _acc += dt.clamp(0.0, 0.1);
    while (_acc >= stepDt && !isOver) {
      _acc -= stepDt;
      for (final ai in ais) {
        setInput(ai.player, ai.think(this));
      }
      step();
    }
  }

  /// One fixed simulation tick.
  void step() {
    if (isOver) return;
    _tick++;
    for (var p = 0; p < mallets.length; p++) {
      _moveMallet(mallets[p]);
    }
    if (serveTimer > 0) {
      serveTimer--;
      return;
    }
    puckVx *= _dragPerStep;
    puckVy *= _dragPerStep;
    puckX += puckVx * stepDt;
    puckY += puckVy * stepDt;
    for (final m in mallets) {
      _collideMallet(m);
    }
    _collideWalls();
    _capSpeed();
    if (puckY < 0) {
      _goal(0);
    } else if (puckY > height) {
      _goal(1);
    } else {
      _shotClock();
    }
  }

  void _shotClock() {
    final side = puckY > height / 2 ? 0 : 1;
    if (side != lingerSide) {
      lingerSide = side;
      lingerTicks = 0;
    } else if (++lingerTicks > shotClockTicks) {
      turnovers++;
      _servePuck(1 - side);
    }
  }

  /// Seconds left on the shot clock for the half holding the puck.
  double get shotClockLeft => (shotClockTicks - lingerTicks) * stepDt;

  void _moveMallet(Mallet m) {
    final dx = m.targetX - m.x;
    final dy = m.targetY - m.y;
    final d = math.sqrt(dx * dx + dy * dy);
    const maxStep = malletMaxSpeed * stepDt;
    double nx, ny;
    if (d <= maxStep) {
      nx = m.targetX;
      ny = m.targetY;
    } else {
      nx = m.x + dx / d * maxStep;
      ny = m.y + dy / d * maxStep;
    }
    m.vx = (nx - m.x) / stepDt;
    m.vy = (ny - m.y) / stepDt;
    m.x = nx;
    m.y = ny;
  }

  void _collideMallet(Mallet m) {
    const reach = malletRadius + puckRadius;
    var dx = puckX - m.x;
    var dy = puckY - m.y;
    final d2 = dx * dx + dy * dy;
    if (d2 >= reach * reach) return;
    var d = math.sqrt(d2);
    if (d < 1e-9) {
      dx = 0;
      dy = m.y > height / 2 ? -1 : 1;
      d = 1;
    }
    final nx = dx / d, ny = dy / d;
    puckX = m.x + nx * reach;
    puckY = m.y + ny * reach;
    final rvx = puckVx - m.vx;
    final rvy = puckVy - m.vy;
    final vn = rvx * nx + rvy * ny;
    if (vn < 0) {
      puckVx -= (1 + malletRestitution) * vn * nx;
      puckVy -= (1 + malletRestitution) * vn * ny;
      if (vn < -1) malletHits++;
    }
  }

  static bool inMouth(double x) => x > goalLeft && x < goalRight;

  void _collideWalls() {
    const r = puckRadius;
    var bounced = false;
    if (puckX < r) {
      puckX = r;
      if (puckVx < 0) {
        puckVx = -puckVx * wallRestitution;
        bounced = true;
      }
    } else if (puckX > width - r) {
      puckX = width - r;
      if (puckVx > 0) {
        puckVx = -puckVx * wallRestitution;
        bounced = true;
      }
    }
    if (!inMouth(puckX)) {
      if (puckY < r) {
        puckY = r;
        if (puckVy < 0) {
          puckVy = -puckVy * wallRestitution;
          bounced = true;
        }
      } else if (puckY > height - r) {
        puckY = height - r;
        if (puckVy > 0) {
          puckVy = -puckVy * wallRestitution;
          bounced = true;
        }
      }
    }
    // Goal posts: the four mouth corners act as point obstacles.
    if (_collidePost(goalLeft, 0) ||
        _collidePost(goalRight, 0) ||
        _collidePost(goalLeft, height) ||
        _collidePost(goalRight, height)) {
      bounced = true;
    }
    if (bounced && puckVx * puckVx + puckVy * puckVy > 1) wallHits++;
  }

  bool _collidePost(double cx, double cy) {
    final dx = puckX - cx, dy = puckY - cy;
    final d2 = dx * dx + dy * dy;
    if (d2 >= puckRadius * puckRadius || d2 < 1e-12) return false;
    final d = math.sqrt(d2);
    final nx = dx / d, ny = dy / d;
    puckX = cx + nx * puckRadius;
    puckY = cy + ny * puckRadius;
    final vn = puckVx * nx + puckVy * ny;
    if (vn >= 0) return false;
    puckVx -= (1 + wallRestitution) * vn * nx;
    puckVy -= (1 + wallRestitution) * vn * ny;
    return true;
  }

  void _capSpeed() {
    final s2 = puckVx * puckVx + puckVy * puckVy;
    if (s2 > puckMaxSpeed * puckMaxSpeed) {
      final k = puckMaxSpeed / math.sqrt(s2);
      puckVx *= k;
      puckVy *= k;
    }
  }

  void _goal(int scorer) {
    scores[scorer]++;
    goals++;
    lastScorer = scorer;
    if (scores[scorer] >= winScore) {
      winner = scorer;
    }
    _servePuck(1 - scorer);
  }

  /// Places the puck, at rest, in the middle of [player]'s half.
  void _servePuck(int player) {
    puckX = width / 2;
    puckY = player == 0 ? height * 0.75 : height * 0.25;
    puckVx = 0;
    puckVy = 0;
    serveTimer = serveTicks;
    lingerSide = player;
    lingerTicks = 0;
    // Keep the serve spot clear of the receiving mallet.
    final m = mallets[player];
    const reach = malletRadius + puckRadius + 0.1;
    if ((m.x - puckX).abs() < reach && (m.y - puckY).abs() < reach) {
      m.y = player == 0 ? math.min(maxYFor(0), puckY + reach) : math.max(minYFor(1), puckY - reach);
      m.targetX = m.x;
      m.targetY = m.y;
    }
  }

  // ------------------------------------------------------------------ sync
  /// Cheap fingerprint of the simulation state for lockstep desync checks.
  int stateHash() {
    var h = 17;
    void mix(int v) => h = (h * 31 + v) & 0x3fffffff;
    int r(double v) => (v * 1000).round();
    mix(_tick);
    mix(scores[0]);
    mix(scores[1]);
    mix(serveTimer);
    mix(lingerTicks);
    mix(winner ?? -1);
    mix(r(puckX));
    mix(r(puckY));
    mix(r(puckVx));
    mix(r(puckVy));
    for (final m in mallets) {
      mix(r(m.x));
      mix(r(m.y));
    }
    return h;
  }

  // ------------------------------------------------------------------ debug
  /// Test helper: puts the puck somewhere with a velocity and ends any serve pause.
  void debugPlacePuck(double x, double y, [double vx = 0, double vy = 0]) {
    puckX = x;
    puckY = y;
    puckVx = vx;
    puckVy = vy;
    serveTimer = 0;
    lingerSide = y > height / 2 ? 0 : 1;
    lingerTicks = 0;
  }

  /// Test helper: teleports a mallet (and its target) without imparting velocity.
  void debugPlaceMallet(int player, double x, double y) {
    final m = mallets[player];
    m
      ..x = x
      ..y = y
      ..targetX = x
      ..targetY = y
      ..vx = 0
      ..vy = 0;
  }

  double get puckSpeed => math.sqrt(puckVx * puckVx + puckVy * puckVy);
}

enum CpuLevel { easy, normal, hard }

/// Tuning for one CPU difficulty.
class CpuProfile {
  const CpuProfile({
    required this.reactionTicks,
    required this.maxSpeed,
    required this.defenseDepth,
    required this.track,
    required this.predict,
    required this.aimNoise,
  });

  /// Ticks between re-plans (stale view of the puck in between).
  final int reactionTicks;

  /// The CPU's own mallet speed limit (units / second), below the table cap.
  final double maxSpeed;

  /// Distance of the defensive line in front of its own goal line.
  final double defenseDepth;

  /// How closely (0..1) the defender follows the puck sideways.
  final double track;

  /// Whether the defender predicts where the puck crosses its line.
  final bool predict;

  /// Random sideways error (units) on where it aims shots.
  final double aimNoise;

  static const easy = CpuProfile(
    reactionTicks: 30,
    maxSpeed: 8,
    defenseDepth: 4.2,
    track: 0.45,
    predict: false,
    aimNoise: 3.0,
  );
  static const normal = CpuProfile(
    reactionTicks: 14,
    maxSpeed: 13,
    defenseDepth: 2.6,
    track: 0.8,
    predict: true,
    aimNoise: 1.6,
  );
  static const hard = CpuProfile(
    reactionTicks: 5,
    maxSpeed: 20,
    defenseDepth: 1.7,
    track: 1.0,
    predict: true,
    aimNoise: 0.6,
  );

  static CpuProfile of(CpuLevel level) => switch (level) {
    CpuLevel.easy => easy,
    CpuLevel.normal => normal,
    CpuLevel.hard => hard,
  };
}

/// Computer opponent. Reads the world and returns a [PuckInput] that is fed
/// through [PuckWorld.setInput], exactly like a human or remote player.
class AiController {
  AiController({required this.player, this.level = CpuLevel.normal, int seed = 0})
    : profile = CpuProfile.of(level),
      _rng = math.Random(seed * 7919 + player * 31 + level.index);

  final int player;
  final CpuLevel level;
  final CpuProfile profile;
  final math.Random _rng;

  int _cooldown = 0;
  double _wantX = PuckWorld.width / 2;
  double _wantY = 0;
  double _aimX = PuckWorld.width / 2;
  bool _planned = false;
  int _stuckTicks = 0;

  PuckInput think(PuckWorld w) {
    if (!_planned || _cooldown <= 0) {
      _plan(w);
      _planned = true;
      _cooldown = profile.reactionTicks;
    } else {
      _cooldown--;
    }
    final inOwn = player == 0 ? w.puckY > PuckWorld.height / 2 : w.puckY < PuckWorld.height / 2;
    _stuckTicks = inOwn && w.serveTimer == 0 && w.puckSpeed < 1.5 ? _stuckTicks + 1 : 0;
    final m = w.mallets[player];
    final dx = _wantX - m.x, dy = _wantY - m.y;
    final d = math.sqrt(dx * dx + dy * dy);
    final maxStep = profile.maxSpeed * PuckWorld.stepDt;
    if (d <= maxStep) return PuckInput(_wantX, _wantY);
    return PuckInput(m.x + dx / d * maxStep, m.y + dy / d * maxStep);
  }

  /// Picks a destination in canonical coordinates (own goal at the bottom),
  /// mirrored back for player 1.
  void _plan(PuckWorld w) {
    const h = PuckWorld.height, wd = PuckWorld.width;
    const reach = PuckWorld.malletRadius + PuckWorld.puckRadius;
    final flip = player == 1;
    final px = w.puckX;
    final py = flip ? h - w.puckY : w.puckY;
    final vx = w.puckVx;
    final vy = flip ? -w.puckVy : w.puckVy;
    final m = w.mallets[player];
    final mx = m.x;
    final my = flip ? h - m.y : m.y;

    double tx, ty;
    final inOwn = py > h / 2 - 0.3;
    final threatening = vy > 3;
    final behindPuck = my > py + 0.3;
    if (inOwn && (!threatening || behindPuck) && w.serveTimer < profile.reactionTicks) {
      // Attack: line up behind the puck, facing the opponent's goal, then drive through.
      if (_rng.nextInt(6) == 0 || _aimX == wd / 2) {
        _aimX = wd / 2 + (_rng.nextDouble() * 2 - 1) * profile.aimNoise;
      }
      var ux = px - _aimX, uy = py;
      final ul = math.sqrt(ux * ux + uy * uy);
      ux /= ul;
      uy /= ul;
      final rx = mx - px, ry = my - py;
      final rl = math.sqrt(rx * rx + ry * ry);
      final lined = rl > 1e-6 && (rx * ux + ry * uy) / rl > 0.8 && rl < reach + 2.0;
      final bx = px + ux * (reach + 0.4), by = py + uy * (reach + 0.4);
      final yMax = h - PuckWorld.malletRadius;
      if (_stuckTicks > 360) {
        // Long stalemate: just ram the puck.
        tx = px;
        ty = py;
      } else if (by > yMax - 0.05 && !lined) {
        // Too close to our own back wall to get behind it: knock it sideways.
        final outer = px > wd / 2 ? 1.0 : -1.0;
        final fits = (px + outer * (reach + 0.2) - wd / 2).abs() <= wd / 2 - PuckWorld.malletRadius;
        final side = fits ? outer : -outer;
        final sy = math.min(py, yMax);
        if ((mx - px) * side > reach * 0.9 && (my - sy).abs() < 0.45) {
          tx = px - side * 1.8;
          ty = sy;
        } else {
          tx = px + side * (reach + 0.3);
          ty = sy;
        }
      } else if (lined) {
        tx = px - ux * 1.6;
        ty = py - uy * 1.6;
      } else if (rx * ux + ry * uy < 0.2) {
        // In front of the puck: swing round the side that is closer.
        final side = rx >= 0 ? 1.0 : -1.0;
        tx = px + side * (reach + 0.4);
        ty = py + reach * 0.6;
      } else {
        tx = bx;
        ty = by;
      }
    } else {
      // Defend: hold a line in front of the goal, tracking (or predicting) the puck.
      final defY = h - profile.defenseDepth;
      var xp = px;
      if (profile.predict && vy > 0.5 && py < defY) {
        xp = _fold(px + vx * (defY - py) / vy);
      }
      tx = wd / 2 + (xp - wd / 2) * profile.track;
      const lim = PuckWorld.goalWidth / 2 + 0.4;
      tx = tx.clamp(wd / 2 - lim, wd / 2 + lim);
      ty = defY;
    }
    _wantX = tx.clamp(PuckWorld.minX, PuckWorld.maxX);
    final cy = ty.clamp(h / 2 + PuckWorld.malletRadius, h - PuckWorld.malletRadius);
    _wantY = flip ? h - cy : cy;
  }

  /// Folds an x coordinate back into the table, mirroring off the side walls.
  static double _fold(double x) {
    const lo = PuckWorld.puckRadius, hi = PuckWorld.width - PuckWorld.puckRadius;
    const span = hi - lo;
    var t = (x - lo) % (2 * span);
    if (t < 0) t += 2 * span;
    return lo + (t <= span ? t : 2 * span - t);
  }
}
