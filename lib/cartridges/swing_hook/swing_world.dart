import 'dart:math' as math;

import 'levels.dart';

export 'levels.dart';

/// Pure-Dart rules for Swing Hook. No Flutter/Flame imports; deterministic for
/// a given level + input sequence (fixed 1/120 s substeps).
///
/// World space uses +y pointing down. The acrobat is a point mass of radius
/// [kSwingPlayerRadius] under gravity. Holding attaches an inextensible rope to
/// the nearest anchor ahead within [SwingLevel.range]; the rope is a distance
/// constraint solved by position projection (position-based dynamics), so the
/// acrobat swings as a pendulum. Releasing keeps the velocity.

enum SwingPhase { flying, swinging, dying, won, lost }

const double kSwingStep = 1 / 120;
const double kSwingGravity = 25;
const double kSwingPlayerRadius = 0.35;
const double kSwingMaxSpeed = 26;
const double kSwingMinRope = 1.5;

/// Tangential push (units/s^2) applied while swinging forward, so a held
/// swing slowly gains energy like a pumped pendulum.
const double kSwingPump = 4;

/// Body spin multiplier applied on release (the acrobat tucks).
const double kSwingTuck = 2.2;
const double kSwingMaxSpin = 14;

/// Seconds between a failure and the respawn (or the final loss).
const double kSwingDeathDelay = 0.8;
const int kSwingRetries = 3;
const int kSwingFlipPoints = 50;

/// Live state of one anchor (moving anchors are re-evaluated every step).
class SwingAnchorState {
  SwingAnchorState(this.def) : x = def.x, y = def.y;
  final SwingAnchor def;
  double x, y;

  void place(double t) {
    if (def.period <= 0) {
      x = def.x;
      y = def.y;
      return;
    }
    final s = math.sin(t * math.pi * 2 / def.period + def.phase);
    x = def.x + def.dx * s;
    y = def.y + def.dy * s;
  }
}

class SwingWorld {
  /// Builds the authored level [levelNumber] (looping harder past the last).
  SwingWorld({required this.levelNumber, this.seed = 0}) : level = swingLevel(levelNumber) {
    _init();
  }

  /// Builds a world from an explicit level (tests, tools).
  SwingWorld.custom(this.level, {this.levelNumber = 1, this.seed = 0}) {
    _init();
  }

  final int levelNumber;
  final int seed;
  final SwingLevel level;

  late final List<SwingAnchorState> anchors;
  final List<double> padFlash = [];

  SwingPhase phase = SwingPhase.flying;

  // Player state.
  double px = 0, py = 0, vx = 0, vy = 0;

  /// Body axis angle (radians, direction from feet to head).
  double bodyAngle = -math.pi / 2;

  /// Angular velocity of the body (rad/s).
  double spin = 0;
  double _spinAccum = 0;

  /// Index of the anchor the rope is attached to, or -1.
  int ropeIndex = -1;
  double ropeLength = 0;

  /// Anchor that a press would grab right now, or -1.
  int targetIndex = -1;

  bool holding = false;
  double elapsed = 0;
  double _acc = 0;
  double _deathTimer = 0;
  double _lastBodyAngle = 0;

  int checkpoint = -1;
  int retriesLeft = kSwingRetries;
  int fails = 0;
  int flips = 0;
  int bounces = 0;
  int attaches = 0;

  /// Furthest x reached (for progress display).
  double bestX = 0;

  bool get isOver => phase == SwingPhase.won || phase == SwingPhase.lost;
  bool get won => phase == SwingPhase.won;
  bool get attached => ropeIndex >= 0;
  bool get alive => phase == SwingPhase.flying || phase == SwingPhase.swinging;
  int get entityCount => 1 + anchors.length + level.pads.length + level.spikes.length;
  double get speed => math.sqrt(vx * vx + vy * vy);
  double get progress => ((bestX - level.startX) / (level.finishX - level.startX)).clamp(0.0, 1.0);

  int get clearBonus => 1000 + 100 * levelNumber;
  int get timePenalty => math.min(clearBonus * 0.6, elapsed * 10).round();
  int get score => math.max(0, (won ? clearBonus - timePenalty : 0) + flips * kSwingFlipPoints);

