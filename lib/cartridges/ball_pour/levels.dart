/// Hand-authored, declarative Ball Pour levels.
///
/// World space is [kPourWidth] x [kPourHeight] units with +y pointing down.
/// The hopper sits above y = 2; balls leave its spout at `hopperX`. Anything
/// that falls below the bottom edge is lost. Angles are in degrees; with +y
/// down a positive angle tilts a plank's right end downward.
library;

const double kPourWidth = 10;
const double kPourHeight = 16;

/// Hard cap on live balls (hopper + multiplier splits never exceed it).
const int kPourBallCap = 250;

class WallDef {
  const WallDef(this.ax, this.ay, this.bx, this.by, {this.bounce = 0.3, this.friction = 0.3});
  final double ax, ay, bx, by;
  final double bounce;
  final double friction;
}

class PegDef {
  const PegDef(this.x, this.y, [this.r = 0.13]);
  final double x, y, r;
}

/// A multiplier ring: every ball passing through it splits into two.
class RingDef {
  const RingDef(this.x, this.y, [this.r = 0.5]);
  final double x, y, r;
}

enum PlankKind { slide, pivot }

/// A player-controlled plank.
///
/// * [PlankKind.slide]: the plank's centre slides along the rail from
///   (ax, ay) to (bx, by) at a fixed [angle].
/// * [PlankKind.pivot]: the plank spins about (ax, ay) between [minAngle]
///   and [maxAngle].
///
/// [start] is the initial rail parameter (0..1); [hint] is the authored
/// solution position used by tests and the attract-mode demo.
class PlankDef {
  const PlankDef.slide({
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.length,
    this.angle = 0,
    this.start = 0,
    this.hint = 0.5,
  }) : kind = PlankKind.slide,
       minAngle = angle,
       maxAngle = angle;

  const PlankDef.pivot({
    required double px,
    required double py,
    required this.length,
    required this.minAngle,
    required this.maxAngle,
    this.start = 0,
    this.hint = 0.5,
  }) : kind = PlankKind.pivot,
       ax = px,
       ay = py,
       bx = px,
       by = py,
       angle = minAngle;

  final PlankKind kind;
  final double ax, ay, bx, by;
  final double length;
  final double angle;
  final double minAngle, maxAngle;
  final double start;
  final double hint;
}

class CupDef {
  const CupDef({
    required this.x,
    required this.bottom,
    required this.width,
    required this.height,
    this.sway = 0,
    this.period = 5,
  });

  /// Centre x, bottom y, inner width and wall height.
  final double x, bottom, width, height;

  /// Left-right sway amplitude (0 = static) and its period in seconds.
  final double sway;
  final double period;

  double get top => bottom - height;
}

class PourLevelDef {
  const PourLevelDef({
    required this.name,
    required this.balls,
    required this.target,
    required this.hopperX,
    required this.cup,
    this.flowRate = 14,
    this.walls = const [],
    this.pegs = const [],
    this.rings = const [],
    this.planks = const [],
    this.tip = '',
    this.pourAtCupX,
  });

  final String name;
  final int balls;
  final int target;
  final double hopperX;
  final double flowRate;
  final CupDef cup;
  final List<WallDef> walls;
  final List<PegDef> pegs;
  final List<RingDef> rings;
  final List<PlankDef> planks;
  final String tip;

  /// Authored solution hint for swaying cups: pour while the cup centre is
  /// within half a unit of this x. Used by tests and the demo player.
  final double? pourAtCupX;

  /// A harder copy for the [loop]-th pass through the level list: a higher
  /// target, a narrower cup and a livelier sway, clamped to stay valid.
  PourLevelDef harder(int loop) {
    if (loop <= 0) return this;
    final t = (target * (1 + 0.07 * loop)).round();
    final maxTarget = (balls * 0.85).floor();
    final w = width(cup.width * (1 - 0.05 * loop));
    var sway = cup.sway + 0.3 * loop;
    final roomLeft = cup.x - w / 2 - 0.3;
    final roomRight = kPourWidth - 0.3 - cup.x - w / 2;
    final room = roomLeft < roomRight ? roomLeft : roomRight;
    if (sway > room) sway = room < 0 ? 0 : room;
    return PourLevelDef(
      name: '$name+$loop',
      balls: balls,
      target: t > maxTarget ? (maxTarget > target ? maxTarget : target) : t,
      hopperX: hopperX,
      flowRate: flowRate + loop,
      cup: CupDef(
        x: cup.x,
        bottom: cup.bottom,
        width: w,
        height: cup.height,
        sway: sway,
        period: cup.sway > 0 ? cup.period * 0.9 : 4.5,
      ),
      walls: walls,
      pegs: pegs,
      rings: rings,
      planks: planks,
      tip: tip,
      pourAtCupX: pourAtCupX,
    );
  }

