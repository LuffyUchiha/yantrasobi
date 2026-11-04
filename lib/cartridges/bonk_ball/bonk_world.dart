import 'dart:math' as math;

/// One player's command for the next simulation ticks.
///
/// Every action (human buttons, CPU, or a future remote peer) enters the rules
/// only through [BonkWorld.setInput] as one of these plain value objects.
/// [move] is a world-space direction in -1..1 (negative = towards x = 0),
/// quantised to 1/100 when applied.
class BonkInput {
  const BonkInput({this.move = 0, this.jump = false, this.kick = false});

  static const BonkInput none = BonkInput();

  final double move;
  final bool jump;
  final bool kick;

  @override
  bool operator ==(Object other) =>
      other is BonkInput && other.move == move && other.jump == jump && other.kick == kick;

  @override
  int get hashCode => Object.hash(move, jump, kick);

  @override
  String toString() => 'BonkInput(move: $move, jump: $jump, kick: $kick)';
}

/// A big-headed athlete: a round head (the main collider) over a small body box.
class BonkPlayer {
  BonkPlayer(this.index, this.homeX) : x = homeX, y = BonkWorld.standY;

  final int index;
  final double homeX;

  /// Head centre (world units, y up).
  double x, y;
  double vx = 0, vy = 0;
  bool grounded = true;

  /// Ticks left on the active boot swing (the kick hitbox lives while > 0).
  int kickTimer = 0;
  int kickCooldown = 0;

  /// The current swing already struck the ball.
  bool kickLanded = false;

  BonkInput input = BonkInput.none;

  /// Direction this player attacks: player 0 attacks +x, player 1 attacks -x.
  int get facing => index == 0 ? 1 : -1;

  /// Bottom of the feet.
  double get footY => y - BonkWorld.headRadius - BonkWorld.bodyHeight;

  bool get kicking => kickTimer > 0;

  /// 0..1 progress through the current swing (1 when idle).
  double get kickProgress => kicking ? 1 - kickTimer / BonkWorld.kickTicks : 1;

  double get bootX => x + facing * BonkWorld.bootReach;
  double get bootY => footY + BonkWorld.bootLift;

  void reset() {
    x = homeX;
    y = BonkWorld.standY;
    vx = 0;
    vy = 0;
    grounded = true;
    kickTimer = 0;
    kickCooldown = 0;
    kickLanded = false;
  }
}

/// Pure, deterministic rules for a 1v1 big-head football duel, side view.
///
/// World coordinates: x in [0, width] left to right, y up from the ground at
/// y = 0. Player 0 starts on the left, defends the goal at x = 0 and attacks
/// the goal at x = width; player 1 mirrors that.
///
/// The simulation advances only through fixed [stepDt] ticks ([step]);
/// [update] feeds them from a frame-time accumulator.
class BonkWorld {
  BonkWorld({
    int seed = 0,
    this.winScore = defaultWinScore,
    this.matchTicks = defaultMatchTicks,
    this.goldenGoal = false,
  }) : players = [BonkPlayer(0, width * 0.25), BonkPlayer(1, width * 0.75)],
       remainingTicks = matchTicks {
    _kickoff(math.Random(seed).nextBool() ? 0 : 1, kickoffTicksFirst);
  }

  // ------------------------------------------------------------------ geometry
  static const double width = 16;
  static const double height = 9;

  static const double headRadius = 0.75;
  static const double bodyWidth = 0.8;
  static const double bodyHeight = 0.4;

  /// Head-centre height of a player standing on the ground.
  static const double standY = bodyHeight + headRadius;

  /// Full standing height of a player.
  static const double playerHeight = bodyHeight + 2 * headRadius;

  static const double ballRadius = 0.42;

  /// Depth of each goal (from the end wall to the goal line).
  static const double goalDepth = 1.4;

  /// Goal-mouth height at the goal line: about 2.5 player heights.
  static const double goalHeight = playerHeight * 2.5;

