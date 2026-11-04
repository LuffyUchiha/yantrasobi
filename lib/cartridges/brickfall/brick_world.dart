import 'dart:math' as math;

import 'levels.dart';

/// Pure-Dart rules for Brickfall, a paddle-and-ball brick breaker.
///
/// World space is [width] x [height] units, +y down. The brick grid has
/// [kBrickCols] columns of [brickW] x [brickH] cells starting at [gridTop].
/// Simulation runs on a fixed [tick]; each ball is additionally sub-stepped so
/// it never moves more than half its radius per sub-step, which (with bricks
/// and the paddle much thicker than that) rules out tunnelling.

enum BrickKind { normal, tough, steel, explosive }

enum PowerKind { wide, multi, slow, laser, life }

enum BrickPhase { playing, won, lost }

enum BrickEventKind { hit, broke, steel, paddle, wall, launch, capsule, laser, lifeLost, won, lost }

class Brick {
  Brick(this.col, this.row, this.kind, this.maxHp, {this.capsule}) : hp = maxHp;

  final int col, row;
  final BrickKind kind;
  final int maxHp;
  final PowerKind? capsule;
  int hp;
  bool alive = true;

  /// Seconds of hit flash left (for the renderer).
  double flash = 0;

  bool get destructible => kind != BrickKind.steel;
  double get left => col * BrickWorld.brickW;
  double get right => left + BrickWorld.brickW;
  double get top => BrickWorld.gridTop + row * BrickWorld.brickH;
  double get bottom => top + BrickWorld.brickH;
  double get cx => left + BrickWorld.brickW / 2;
  double get cy => top + BrickWorld.brickH / 2;
}

class Ball {
  Ball(this.x, this.y, this.vx, this.vy);
  double x, y, vx, vy;
  bool held = false;
  bool lost = false;

  /// Seconds since this ball last touched the paddle or a breakable brick.
  double idle = 0;
}

class Capsule {
  Capsule(this.kind, this.x, this.y);
  final PowerKind kind;
  double x, y;
  bool alive = true;
}

class Bolt {
  Bolt(this.x, this.y);
  double x, y;
  bool alive = true;
}

class BrickEvent {
  const BrickEvent(this.kind, this.x, this.y, {this.brick, this.power, this.points = 0});
  final BrickEventKind kind;
  final double x, y;
  final BrickKind? brick;
  final PowerKind? power;
  final int points;
}

class BrickWorld {
  /// Builds level [level] (authored for 1..10, generated after that).
  BrickWorld({required int seed, this.level = 1}) : _rng = math.Random(seed) {
    _load(layoutForLevel(level));
  }

  /// Builds a world from an explicit layout (tests, tools).
  BrickWorld.custom(List<String> rows, {int seed = 1, this.level = 1}) : _rng = math.Random(seed) {
    _load(rows);
  }

  // ---------------------------------------------------------------- constants
  static const double width = 360;
  static const double height = 600;
  static const double brickW = width / kBrickCols;
  static const double brickH = 18;
  static const double gridTop = 56;
  static const double ballRadius = 6;
  static const double paddleY = 548;
  static const double paddleH = 12;
  static const double paddleHalf = 36;
  static const double widePaddleHalf = 58;
  static const double paddleMaxSpeed = 2400;
  static const double tick = 1 / 120;
  static const double maxSpeed = 560;
  static const double speedPerHit = 4;
  static const double slowFactor = 0.6;
  static const double maxBounceAngle = 62 * math.pi / 180;
  static const double minVerticalRatio = 0.26;
  static const double wideDuration = 15;
  static const double slowDuration = 10;
  static const double laserDuration = 8;
  static const double laserCooldown = 0.22;
  static const double boltSpeed = 720;
  static const double capsuleSpeed = 140;
  static const double capsuleHalfW = 15;
  static const double capsuleHalfH = 7;
  static const int startLives = 3;
  static const int maxLives = 9;
  static const int maxBalls = 12;
  static const int maxMultiplier = 5;
  static const int lifeBonus = 250;
  static const double randomDropChance = 0.12;

  static int pointsFor(Brick b) => switch (b.kind) {
    BrickKind.normal => 10,
    BrickKind.tough => b.maxHp >= 3 ? 40 : 25,
    BrickKind.explosive => 20,
    BrickKind.steel => 0,
  };

