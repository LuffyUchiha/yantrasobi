import 'dart:math' as math;

/// Pure-Dart rules for Quad Pong: up to four paddles, one per edge of a
/// square court. Multiplayer-ready: every paddle (human, CPU or a future
/// remote peer) is driven only through [setInput]; the world advances in fixed
/// steps and exposes [tick] and [stateHash] for lockstep sync.
///
/// Seats: 0 = bottom, 1 = top, 2 = left, 3 = right. Court spans 0..[size].

class PongInput {
  const PongInput(this.target);

  /// Desired paddle centre along its edge, 0..1.
  final double target;
}

class Paddle {
  Paddle(this.seat);
  final int seat;
  double pos = 0.5;
  double target = 0.5;
  int lives = 5;
  bool active = true;
  bool get out => lives <= 0;
}

class PongBall {
  double x = 0, y = 0, vx = 0, vy = 0;
}

class PongWorld {
  PongWorld({this.seats = 2, int seed = 1}) : _rng = math.Random(seed) {
    for (var i = 0; i < 4; i++) {
      paddles.add(Paddle(i)..active = i < seats);
    }
    _serve();
  }

  static const double size = 100;
  static const double paddleLen = 22;
  static const double paddleSpeed = 1.6; // fraction of edge per second
  static const double ballRadius = 1.6;
  static const double dt = 1 / 120;

  final int seats;
  final math.Random _rng;
  final List<Paddle> paddles = [];
  final PongBall ball = PongBall();
  int tick = 0;
  double _acc = 0;
  double _serveDelay = 1;
  int rally = 0;
  int? lastScoredAgainst;

  bool get isOver => paddles.where((p) => p.active && !p.out).length <= 1;
  int? get winner =>
      isOver ? paddles.firstWhere((p) => p.active && !p.out, orElse: () => paddles[0]).seat : null;
  int get entityCount => 1 + paddles.where((p) => p.active).length;
  double get ballSpeed => math.min(95, 45 + rally * 2.5);

  void setInput(int seat, PongInput input) => paddles[seat].target = input.target.clamp(0.0, 1.0);

  void _serve() {
    ball
      ..x = size / 2
      ..y = size / 2;
    final live = [
      for (final p in paddles)
        if (p.active && !p.out) p.seat,
    ];
    // Serve toward a random live seat, at a slight angle.
    final seat = live[_rng.nextInt(live.length)];
    final angle = (_rng.nextDouble() - 0.5) * 0.8;
    final (dx, dy) = switch (seat) {
      0 => (math.sin(angle), math.cos(angle)),
      1 => (math.sin(angle), -math.cos(angle)),
      2 => (-math.cos(angle), math.sin(angle)),
      _ => (math.cos(angle), math.sin(angle)),
    };
    rally = 0;
    ball
      ..vx = dx * ballSpeed
      ..vy = dy * ballSpeed;
    _serveDelay = 1;
  }

  void update(double frameDt) {
    _acc += math.min(frameDt, 0.25);
    while (_acc >= dt) {
      _acc -= dt;
      step();
    }
  }

  /// One fixed simulation step.
  void step() {
    if (isOver) return;
    tick++;
    for (final p in paddles) {
      if (!p.active || p.out) continue;
      final d = (p.target - p.pos).clamp(-paddleSpeed * dt, paddleSpeed * dt);
      p.pos = (p.pos + d).clamp(paddleLen / size / 2, 1 - paddleLen / size / 2);
    }
    if (_serveDelay > 0) {
      _serveDelay -= dt;
      return;
    }
    ball
      ..x += ball.vx * dt
      ..y += ball.vy * dt;
    _edge(0, ball.y >= size - ballRadius, ball.x, () => ball.vy = -ball.vy.abs());
    _edge(1, ball.y <= ballRadius, ball.x, () => ball.vy = ball.vy.abs());
    _edge(2, ball.x <= ballRadius, ball.y, () => ball.vx = ball.vx.abs());
    _edge(3, ball.x >= size - ballRadius, ball.y, () => ball.vx = -ball.vx.abs());
  }

  /// Handles the ball reaching edge [seat]: paddle hit, wall bounce or a point lost.
  void _edge(int seat, bool reached, double along, void Function() reflect) {
    if (!reached) return;
    final p = paddles[seat];
    if (!p.active || p.out) {
      // Empty seats are solid walls.
      reflect();
      _clampBall();
      return;
    }
    final centre = p.pos * size;
    final offset = (along - centre) / (paddleLen / 2);
    if (offset.abs() <= 1.1) {
      rally++;
      reflect();
      // Hit position steers the ball like a classic pong paddle.
      final speed = ballSpeed;
      // Seeded deflection noise keeps rallies from locking into straight
      // back-and-forth lines (still deterministic for lockstep).
      final tangent = (offset.clamp(-1.0, 1.0) * 0.9 + (_rng.nextDouble() - 0.5) * 0.7).clamp(-1.1, 1.1);
      if (seat <= 1) {
        final sign = seat == 0 ? -1.0 : 1.0;
        ball
          ..vx = math.sin(tangent) * speed
          ..vy = sign * math.cos(tangent) * speed;
      } else {
        final sign = seat == 2 ? 1.0 : -1.0;
        ball
          ..vy = math.sin(tangent) * speed
          ..vx = sign * math.cos(tangent) * speed;
      }
      _clampBall();
      return;
    }
    p.lives--;
    lastScoredAgainst = seat;
    if (!isOver) _serve();
  }

  void _clampBall() {
    ball
      ..x = ball.x.clamp(ballRadius, size - ballRadius)
      ..y = ball.y.clamp(ballRadius, size - ballRadius);
  }

  /// Cheap fingerprint for lockstep desync detection.
  int stateHash() {
    var h = tick;
    int mix(int h, double v) => (h * 31 + (v * 1000).round()) & 0x3fffffff;
    h = mix(h, ball.x);
    h = mix(h, ball.y);
    h = mix(h, ball.vx);
    h = mix(h, ball.vy);
    for (final p in paddles) {
      h = mix(h, p.pos);
      h = (h * 31 + p.lives) & 0x3fffffff;
    }
    return h;
  }

  /// Pins the ball for tests.
  void debugBall(double x, double y, double vx, double vy) {
    _serveDelay = 0;
    ball
      ..x = x
      ..y = y
      ..vx = vx
      ..vy = vy;
  }
}

/// CPU paddle: tracks the ball along its edge with a reaction lag.
class PongAi {
  PongAi(this.seat, {this.skill = 0.8});
  final int seat;
  final double skill;

  PongInput think(PongWorld w) {
    final b = w.ball;
    final along = seat <= 1 ? b.x : b.y;
    final towardMe = switch (seat) {
      0 => b.vy > 0,
      1 => b.vy < 0,
      2 => b.vx < 0,
      _ => b.vx > 0,
    };
    final target = towardMe ? along / PongWorld.size : 0.5;
    final current = w.paddles[seat].pos;
    return PongInput(current + (target - current) * skill);
  }
}