  /// The crossbar rises this much towards the back wall, so a ball resting
  /// on it rolls back into play.
  static const double crossbarRise = 0.35;
  static const double crossbarThickness = 0.14;

  // ------------------------------------------------------------------ physics
  static const double stepDt = 1 / 120;
  static const int defaultWinScore = 5;
  static const int defaultMatchTicks = 60 * 120;

  static const double playerGravity = 32;
  static const double jumpSpeed = 13.5;
  static const double moveSpeed = 6.5;
  static const double groundAccel = 60;
  static const double airAccel = 36;

  static const double ballGravity = 20;
  static const double ballDrag = 0.3;
  static const double ballMaxSpeed = 26;
  static const double groundRestitution = 0.72;
  static const double wallRestitution = 0.75;
  static const double crossbarRestitution = 0.65;
  static const double headRestitution = 0.75;
  static const double bodyRestitution = 0.45;

  /// Extra pop added along the contact normal on a moving header.
  static const double headerBoost = 1.2;
  static const double rollFriction = 0.9;

  // ------------------------------------------------------------------ kick
  static const int kickTicks = 16;
  static const int kickCooldownTicks = 40;
  static const double bootReach = 0.8;
  static const double bootLift = 0.25;
  static const double bootRadius = 0.5;
  static const double kickVx = 12;
  static const double kickVy = 10;

  // ------------------------------------------------------------------ flow
  static const int kickoffTicksFirst = 90;
  static const int kickoffTicks = 60;
  static const int goalPauseTicks = 120;
  static const double kickoffBallY = 4.5;

  static final double _dragPerStep = math.exp(-ballDrag * stepDt);
  static final double _rollPerStep = math.exp(-rollFriction * stepDt);

  final int winScore;
  final int matchTicks;

  /// Tie at full time goes to golden goal (2P) instead of a draw (vs CPU).
  final bool goldenGoal;

  final List<BonkPlayer> players;
  final List<int> scores = [0, 0];

  double ballX = width / 2, ballY = kickoffBallY;
  double ballVx = 0, ballVy = 0;

  int _tick = 0;
  int get tick => _tick;

  /// Match clock in ticks; frozen during kickoffs and goal celebrations.
  int remainingTicks;

  /// Frozen countdown before the ball drops at a kickoff.
  int kickoffTimer = 0;

  /// Post-goal celebration ticks (play continues, but nothing counts).
  int goalPause = 0;
  int _nextKickoffSide = 0;
  double _kickoffNudge = 0;

  /// Full time arrived level and [goldenGoal] is on: next goal wins.
  bool goldenGoalActive = false;

  /// Index of the winner, once decided.
  int? winner;

  /// Full time arrived level without golden goal.
  bool isDraw = false;

  // Event counters, polled by the renderer for sounds and effects.
  int headHits = 0;
  int kicks = 0;
  int kickHits = 0;
  int bounces = 0;
  int crossbarHits = 0;
  int jumps = 0;
  int goals = 0;
  int lastScorer = -1;

  /// Player who last touched the ball (-1 = nobody since the kickoff).
  int lastTouch = -1;

  /// The latest goal went in off the conceding player.
  bool lastWasOwnGoal = false;

  double _acc = 0;

  bool get isOver => winner != null || isDraw;

  /// Player 0 (the local / left player) won.
  bool get won => winner == 0;

  /// Goals scored by player 0.
  int get score => scores[0];

  int get entityCount => 3;

  double get secondsLeft => remainingTicks * stepDt;

  bool get ballFrozen => kickoffTimer > 0;