  /// Where the next respawn happens.
  double get spawnX => checkpoint < 0 ? level.startX : level.checkpoints[checkpoint].x;
  double get spawnY => checkpoint < 0 ? level.startY : level.checkpoints[checkpoint].y;

  void _init() {
    anchors = [for (final a in level.anchors) SwingAnchorState(a)];
    padFlash.addAll(List.filled(level.pads.length, 0));
    _spawn();
    _updateTarget();
  }

  void _spawn() {
    px = spawnX;
    py = spawnY;
    vx = level.launchVx;
    vy = level.launchVy;
    ropeIndex = -1;
    bodyAngle = -math.pi / 2;
    spin = 0;
    _spinAccum = 0;
    phase = SwingPhase.flying;
    bestX = math.max(bestX, px);
  }

  // ---------------------------------------------------------------- input
  void press() {
    holding = true;
    if (alive && !attached) _tryAttach();
  }

  void release() {
    holding = false;
    if (attached) _detach();
  }

  // ---------------------------------------------------------------- update
  void update(double dt) {
    if (isOver) return;
    _acc += math.min(dt, 0.25);
    while (_acc >= kSwingStep && !isOver) {
      _acc -= kSwingStep;
      step();
    }
  }

  /// Advances exactly one fixed step.
  void step() {
    if (isOver) return;
    const h = kSwingStep;
    elapsed += h;
    for (final a in anchors) {
      a.place(elapsed);
    }
    for (var i = 0; i < padFlash.length; i++) {
      if (padFlash[i] > 0) padFlash[i] = math.max(0, padFlash[i] - h);
    }
    if (phase == SwingPhase.dying) {
      _deathTimer -= h;
      if (_deathTimer <= 0) {
        if (retriesLeft > 0) {
          retriesLeft--;
          _spawn();
        } else {
          phase = SwingPhase.lost;
        }
      }
      return;
    }

    _updateTarget();
    if (holding && !attached) _tryAttach();

    // Integrate (semi-implicit), then project the rope constraint.
    vy += kSwingGravity * h;
    if (attached) {
      final a = anchors[ropeIndex];
      final rx = px - a.x, ry = py - a.y;
      final d = math.sqrt(rx * rx + ry * ry);
      if (d > 1e-6) {
        // Tangent that points rightward when the acrobat hangs below the anchor.
        final tx = ry / d, ty = -rx / d;
        final vt = vx * tx + vy * ty;
        if (vt > 0 && vx > 0) {
          vx += tx * kSwingPump * h;
          vy += ty * kSwingPump * h;
        }
      }
    }
    final ox = px, oy = py;
    px += vx * h;
    py += vy * h;
    if (attached) {
      final a = anchors[ropeIndex];
      final rx = px - a.x, ry = py - a.y;
      final d = math.sqrt(rx * rx + ry * ry);
      if (d > ropeLength && d > 1e-9) {
        px = a.x + rx / d * ropeLength;
        py = a.y + ry / d * ropeLength;
      }
      vx = (px - ox) / h;
      vy = (py - oy) / h;
    }
    final sp = speed;
    if (sp > kSwingMaxSpeed) {
      vx *= kSwingMaxSpeed / sp;
      vy *= kSwingMaxSpeed / sp;
    }

    _updateBody(h);
    _collidePads(oy);
    if (px > bestX) bestX = px;

    // Hazards.
    if (py - kSwingPlayerRadius > level.killY) {
      _fail();
      return;
    }
    for (final s in level.spikes) {
      if (_circleHitsRect(px, py, kSwingPlayerRadius * 0.85, s.x, s.y, s.w, s.h)) {
        _fail();
        return;
      }
    }
    // Checkpoints.
    for (var i = checkpoint + 1; i < level.checkpoints.length; i++) {
      if (px >= level.checkpoints[i].x) checkpoint = i;
    }
    if (px >= level.finishX) {
      phase = SwingPhase.won;
      ropeIndex = -1;
    }
  }