  // ---------------------------------------------------------------- state
  final int level;
  final math.Random _rng;
  final List<Brick> bricks = [];
  late final List<Brick?> _grid;
  int rows = 0;
  final List<Ball> balls = [];
  final List<Capsule> capsules = [];
  final List<Bolt> bolts = [];
  final List<BrickEvent> events = [];

  BrickPhase phase = BrickPhase.playing;
  int lives = startLives;
  int score = 0;
  int combo = 0;
  int bestCombo = 0;
  int bricksBroken = 0;
  int paddleHits = 0;
  int speedHits = 0;
  int destructibleLeft = 0;
  int powersCaught = 0;
  int earnedLifeBonus = 0;
  double time = 0;
  double paddleX = width / 2;
  double _paddleTarget = width / 2;
  double wideTime = 0, slowTime = 0, laserTime = 0;
  double _laserCooldown = 0;
  double _acc = 0;

  bool get isOver => phase != BrickPhase.playing;
  bool get won => phase == BrickPhase.won;
  int get entityCount => destructibleLeft + balls.length + capsules.length + bolts.length;
  double get paddleHalfWidth => wideTime > 0 ? widePaddleHalf : paddleHalf;
  bool get hasHeldBall => balls.any((b) => b.held);
  bool get laserActive => laserTime > 0;
  int get multiplier => math.min(maxMultiplier, math.max(1, combo));
  double get baseSpeed => 290 + 6.0 * math.min(level - 1, 20);
  double get currentSpeed =>
      math.min(maxSpeed, baseSpeed + speedPerHit * speedHits) * (slowTime > 0 ? slowFactor : 1);

  Brick? brickAt(int col, int row) =>
      (col < 0 || col >= kBrickCols || row < 0 || row >= rows) ? null : _grid[row * kBrickCols + col];

  // ---------------------------------------------------------------- levels
  static List<String> layoutForLevel(int level) {
    final l = math.max(1, level);
    if (l <= kAuthoredLevels.length) return kAuthoredLevels[l - 1].rows;
    return generateLayout(l);
  }

  static String levelName(int level) {
    final l = math.max(1, level);
    if (l <= kAuthoredLevels.length) return kAuthoredLevels[l - 1].name;
    return 'Deep ${l - kAuthoredLevels.length}';
  }