  // ------------------------------------------------------------------ input
  /// Sets what [player] does from the next tick on.
  void setInput(int player, BonkInput input) {
    final m = (input.move.clamp(-1.0, 1.0) * 100).roundToDouble() / 100;
    players[player].input = m == input.move ? input : BonkInput(move: m, jump: input.jump, kick: input.kick);
  }

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
    if (kickoffTimer > 0) {
      kickoffTimer--;
      if (kickoffTimer == 0) ballVx = _kickoffNudge;
      return;
    }
    for (final p in players) {
      _movePlayer(p);
    }
    _collidePlayers(players[0], players[1]);
    _moveBall();
    for (final p in players) {
      _collideHead(p);
      _collideBody(p);
      _tryKick(p);
      if (p.kickTimer > 0) p.kickTimer--;
      if (p.kickCooldown > 0) p.kickCooldown--;
    }
    _capBallSpeed();

    if (goalPause > 0) {
      goalPause--;
      if (goalPause == 0) _kickoff(_nextKickoffSide, kickoffTicks);
      return;
    }
    final scorer = _goalScorer();
    if (scorer != null) {
      _goal(scorer);
      return;
    }
    if (!goldenGoalActive) {
      remainingTicks--;
      if (remainingTicks <= 0) _fullTime();
    }
  }

  // ------------------------------------------------------------------ players
  void _movePlayer(BonkPlayer p) {
    const dt = stepDt;
    final inp = p.input;
    final target = inp.move * moveSpeed;
    final a = (p.grounded ? groundAccel : airAccel) * dt;
    p.vx += (target - p.vx).clamp(-a, a);
    if (inp.jump && p.grounded) {
      p.vy = jumpSpeed;
      p.grounded = false;
      jumps++;
    }
    if (inp.kick && p.kickCooldown == 0) {
      p.kickTimer = kickTicks;
      p.kickCooldown = kickCooldownTicks;
      p.kickLanded = false;
      kicks++;
    }
    p.vy -= playerGravity * dt;
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    p.grounded = false;
    if (p.y <= standY) {
      p.y = standY;
      if (p.vy < 0) p.vy = 0;
      p.grounded = true;
    }
    if (p.y > height - headRadius) {
      p.y = height - headRadius;
      if (p.vy > 0) p.vy = 0;
    }
    if (p.x < headRadius) {
      p.x = headRadius;
      if (p.vx < 0) p.vx = 0;
    } else if (p.x > width - headRadius) {
      p.x = width - headRadius;
      if (p.vx > 0) p.vx = 0;
    }
    // Heads bump the crossbars; a head resting on top slides off into play.
    for (var side = 0; side < 2; side++) {
      final c = _segmentContact(p.x, p.y, headRadius + crossbarThickness / 2, side);
      if (c == null) continue;
      p.x += c.nx * c.depth;
      p.y += c.ny * c.depth;
      final vn = p.vx * c.nx + p.vy * c.ny;
      if (vn < 0) {
        p.vx -= vn * c.nx;
        p.vy -= vn * c.ny;
      }
      if (c.ny > 0.5) p.x += (side == 0 ? 1 : -1) * 2.5 * dt;
    }
  }

  void _collidePlayers(BonkPlayer a, BonkPlayer b) {
    const reach = headRadius * 2;
    var dx = b.x - a.x, dy = b.y - a.y;
    final d2 = dx * dx + dy * dy;
    if (d2 >= reach * reach) return;
    var d = math.sqrt(d2);
    if (d < 1e-9) {
      dx = 1;
      dy = 0;
      d = 1;
    }
    final nx = dx / d, ny = dy / d;
    final push = (reach - d) / 2;
    a.x -= nx * push;
    a.y -= ny * push;
    b.x += nx * push;
    b.y += ny * push;
    final rv = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
    if (rv < 0) {
      a.vx += rv * nx / 2;
      a.vy += rv * ny / 2;
      b.vx -= rv * nx / 2;
      b.vy -= rv * ny / 2;
    }
    // Landing on the other player's head counts as standing.
    if (ny > 0.6) {
      if (b.vy < 0) b.vy = 0;
      b.grounded = true;
    } else if (ny < -0.6) {
      if (a.vy < 0) a.vy = 0;
      a.grounded = true;
    }
    for (final p in [a, b]) {
      if (p.y < standY) p.y = standY;
      p.x = p.x.clamp(headRadius, width - headRadius);
    }
  }

  // ------------------------------------------------------------------ ball
  void _moveBall() {
    const dt = stepDt;
    const r = ballRadius;
    ballVy -= ballGravity * dt;
    ballVx *= _dragPerStep;
    ballVy *= _dragPerStep;
    ballX += ballVx * dt;
    ballY += ballVy * dt;
    if (ballY < r) {
      ballY = r;
      if (ballVy < -1.0) {
        if (ballVy < -3) bounces++;
        ballVy = -ballVy * groundRestitution;
      } else {
        ballVy = 0;
      }
      ballVx *= _rollPerStep;
    } else if (ballY > height - r) {
      ballY = height - r;
      if (ballVy > 0) ballVy = -ballVy * wallRestitution;
    }
    if (ballX < r) {
      ballX = r;
      if (ballVx < 0) ballVx = -ballVx * wallRestitution;
    } else if (ballX > width - r) {
      ballX = width - r;
      if (ballVx > 0) ballVx = -ballVx * wallRestitution;
    }
    for (var side = 0; side < 2; side++) {
      final c = _segmentContact(ballX, ballY, r + crossbarThickness / 2, side);
      if (c == null) continue;
      ballX += c.nx * c.depth;
      ballY += c.ny * c.depth;
      final vn = ballVx * c.nx + ballVy * c.ny;
      if (vn < 0) {
        ballVx -= (1 + crossbarRestitution) * vn * c.nx;
        ballVy -= (1 + crossbarRestitution) * vn * c.ny;
        if (vn < -2) crossbarHits++;
      }
    }
  }

  void _collideHead(BonkPlayer p) {
    const reach = headRadius + ballRadius;
    var dx = ballX - p.x, dy = ballY - p.y;
    final d2 = dx * dx + dy * dy;
    if (d2 >= reach * reach) return;
    var d = math.sqrt(d2);
    if (d < 1e-9) {
      dx = 0;
      dy = 1;
      d = 1;
    }
    final nx = dx / d, ny = dy / d;
    ballX = p.x + nx * reach;
    ballY = p.y + ny * reach;
    if (ballY < ballRadius) ballY = ballRadius;
    final rvx = ballVx - p.vx, rvy = ballVy - p.vy;
    final vn = rvx * nx + rvy * ny;
    lastTouch = p.index;
    if (vn < 0) {
      ballVx -= (1 + headRestitution) * vn * nx;
      ballVy -= (1 + headRestitution) * vn * ny;
      // A head moving into the ball adds a little extra pop.
      final drive = p.vx * nx + p.vy * ny;
      if (drive > 0.5) {
        ballVx += nx * headerBoost;
        ballVy += ny * headerBoost;
      }
      if (vn < -1.5) headHits++;
    }
  }

  void _collideBody(BonkPlayer p) {
    const r = ballRadius;
    final left = p.x - bodyWidth / 2, right = p.x + bodyWidth / 2;
    final bottom = p.footY, top = p.footY + bodyHeight;
    final cx = ballX.clamp(left, right), cy = ballY.clamp(bottom, top);
    var dx = ballX - cx, dy = ballY - cy;
    final d2 = dx * dx + dy * dy;
    if (d2 >= r * r) return;
    double nx, ny, depth;
    if (d2 < 1e-12) {
      // Centre inside the box: push out sideways, away from the player.
      nx = ballX >= p.x ? 1 : -1;
      ny = 0;
      depth = (nx > 0 ? right - ballX : ballX - left) + r;
    } else {
      final d = math.sqrt(d2);
      nx = dx / d;
      ny = dy / d;
      depth = r - d;
    }
    ballX += nx * depth;
    ballY += ny * depth;
    if (ballY < r) ballY = r;
    lastTouch = p.index;
    final rvx = ballVx - p.vx, rvy = ballVy - p.vy;
    final vn = rvx * nx + rvy * ny;
    if (vn < 0) {
      ballVx -= (1 + bodyRestitution) * vn * nx;
      ballVy -= (1 + bodyRestitution) * vn * ny;
    }
  }

  void _tryKick(BonkPlayer p) {
    if (p.kickTimer <= 0 || p.kickLanded) return;
    final dx = ballX - p.bootX, dy = ballY - p.bootY;
    const reach = bootRadius + ballRadius;
    if (dx * dx + dy * dy >= reach * reach) return;
    p.kickLanded = true;
    kickHits++;
    lastTouch = p.index;
    ballVx = p.facing * kickVx + p.vx * 0.4;
    ballVy = kickVy + math.max(0.0, p.vy) * 0.3;
  }

  void _capBallSpeed() {
    final s2 = ballVx * ballVx + ballVy * ballVy;
    if (s2 > ballMaxSpeed * ballMaxSpeed) {
      final k = ballMaxSpeed / math.sqrt(s2);
      ballVx *= k;
      ballVy *= k;
    }
  }

  // ------------------------------------------------------------------ crossbars
  /// Crossbar of [side] (0 = left goal, 1 = right goal) as a segment from the
  /// back wall to the goal line.
  static (double, double, double, double) crossbar(int side) => side == 0
      ? (0.0, goalHeight + crossbarRise, goalDepth, goalHeight)
      : (width, goalHeight + crossbarRise, width - goalDepth, goalHeight);

  static _Contact? _segmentContact(double px, double py, double radius, int side) {
    final (ax, ay, bx, by) = crossbar(side);
    final sx = bx - ax, sy = by - ay;
    final t = (((px - ax) * sx + (py - ay) * sy) / (sx * sx + sy * sy)).clamp(0.0, 1.0);
    final cx = ax + sx * t, cy = ay + sy * t;
    var dx = px - cx, dy = py - cy;
    final d2 = dx * dx + dy * dy;
    if (d2 >= radius * radius) return null;
    var d = math.sqrt(d2);
    if (d < 1e-9) {
      dx = 0;
      dy = -1;
      d = 1;
    }
    return _Contact(dx / d, dy / d, radius - d);
  }

  // ------------------------------------------------------------------ goals
  /// Player who just scored, if the ball is wholly over a goal line under the bar.
  int? _goalScorer() {
    if (ballY >= goalHeight) return null;
    if (ballX < goalDepth - ballRadius) return 1;
    if (ballX > width - goalDepth + ballRadius) return 0;
    return null;
  }

  void _goal(int scorer) {
    scores[scorer]++;
    goals++;
    lastScorer = scorer;
    lastWasOwnGoal = lastTouch == 1 - scorer;
    if (goldenGoalActive || scores[scorer] >= winScore) {
      winner = scorer;
      return;
    }
    goalPause = goalPauseTicks;
    _nextKickoffSide = 1 - scorer;
  }

  void _fullTime() {
    remainingTicks = 0;
    if (scores[0] != scores[1]) {
      winner = scores[0] > scores[1] ? 0 : 1;
    } else if (goldenGoal) {
      goldenGoalActive = true;
    } else {
      isDraw = true;
    }
  }

  /// Resets everyone and drops the ball at the centre, drifting towards [side].
  void _kickoff(int side, int ticks) {
    for (final p in players) {
      p.reset();
    }
    ballX = width / 2;
    ballY = kickoffBallY;
    ballVx = 0;
    ballVy = 0;
    lastTouch = -1;
    kickoffTimer = ticks;
    _kickoffNudge = side == 0 ? -1.2 : 1.2;
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
    mix(remainingTicks);
    mix(kickoffTimer);
    mix(goalPause);
    mix(winner ?? -1);
    mix(isDraw ? 1 : 0);
    mix(r(ballX));
    mix(r(ballY));
    mix(r(ballVx));
    mix(r(ballVy));
    for (final p in players) {
      mix(r(p.x));
      mix(r(p.y));
      mix(r(p.vx));
      mix(r(p.vy));
      mix(p.kickTimer);
    }
    return h;
  }

  // ------------------------------------------------------------------ debug
  /// Test helper: places the ball and ends any kickoff freeze or goal pause.
  void debugPlaceBall(double x, double y, [double vx = 0, double vy = 0]) {
    ballX = x;
    ballY = y;
    ballVx = vx;
    ballVy = vy;
    kickoffTimer = 0;
    goalPause = 0;
  }

  /// Test helper: teleports a player.
  void debugPlacePlayer(int player, double x, double y, [double vx = 0, double vy = 0]) {
    final p = players[player];
    p
      ..x = x
      ..y = y
      ..vx = vx
      ..vy = vy
      ..grounded = y <= standY;
  }

  /// Test helper: ends the kickoff freeze immediately.
  void debugSkipKickoff() {
    if (kickoffTimer > 0) {
      kickoffTimer = 0;
      ballVx = _kickoffNudge;
    }
  }

  double get ballSpeed => math.sqrt(ballVx * ballVx + ballVy * ballVy);
}