  void _updateBody(double h) {
    if (attached) {
      final a = anchors[ropeIndex];
      final ang = math.atan2(a.y - py, a.x - px);
      var d = ang - _lastBodyAngle;
      if (d > math.pi) d -= math.pi * 2;
      if (d < -math.pi) d += math.pi * 2;
      spin = d / h;
      _lastBodyAngle = ang;
      bodyAngle = ang;
    } else {
      bodyAngle += spin * h;
      _spinAccum += spin * h;
      if (_spinAccum.abs() >= math.pi * 2) {
        flips++;
        _spinAccum -= _spinAccum.sign * math.pi * 2;
      }
    }
  }

  void _collidePads(double oldY) {
    for (var i = 0; i < level.pads.length; i++) {
      final p = level.pads[i];
      if (px < p.x - kSwingPlayerRadius || px > p.x + p.w + kSwingPlayerRadius) continue;
      final top = p.y;
      if (vy > 0 && oldY + kSwingPlayerRadius <= top + 0.05 && py + kSwingPlayerRadius >= top) {
        py = top - kSwingPlayerRadius;
        vy = -math.max(p.power, vy * 0.6);
        if (vx < p.kick) vx = p.kick;
        bounces++;
        padFlash[i] = 0.3;
        if (attached) _detach();
        spin = (spin + vx * 0.35).clamp(-kSwingMaxSpin, kSwingMaxSpin);
      }
    }
  }

  void _fail() {
    phase = SwingPhase.dying;
    ropeIndex = -1;
    fails++;
    _deathTimer = kSwingDeathDelay;
  }

  /// Nearest anchor ahead of the acrobat, above it and within range.
  int findTarget() {
    var best = -1;
    var bestD = level.range * level.range;
    for (var i = 0; i < anchors.length; i++) {
      final a = anchors[i];
      if (a.x < px - 0.75) continue; // behind
      if (a.y > py - 0.5) continue; // not above
      final dx = a.x - px, dy = a.y - py;
      final d = dx * dx + dy * dy;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _updateTarget() => targetIndex = alive && !attached ? findTarget() : -1;

  void _tryAttach() {
    final t = findTarget();
    if (t < 0) return;
    final a = anchors[t];
    final d = math.sqrt((a.x - px) * (a.x - px) + (a.y - py) * (a.y - py));
    ropeIndex = t;
    ropeLength = math.max(kSwingMinRope, d);
    targetIndex = -1;
    phase = SwingPhase.swinging;
    attaches++;
    _spinAccum = 0;
    _lastBodyAngle = math.atan2(a.y - py, a.x - px);
  }

  void _detach() {
    ropeIndex = -1;
    if (phase == SwingPhase.swinging) phase = SwingPhase.flying;
    spin = (spin * kSwingTuck).clamp(-kSwingMaxSpin, kSwingMaxSpin);
    _spinAccum = 0;
  }

  static bool _circleHitsRect(double cx, double cy, double r, double x, double y, double w, double h) {
    final nx = cx.clamp(x, x + w);
    final ny = cy.clamp(y, y + h);
    final dx = cx - nx, dy = cy - ny;
    return dx * dx + dy * dy < r * r;
  }

  // ---------------------------------------------------------------- debug
  /// Puts the acrobat at an exact state (tests).
  void debugPlace(double x, double y, {double vx = 0, double vy = 0}) {
    px = x;
    py = y;
    this.vx = vx;
    this.vy = vy;
    ropeIndex = -1;
    phase = SwingPhase.flying;
  }

  /// Attaches the rope to anchor [i] at the current distance (tests).
  void debugAttach(int i) {
    final a = anchors[i];
    ropeIndex = i;
    ropeLength = math.sqrt((a.x - px) * (a.x - px) + (a.y - py) * (a.y - py));
    phase = SwingPhase.swinging;
    _lastBodyAngle = math.atan2(a.y - py, a.x - px);
    holding = true;
  }

  void debugSetSpin(double w) {
    spin = w;
    _spinAccum = 0;
  }

  /// Compact state fingerprint used by determinism tests.
  String fingerprint() =>
      '${px.toStringAsFixed(6)},${py.toStringAsFixed(6)},${vx.toStringAsFixed(6)},'
      '${vy.toStringAsFixed(6)},$phase,$flips,$fails,$checkpoint,$ropeIndex';
}