  static double width(double w) => w < 1.6 ? 1.6 : w;

  /// Problems with this level (empty if it is playable).
  List<String> validate() {
    final p = <String>[];
    if (balls <= 0 || balls > kPourBallCap) p.add('$name: ball count $balls out of range');
    if (target <= 0 || target > balls) p.add('$name: target $target not in 1..$balls');
    if (hopperX < 0.8 || hopperX > kPourWidth - 0.8) p.add('$name: hopper off screen');
    final left = cup.x - cup.width / 2 - cup.sway;
    final right = cup.x + cup.width / 2 + cup.sway;
    if (left < 0.1 || right > kPourWidth - 0.1) p.add('$name: cup leaves the screen horizontally');
    if (cup.top < 3 || cup.bottom > kPourHeight - 0.2) p.add('$name: cup leaves the screen vertically');
    if (cup.width < 1.2 || cup.height < 0.8) p.add('$name: cup too small');
    bool inside(double x, double y) => x >= 0 && x <= kPourWidth && y >= 0 && y <= kPourHeight;
    for (final w in walls) {
      if (!inside(w.ax, w.ay) || !inside(w.bx, w.by)) p.add('$name: wall outside bounds');
    }
    for (final g in pegs) {
      if (!inside(g.x, g.y)) p.add('$name: peg outside bounds');
    }
    for (final r in rings) {
      if (!inside(r.x, r.y)) p.add('$name: ring outside bounds');
    }
    if (rings.length > 8) p.add('$name: too many rings');
    for (final k in planks) {
      if (!inside(k.ax, k.ay) || !inside(k.bx, k.by)) p.add('$name: plank rail outside bounds');
      if (k.start < 0 || k.start > 1 || k.hint < 0 || k.hint > 1) p.add('$name: plank t out of 0..1');
      if (k.length <= 0.4) p.add('$name: plank too short');
      if (k.kind == PlankKind.pivot && k.minAngle > k.maxAngle) p.add('$name: pivot range inverted');
    }
    return p;
  }
}