class _Contact {
  const _Contact(this.nx, this.ny, this.depth);
  final double nx, ny, depth;
}

enum CpuLevel { easy, normal, hard }

/// Tuning for one CPU difficulty.
class CpuProfile {
  const CpuProfile({
    required this.reactionTicks,
    required this.speed,
    required this.lookahead,
    required this.jumpSkill,
    required this.kickSkill,
    required this.deadzone,
  });

  /// Ticks between re-plans (stale view of the ball in between).
  final int reactionTicks;

  /// Fraction of full running speed the CPU uses.
  final double speed;

  /// Seconds ahead it predicts the ball.
  final double lookahead;

  /// Chance per plan that it jumps for a high ball.
  final double jumpSkill;

  /// Chance per plan that it swings at a ball in boot range.
  final double kickSkill;

  /// How close (units) to its target spot is close enough.
  final double deadzone;

  static const easy = CpuProfile(
    reactionTicks: 26,
    speed: 0.55,
    lookahead: 0,
    jumpSkill: 0.3,
    kickSkill: 0.35,
    deadzone: 0.7,
  );
  static const normal = CpuProfile(
    reactionTicks: 16,
    speed: 0.75,
    lookahead: 0.15,
    jumpSkill: 0.6,
    kickSkill: 0.7,
    deadzone: 0.4,
  );
  static const hard = CpuProfile(
    reactionTicks: 12,
    speed: 1.0,
    lookahead: 0.35,
    jumpSkill: 0.9,
    kickSkill: 0.95,
    deadzone: 0.15,
  );