  /// Deterministic mirrored layout for levels past the authored set. Steel is
  /// never placed next to (or diagonal to) other steel, so no breakable brick
  /// can be sealed off.
  static List<String> generateLayout(int level) {
    final rng = math.Random(level * 7919 + 17);
    final depth = level - kAuthoredLevels.length;
    final rowCount = (7 + depth ~/ 2).clamp(7, 12);
    final toughP = math.min(0.55, 0.22 + 0.03 * depth);
    final hp3P = math.min(0.6, 0.2 + 0.04 * depth);
    final steelP = math.min(0.14, 0.05 + 0.01 * depth);
    const explosiveP = 0.06;
    const capsuleP = 0.07;
    final motif = rng.nextInt(4);
    final cells = List.generate(rowCount, (_) => List.filled(kBrickCols, '.'));
    bool steelNear(int r, int c) {
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          final rr = r + dr, cc = c + dc;
          if (rr < 0 || rr >= rowCount || cc < 0 || cc >= kBrickCols) continue;
          if (cells[rr][cc] == '#') return true;
        }
      }
      return false;
    }

    const capsuleCodes = ['W', 'M', 'S', 'L', 'W', 'M', 'S', 'H'];
    for (var r = 0; r < rowCount; r++) {
      for (var c = 0; c < kBrickCols ~/ 2; c++) {
        final filled = switch (motif) {
          0 => (r + c).isEven || r % 3 == 0, // lattice
          1 => (c - 2).abs() + (r - rowCount ~/ 2).abs() <= 4 + r % 2, // diamond
          2 => r % 4 != 3, // bands
          _ => rng.nextDouble() < 0.78, // scatter
        };
        if (!filled) continue;
        String code;
        final roll = rng.nextDouble();
        if (c < 4 && r > 0 && roll < steelP) {
          code = '#';
        } else if (roll < steelP + explosiveP) {
          code = '*';
        } else if (roll < steelP + explosiveP + toughP) {
          code = rng.nextDouble() < hp3P ? '3' : '2';
        } else if (rng.nextDouble() < capsuleP) {
          code = capsuleCodes[rng.nextInt(capsuleCodes.length)];
        } else {
          code = '1';
        }
        if (code == '#' && (steelNear(r, c) || steelNear(r, kBrickCols - 1 - c))) code = '2';
        cells[r][c] = code;
        cells[r][kBrickCols - 1 - c] = code;
      }
    }
    // Guarantee enough bricks: fill empty cells bottom-up with normal bricks.
    var destructible = 0;
    for (final row in cells) {
      for (final ch in row) {
        if (ch != '.' && ch != '#') destructible++;
      }
    }
    for (var r = rowCount - 1; r >= 0 && destructible < 24; r--) {
      for (var c = 0; c < kBrickCols; c++) {
        if (cells[r][c] == '.') {
          cells[r][c] = '1';
          destructible++;
        }
      }
    }
    return [for (final row in cells) row.join()];
  }

  void _load(List<String> layout) {
    rows = math.min(layout.length, kBrickMaxRows);
    _grid = List<Brick?>.filled(kBrickCols * math.max(1, rows), null);
    for (var r = 0; r < rows; r++) {
      final line = layout[r];
      for (var c = 0; c < kBrickCols && c < line.length; c++) {
        final b = _parse(line[c], c, r);
        if (b == null) continue;
        bricks.add(b);
        _grid[r * kBrickCols + c] = b;
        if (b.destructible) destructibleLeft++;
      }
    }
    _spawnHeldBall();
    if (destructibleLeft == 0) phase = BrickPhase.won;
  }

  static Brick? _parse(String ch, int c, int r) => switch (ch) {
    '1' => Brick(c, r, BrickKind.normal, 1),
    '2' => Brick(c, r, BrickKind.tough, 2),
    '3' => Brick(c, r, BrickKind.tough, 3),
    '#' => Brick(c, r, BrickKind.steel, 1),
    '*' => Brick(c, r, BrickKind.explosive, 1),
    'W' => Brick(c, r, BrickKind.normal, 1, capsule: PowerKind.wide),
    'M' => Brick(c, r, BrickKind.normal, 1, capsule: PowerKind.multi),
    'S' => Brick(c, r, BrickKind.normal, 1, capsule: PowerKind.slow),
    'L' => Brick(c, r, BrickKind.normal, 1, capsule: PowerKind.laser),
    'H' => Brick(c, r, BrickKind.normal, 1, capsule: PowerKind.life),
    _ => null,
  };

  void _spawnHeldBall() {
    balls.add(Ball(paddleX, paddleY - ballRadius, 0, 0)..held = true);
  }

  // ---------------------------------------------------------------- input
  /// The paddle glides toward [x] (clamped to the field) every tick.
  void setPaddleTarget(double x) => _paddleTarget = x;

  /// Releases every ball resting on the paddle. Returns true if one launched.
  bool launch() {
    if (isOver) return false;
    var any = false;
    for (final b in balls) {
      if (!b.held) continue;
      final a = (_rng.nextDouble() * 2 - 1) * 0.3;
      final s = currentSpeed;
      b
        ..held = false
        ..vx = s * math.sin(a)
        ..vy = -s * math.cos(a)
        ..idle = 0;
      any = true;
    }
    if (any) events.add(BrickEvent(BrickEventKind.launch, paddleX, paddleY));
    return any;
  }

  /// Fires a pair of laser bolts while the laser power is active.
  bool fire() {
    if (isOver || laserTime <= 0 || _laserCooldown > 0) return false;
    final hw = paddleHalfWidth - 6;
    bolts
      ..add(Bolt(paddleX - hw, paddleY - 4))
      ..add(Bolt(paddleX + hw, paddleY - 4));
    _laserCooldown = laserCooldown;
    events.add(BrickEvent(BrickEventKind.laser, paddleX, paddleY));
    return true;
  }

  // ---------------------------------------------------------------- simulation
  void update(double dt) {
    events.clear();
    if (dt <= 0) return;
    _acc += math.min(dt, 0.1);
    while (_acc >= tick) {
      _acc -= tick;
      _step(tick);
    }
  }

  void _step(double h) {
    for (final b in bricks) {
      if (b.flash > 0) b.flash = math.max(0, b.flash - h);
    }
    if (isOver) return;
    time += h;
    if (wideTime > 0) wideTime = math.max(0, wideTime - h);
    if (slowTime > 0) slowTime = math.max(0, slowTime - h);
    if (laserTime > 0) laserTime = math.max(0, laserTime - h);
    if (_laserCooldown > 0) _laserCooldown -= h;

    // Paddle.
    final hw = paddleHalfWidth;
    final target = _paddleTarget.clamp(hw, width - hw);
    final maxMove = paddleMaxSpeed * h;
    paddleX += (target - paddleX).clamp(-maxMove, maxMove);
    paddleX = paddleX.clamp(hw, width - hw);

    // Balls.
    final speed = currentSpeed;
    for (final b in balls) {
      if (b.held) {
        b
          ..x = paddleX
          ..y = paddleY - ballRadius;
        continue;
      }
      b.idle += h;
      _setSpeed(b, speed);
      final n = math.max(1, (speed * h / (ballRadius * 0.5)).ceil());
      final sub = h / n;
      for (var i = 0; i < n && !b.lost && !isOver; i++) {
        _moveBall(b, sub);
      }
    }
    balls.removeWhere((b) => b.lost);

    _stepBolts(h);
    _stepCapsules(h);

    if (destructibleLeft <= 0 && phase == BrickPhase.playing) {
      phase = BrickPhase.won;
      earnedLifeBonus = lives * lifeBonus;
      score += earnedLifeBonus;
      events.add(const BrickEvent(BrickEventKind.won, width / 2, height / 2));
      return;
    }
    if (balls.isEmpty && phase == BrickPhase.playing) _loseLife();
  }

  void _setSpeed(Ball b, double s) {
    final cur = math.sqrt(b.vx * b.vx + b.vy * b.vy);
    if (cur < 1e-6) {
      b
        ..vx = 0
        ..vy = -s;
      return;
    }
    final k = s / cur;
    b
      ..vx *= k
      ..vy *= k;
  }

  /// Keeps the ball from settling into near-horizontal paths.
  void _fixAngle(Ball b) {
    final s = math.sqrt(b.vx * b.vx + b.vy * b.vy);
    final minVy = s * minVerticalRatio;
    if (b.vy.abs() >= minVy) return;
    final vy = b.vy < 0 ? -minVy : minVy;
    final vx = math.sqrt(math.max(0, s * s - vy * vy));
    b
      ..vy = vy
      ..vx = b.vx < 0 ? -vx : vx;
  }

  /// Breaks long loops among steel and walls by nudging the angle.
  void _maybeNudge(Ball b) {
    if (b.idle < 8) return;
    const a = 0.17;
    final c = math.cos(a), s = math.sin(a);
    final vx = b.vx * c - b.vy * s;
    final vy = b.vx * s + b.vy * c;
    b
      ..vx = vx
      ..vy = vy
      ..idle = 6;
    _fixAngle(b);
  }

  void _moveBall(Ball b, double s) {
    const r = ballRadius;
    b
      ..x += b.vx * s
      ..y += b.vy * s;

    // Walls.
    var wall = false;
    if (b.x < r) {
      b.x = r;
      if (b.vx < 0) b.vx = -b.vx;
      wall = true;
    } else if (b.x > width - r) {
      b.x = width - r;
      if (b.vx > 0) b.vx = -b.vx;
      wall = true;
    }
    if (b.y < r) {
      b.y = r;
      if (b.vy < 0) b.vy = -b.vy;
      wall = true;
    }
    if (wall) {
      _fixAngle(b);
      _maybeNudge(b);
      events.add(BrickEvent(BrickEventKind.wall, b.x, b.y));
    }

    // Bricks: resolve the deepest overlap first, up to three contacts.
    for (var pass = 0; pass < 3; pass++) {
      Brick? best;
      var bestPen = 0.0, bnx = 0.0, bny = 0.0;
      final c0 = math.max(0, ((b.x - r) / brickW).floor());
      final c1 = math.min(kBrickCols - 1, ((b.x + r) / brickW).floor());
      final r0 = math.max(0, ((b.y - r - gridTop) / brickH).floor());
      final r1 = math.min(rows - 1, ((b.y + r - gridTop) / brickH).floor());
      for (var row = r0; row <= r1; row++) {
        for (var col = c0; col <= c1; col++) {
          final k = _grid[row * kBrickCols + col];
          if (k == null || !k.alive) continue;
          final hit = _circleBox(b.x, b.y, r, k.left, k.top, k.right, k.bottom);
          if (hit && _pen > bestPen) {
            best = k;
            bestPen = _pen;
            bnx = _nx;
            bny = _ny;
          }
        }
      }
      if (best == null) break;
      b
        ..x += bnx * bestPen
        ..y += bny * bestPen;
      final dot = b.vx * bnx + b.vy * bny;
      if (dot < 0) {
        b
          ..vx -= 2 * dot * bnx
          ..vy -= 2 * dot * bny;
        _fixAngle(b);
        _hitBrick(best, b);
        if (isOver) return;
      }
    }

    // Paddle.
    final hw = paddleHalfWidth;
    final pl = paddleX - hw, pr = paddleX + hw;
    if (_circleBox(b.x, b.y, r, pl, paddleY, pr, paddleY + paddleH)) {
      if (b.vy > 0 && _ny < -0.3 && b.y < paddleY + paddleH * 0.5) {
        final t = ((b.x - paddleX) / (hw + r * 0.5)).clamp(-1.0, 1.0);
        final a = t * maxBounceAngle;
        final sp = math.sqrt(b.vx * b.vx + b.vy * b.vy);
        b
          ..vx = sp * math.sin(a)
          ..vy = -sp * math.cos(a)
          ..y = paddleY - r
          ..idle = 0;
        combo = 0;
        paddleHits++;
        events.add(BrickEvent(BrickEventKind.paddle, b.x, paddleY));
      } else {
        b
          ..x += _nx * _pen
          ..y += _ny * _pen;
        final dot = b.vx * _nx + b.vy * _ny;
        if (dot < 0) {
          b
            ..vx -= 2 * dot * _nx
            ..vy -= 2 * dot * _ny;
        }
      }
    }

    if (b.y - r > height) b.lost = true;
  }

  double _nx = 0, _ny = 0, _pen = 0;

  /// Circle vs axis-aligned box. On overlap stores the push-out normal in
  /// [_nx]/[_ny] and the penetration depth in [_pen].
  bool _circleBox(double x, double y, double r, double l, double t, double rt, double bt) {
    final cx = x.clamp(l, rt);
    final cy = y.clamp(t, bt);
    final dx = x - cx, dy = y - cy;
    final d2 = dx * dx + dy * dy;
    if (d2 >= r * r) return false;
    if (d2 > 1e-12) {
      final d = math.sqrt(d2);
      _nx = dx / d;
      _ny = dy / d;
      _pen = r - d;
      return true;
    }
    // Centre inside the box: push out along the shallowest axis.
    final dl = x - l, dr = rt - x, dt = y - t, db = bt - y;
    var m = dl;
    _nx = -1;
    _ny = 0;
    if (dr < m) {
      m = dr;
      _nx = 1;
      _ny = 0;
    }
    if (dt < m) {
      m = dt;
      _nx = 0;
      _ny = -1;
    }
    if (db < m) {
      m = db;
      _nx = 0;
      _ny = 1;
    }
    _pen = m + r;
    return true;
  }

  void _hitBrick(Brick k, Ball? ball) {
    k.flash = 0.12;
    if (!k.destructible) {
      events.add(BrickEvent(BrickEventKind.steel, k.cx, k.cy, brick: k.kind));
      if (ball != null) _maybeNudge(ball);
      return;
    }
    ball?.idle = 0;
    speedHits++;
    k.hp--;
    if (k.hp > 0) {
      score += 5;
      events.add(BrickEvent(BrickEventKind.hit, k.cx, k.cy, brick: k.kind, points: 5));
      return;
    }
    _destroy(k);
  }

  void _destroy(Brick k) {
    if (!k.alive || !k.destructible) return;
    k
      ..alive = false
      ..hp = 0;
    destructibleLeft--;
    bricksBroken++;
    combo++;
    if (combo > bestCombo) bestCombo = combo;
    final pts = pointsFor(k) * multiplier;
    score += pts;
    events.add(BrickEvent(BrickEventKind.broke, k.cx, k.cy, brick: k.kind, points: pts));
    final drop = k.capsule ?? (_rng.nextDouble() < randomDropChance ? _randomPower() : null);
    if (drop != null && capsules.length < 4) capsules.add(Capsule(drop, k.cx, k.cy));
    if (k.kind == BrickKind.explosive) {
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          final n = brickAt(k.col + dc, k.row + dr);
          if (n != null && n.alive) _destroy(n);
        }
      }
    }
  }

  PowerKind _randomPower() {
    final roll = _rng.nextInt(11);
    if (roll < 3) return PowerKind.wide;
    if (roll < 6) return PowerKind.multi;
    if (roll < 8) return PowerKind.slow;
    if (roll < 10) return PowerKind.laser;
    return PowerKind.life;
  }

  void _stepBolts(double h) {
    for (final t in bolts) {
      t.y -= boltSpeed * h;
      if (t.y < 0) {
        t.alive = false;
        continue;
      }
      final row = ((t.y - gridTop) / brickH).floor();
      final col = (t.x / brickW).floor();
      final k = brickAt(col, row);
      if (k != null && k.alive) {
        t.alive = false;
        _hitBrick(k, null);
      }
    }
    bolts.removeWhere((t) => !t.alive);
  }

  void _stepCapsules(double h) {
    final hw = paddleHalfWidth;
    for (final c in capsules) {
      c.y += capsuleSpeed * h;
      if (c.x + capsuleHalfW >= paddleX - hw &&
          c.x - capsuleHalfW <= paddleX + hw &&
          c.y + capsuleHalfH >= paddleY &&
          c.y - capsuleHalfH <= paddleY + paddleH) {
        c.alive = false;
        powersCaught++;
        applyPower(c.kind);
        events.add(BrickEvent(BrickEventKind.capsule, c.x, paddleY, power: c.kind));
      } else if (c.y - capsuleHalfH > height) {
        c.alive = false;
      }
    }
    capsules.removeWhere((c) => !c.alive);
  }

  /// Applies a power-up immediately (also used by tests).
  void applyPower(PowerKind kind) {
    switch (kind) {
      case PowerKind.wide:
        wideTime = wideDuration;
      case PowerKind.slow:
        slowTime = slowDuration;
      case PowerKind.laser:
        laserTime = laserDuration;
      case PowerKind.life:
        lives = math.min(maxLives, lives + 1);
      case PowerKind.multi:
        if (balls.every((b) => b.held)) launch();
        Ball? src;
        for (final b in balls) {
          if (!b.held && !b.lost) {
            src = b;
            break;
          }
        }
        if (src == null) return;
        for (final a in const [-0.45, 0.45]) {
          if (balls.length >= maxBalls) break;
          final c = math.cos(a), s = math.sin(a);
          final nb = Ball(src.x, src.y, src.vx * c - src.vy * s, src.vx * s + src.vy * c);
          _fixAngle(nb);
          balls.add(nb);
        }
    }
  }

  void _loseLife() {
    lives--;
    events.add(BrickEvent(BrickEventKind.lifeLost, paddleX, paddleY));
    capsules.clear();
    bolts.clear();
    wideTime = 0;
    slowTime = 0;
    laserTime = 0;
    combo = 0;
    speedHits = 0;
    if (lives <= 0) {
      lives = 0;
      phase = BrickPhase.lost;
      events.add(BrickEvent(BrickEventKind.lost, paddleX, paddleY));
      return;
    }
    _spawnHeldBall();
  }

  // ---------------------------------------------------------------- helpers
  /// Replaces every ball with one free ball (tests).
  Ball debugPlaceBall(double x, double y, double vx, double vy) {
    balls.clear();
    final b = Ball(x, y, vx, vy);
    _setSpeed(b, currentSpeed);
    balls.add(b);
    return b;
  }

  /// Drops a capsule at a position (tests).
  void debugDropCapsule(PowerKind kind, double x, double y) => capsules.add(Capsule(kind, x, y));

  /// Moves the paddle instantly (tests).
  void debugSetPaddle(double x) {
    paddleX = x.clamp(paddleHalfWidth, width - paddleHalfWidth);
    _paddleTarget = paddleX;
  }

  /// Where the most urgent ball will cross the paddle line, folding wall
  /// bounces and ignoring bricks. Used by the demo bot and tests.
  double predictBallX() {
    Ball? pick;
    var bestT = double.infinity;
    for (final b in balls) {
      if (b.held || b.lost) continue;
      final t = b.vy > 0 ? (paddleY - ballRadius - b.y) / b.vy : 1e6 - b.y;
      if (t < bestT) {
        bestT = t;
        pick = b;
      }
    }
    if (pick == null) return paddleX;
    if (pick.vy <= 0) return pick.x;
    final x = pick.x + pick.vx * math.max(0, bestT);
    const lo = ballRadius;
    const span = width - 2 * ballRadius;
    var u = (x - lo) % (2 * span);
    if (u < 0) u += 2 * span;
    if (u > span) u = 2 * span - u;
    return lo + u;
  }
}