/// The authored campaign, easiest first. After the last level the list
/// loops with [PourLevelDef.harder].
const List<PourLevelDef> kPourLevels = [
  // 1. Straight down: learn to hold the gate.
  PourLevelDef(
    name: 'First Pour',
    balls: 40,
    target: 24,
    hopperX: 5,
    cup: CupDef(x: 5, bottom: 14.6, width: 3.0, height: 2.0),
    pegs: [PegDef(2.2, 8), PegDef(7.8, 8)],
    tip: 'Hold anywhere to open the gate',
  ),
  // 2. A fixed ramp carries the stream across.
  PourLevelDef(
    name: 'Ramp Run',
    balls: 50,
    target: 36,
    hopperX: 2.5,
    cup: CupDef(x: 7.2, bottom: 14.6, width: 3.0, height: 2.0),
    walls: [WallDef(1.2, 5.0, 6.2, 7.2), WallDef(9.9, 8.2, 7.4, 10.2), WallDef(5.9, 9.4, 5.9, 12.2)],
    tip: 'Ramps carry the stream to the cup',
  ),
  // 3. First plank: slide it under the stream.
  PourLevelDef(
    name: 'Slide Plank',
    balls: 50,
    target: 28,
    hopperX: 6,
    cup: CupDef(x: 2.4, bottom: 14.6, width: 3.0, height: 2.0),
    planks: [
      PlankDef.slide(ax: 3.0, ay: 10.0, bx: 8.6, by: 10.0, length: 3.0, angle: -15, start: 1, hint: 0.5),
    ],
    tip: 'Drag the plank to steer the balls',
  ),
  // 4. Pegs scatter the stream; funnel walls recollect it.
  PourLevelDef(
    name: 'Peg Garden',
    balls: 60,
    target: 44,
    hopperX: 5,
    cup: CupDef(x: 5, bottom: 14.8, width: 2.6, height: 1.9),
    pegs: [
      PegDef(4.4, 5.0), PegDef(5.6, 5.0), //
      PegDef(3.8, 6.2), PegDef(5.0, 6.2), PegDef(6.2, 6.2),
      PegDef(3.2, 7.4), PegDef(4.4, 7.4), PegDef(5.6, 7.4), PegDef(6.8, 7.4),
      PegDef(3.8, 8.6), PegDef(5.0, 8.6), PegDef(6.2, 8.6),
    ],
    walls: [WallDef(0.2, 8.5, 3.4, 11.4), WallDef(9.8, 8.5, 6.6, 11.4)],
    tip: 'Pegs scatter, funnels gather',
  ),
  // 5. A pivoting paddle picks the side.
  PourLevelDef(
    name: 'Seesaw',
    balls: 60,
    target: 34,
    hopperX: 5,
    cup: CupDef(x: 7.8, bottom: 14.6, width: 2.8, height: 2.0),
    walls: [WallDef(0.2, 9.0, 3.0, 11.0)],
    pegs: [PegDef(5.0, 11.0, 0.3)],
    planks: [
      PlankDef.pivot(px: 5.0, py: 6.5, length: 3.0, minAngle: -35, maxAngle: 35, start: 0.0, hint: 0.7),
    ],
    tip: 'Tilt the paddle toward the cup',
  ),
  // 6. Multiplier ring: route the stream through it.
  PourLevelDef(
    name: 'Double Up',
    balls: 40,
    target: 36,
    hopperX: 2.2,
    cup: CupDef(x: 7.0, bottom: 14.6, width: 3.2, height: 2.2),
    rings: [RingDef(5.0, 9.0, 0.6)],
    planks: [PlankDef.slide(ax: 1.2, ay: 6.0, bx: 6.0, by: 6.0, length: 2.6, angle: 15, start: 1, hint: 0.3)],
    tip: 'Rings split every ball in two',
  ),
  // 7. The cup starts to drift.
  PourLevelDef(
    name: 'Drifter',
    balls: 60,
    target: 32,
    hopperX: 5,
    cup: CupDef(x: 5, bottom: 14.6, width: 3.0, height: 2.0, sway: 2.2, period: 5),
    walls: [WallDef(3.4, 9.4, 4.6, 10.4), WallDef(6.6, 9.4, 5.4, 10.4)],
    tip: 'Pour when the cup passes under',
    pourAtCupX: 2.8,
  ),
  // 8. Two planks relay the stream.
  PourLevelDef(
    name: 'Relay',
    balls: 70,
    target: 40,
    hopperX: 1.6,
    cup: CupDef(x: 5.5, bottom: 14.8, width: 2.8, height: 2.0),
    walls: [WallDef(0.2, 3.6, 2.8, 4.6), WallDef(5.4, 7.8, 2.0, 9.6)],
    planks: [
      PlankDef.slide(ax: 3.2, ay: 6.0, bx: 7.0, by: 6.0, length: 2.4, angle: 15, start: 1, hint: 0.2),
      PlankDef.slide(ax: 5.0, ay: 10.4, bx: 8.6, by: 10.4, length: 2.8, angle: -15, start: 0, hint: 0.7),
    ],
    tip: 'Line the planks up into a zigzag',
  ),
  // 9. Rings, pegs and a drifting cup.
  PourLevelDef(
    name: 'Split Rain',
    balls: 50,
    target: 44,
    hopperX: 5,
    cup: CupDef(x: 5, bottom: 14.8, width: 2.8, height: 2.1, sway: 1.8, period: 6),
    rings: [RingDef(3.4, 6.6, 0.55), RingDef(6.6, 6.6, 0.55)],
    pegs: [PegDef(2.0, 9.4), PegDef(8.0, 9.4)],
    walls: [WallDef(0.2, 9.6, 2.6, 11.2), WallDef(9.8, 9.6, 7.4, 11.2)],
    planks: [PlankDef.pivot(px: 5.0, py: 4.6, length: 2.2, minAngle: -30, maxAngle: 30, start: 0.7, hint: 1)],
    tip: 'Tip the stream toward the cup',
    pourAtCupX: 3.2,
  ),
  // 10. Everything at once.
  PourLevelDef(
    name: 'Grand Pour',
    balls: 80,
    target: 60,
    hopperX: 8.4,
    cup: CupDef(x: 3.0, bottom: 15.0, width: 2.8, height: 2.0, sway: 1.0, period: 6),
    walls: [WallDef(9.8, 4.2, 6.8, 5.4), WallDef(6.0, 4.6, 6.0, 8.0)],
    rings: [RingDef(3.2, 11.0, 0.55)],
    pegs: [PegDef(5.4, 12.0), PegDef(6.4, 12.6)],
    planks: [
      PlankDef.slide(ax: 4.5, ay: 9.2, bx: 8.0, by: 9.2, length: 2.4, angle: -15, start: 1, hint: 0.4),
    ],
    tip: 'Ramp, ring, plank, cup',
    pourAtCupX: 2.4,
  ),
];

/// The effective definition for a 1-based [level], looping with harder
/// parameters after the authored list runs out.
PourLevelDef pourLevel(int level) {
  final i = (level < 1 ? 0 : level - 1);
  final loop = i ~/ kPourLevels.length;
  return kPourLevels[i % kPourLevels.length].harder(loop);
}