  static CpuProfile of(CpuLevel level) => switch (level) {
    CpuLevel.easy => easy,
    CpuLevel.normal => normal,
    CpuLevel.hard => hard,
  };
}

/// Computer opponent. Reads the world and returns a [BonkInput] that is fed
/// through [BonkWorld.setInput], exactly like a human or remote player.
///
/// It reasons in canonical coordinates (own goal at x = 0) and mirrors back.
class AiController {
  AiController({required this.player, this.level = CpuLevel.normal, int seed = 0, CpuProfile? profile})
    : profile = profile ?? CpuProfile.of(level),
      _rng = math.Random(seed * 7919 + player * 31 + level.index);

  final int player;
  final CpuLevel level;
  final CpuProfile profile;
  final math.Random _rng;

  int _cooldown = 0;
  bool _planned = false;
  double _targetX = BonkWorld.width * 0.25;
  bool _jumpWanted = false;
  bool _kickArmed = false;
  int _stall = 0;

  double _c(double x) => player == 0 ? x : BonkWorld.width - x;

  BonkInput think(BonkWorld w) {
    if (w.kickoffTimer > 0) {
      _planned = false;
      return BonkInput.none;
    }
    if (!_planned || _cooldown <= 0) {
      _plan(w);
      _planned = true;
      _cooldown = profile.reactionTicks;
    } else {
      _cooldown--;
    }
    final me = w.players[player];
    final mx = _c(me.x);
    final dx = _targetX - mx;
    var move = 0.0;
    if (dx.abs() > profile.deadzone) {
      move = dx.sign * profile.speed;
    } else if (dx.abs() > 0.08) {
      move = dx / profile.deadzone * profile.speed;
    }
    final bx = _c(w.ballX);
    final rel = bx - mx;
    // Never shove a low ball back towards our own goal: wait until the jump
    // carries our feet over it.
    if (move < 0 && rel < 0 && rel > -1.7 && me.footY < w.ballY + BonkWorld.ballRadius) move = 0;
    var kick = false;
    if (_kickArmed && rel > 0 && rel < 1.8 && w.ballY < me.footY + 1.6) {
      // Only shoot when the opponent is not standing right in the way.
      final ox = _c(w.players[1 - player].x);
      kick = ox < bx || ox - bx > 2.4 || bx > BonkWorld.width - 3.2 || _stall > 50;
    }
    // A dead ball wedged between the players: break the deadlock.
    _stall = w.ballSpeed < 2.5 && rel.abs() < 2.6 ? _stall + 1 : 0;
    final jump = (_jumpWanted || _stall > 90) && me.grounded;
    return BonkInput(move: player == 0 ? move : -move, jump: jump, kick: kick);
  }

  void _plan(BonkWorld w) {
    const wd = BonkWorld.width;
    const behind = BonkWorld.headRadius + BonkWorld.ballRadius + 0.1;
    final me = w.players[player];
    final mx = _c(me.x);
    final la = profile.lookahead;
    final bvx = player == 0 ? w.ballVx : -w.ballVx;
    var px = _c(w.ballX) + bvx * la;
    // Fold the prediction off the end walls.
    const lo = BonkWorld.ballRadius, hi = wd - BonkWorld.ballRadius;
    if (px < lo) px = 2 * lo - px;
    if (px > hi) px = 2 * hi - px;
    px = px.clamp(lo, hi);
    final py = math.max(BonkWorld.ballRadius, w.ballY + w.ballVy * la - 0.5 * BonkWorld.ballGravity * la * la);

    double target;
    var jump = false;
    if (px < mx - 0.2) {
      // The ball is between us and our goal: get back to its goal side.
      // Running into a low ball would push it towards our own goal, so hop
      // over it; if we cannot, hang back on its far side instead.
      final hop = mx - px < 2.4 && py < 2.4;
      if (hop && _rng.nextDouble() < profile.jumpSkill) {
        jump = true;
        target = px - behind;
      } else if (hop && mx - px < 1.5) {
        target = px + behind + 0.3;
      } else {
        target = px - behind;
      }
    } else if (px > wd * 0.62 &&
        bvx > -3 &&
        w.ballSpeed > 2 &&
        (_c(w.players[1 - player].x) - px).abs() < px - mx) {
      // Live ball deep in their half, they are closer, and it is not coming
      // back fast: hold midfield.
      target = math.min(px - 2.5, wd * 0.5);
    } else {
      target = px - behind * 0.85;
      jump = py > 2.3 && py < 6 && (px - mx).abs() < 1.7 && _rng.nextDouble() < profile.jumpSkill;
    }
    _jumpWanted = jump;
    _kickArmed = _rng.nextDouble() < profile.kickSkill;
    _targetX = target.clamp(BonkWorld.headRadius + 0.1, wd - BonkWorld.headRadius - 0.1);
  }
}
