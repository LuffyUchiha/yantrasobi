/// Hand-authored, declarative Swing Hook levels.
///
/// World space uses +y pointing down. The acrobat spawns at (startX, startY)
/// with a hop of (launchVx, launchVy). Anything that drops below `killY`
/// falls into the pit. Reaching `finishX` wins. Checkpoints activate when the
/// acrobat passes their x; a respawn there re-launches with the same hop.
library;

class SwingAnchor {
  /// A static anchor, or a moving one when [period] > 0: its position is
  /// (x, y) + (dx, dy) * sin(2 pi t / period + phase).
  const SwingAnchor(this.x, this.y, {this.dx = 0, this.dy = 0, this.period = 0, this.phase = 0});
  final double x, y;
  final double dx, dy, period, phase;
  bool get moving => period > 0 && (dx != 0 || dy != 0);
}

/// A springy pad whose top edge is at y, spanning x..x+w. Landing on it from
/// above launches the acrobat upward at [power] and at least [kick] forward.
class SwingPad {
  const SwingPad(this.x, this.y, this.w, {this.power = 16, this.kick = 6});
  final double x, y, w;
  final double power, kick;
}

/// A lethal axis-aligned spike block.
class SwingSpike {
  const SwingSpike(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
}

class SwingCheckpoint {
  const SwingCheckpoint(this.x, this.y);
  final double x, y;
}

class SwingLevel {
  const SwingLevel({
    required this.name,
    required this.anchors,
    required this.finishX,
    this.startX = 2,
    this.startY = 9,
    this.launchVx = 7,
    this.launchVy = -8,
    this.killY = 18,
    this.range = 9,
    this.pads = const [],
    this.spikes = const [],
    this.checkpoints = const [],
  });

  final String name;
  final double startX, startY, launchVx, launchVy;
  final double finishX, killY, range;
  final List<SwingAnchor> anchors;
  final List<SwingPad> pads;
  final List<SwingSpike> spikes;
  final List<SwingCheckpoint> checkpoints;

  /// Structural problems with this level (empty when valid).
  List<String> validate() {
    final out = <String>[];
    if (name.isEmpty) out.add('missing name');
    if (finishX < startX + 10) out.add('finish too close to start');
    if (range < 6) out.add('range too short');
    if (anchors.isEmpty) out.add('no anchors');
    bool inSpikes(double x, double y, double margin) => spikes.any(
      (s) => x > s.x - margin && x < s.x + s.w + margin && y > s.y - margin && y < s.y + s.h + margin,
    );
    if (startY > killY - 3) out.add('start too low');
    if (inSpikes(startX, startY, 1.5)) out.add('start inside spikes');
    for (final a in anchors) {
      if (a.x <= startX || a.x >= finishX) out.add('anchor ${a.x} outside course');
      if (a.y + a.dy.abs() > killY - 4) out.add('anchor ${a.x} too low');
      if (a.period != 0 && a.period < 1.5) out.add('anchor ${a.x} moves too fast');
      if (inSpikes(a.x, a.y, 1.2 + a.dx.abs() + a.dy.abs())) out.add('anchor ${a.x} touches spikes');
    }
    for (final p in pads) {
      if (p.w <= 0 || p.power <= 0) out.add('bad pad at ${p.x}');
      if (p.y >= killY) out.add('pad at ${p.x} below the pit');
    }
    for (final s in spikes) {
      if (s.w <= 0 || s.h <= 0) out.add('bad spike at ${s.x}');
    }
    var lastX = startX;
    for (final c in checkpoints) {
      if (c.x <= lastX || c.x >= finishX) out.add('checkpoint ${c.x} out of order');
      if (c.y > killY - 3) out.add('checkpoint ${c.x} too low');
      if (inSpikes(c.x, c.y, 1.5)) out.add('checkpoint ${c.x} inside spikes');
      lastX = c.x;
    }
    // Every stretch of the course must have something to swing from or bounce on.
    final supports = <double>[startX, for (final a in anchors) a.x, for (final p in pads) p.x + p.w / 2]
      ..sort();
    supports.add(finishX);
    for (var i = 1; i < supports.length; i++) {
      if (supports[i] - supports[i - 1] > range * 1.4) {
        out.add('gap ${supports[i - 1]}..${supports[i]} too wide');
      }
    }
    return out;
  }
}

/// Returns level [n] (1-based). Past the authored set the levels loop with a
/// harder twist: shorter rope range and bobbing anchors.
SwingLevel swingLevel(int n) {
  final i = (n < 1 ? 0 : n - 1);
  final base = kSwingLevels[i % kSwingLevels.length];
  final loop = i ~/ kSwingLevels.length;
  if (loop == 0) return base;
  final bob = (0.6 * loop).clamp(0.0, 1.5);
  final speedUp = (1 - 0.1 * loop).clamp(0.7, 1.0);
  return SwingLevel(
    name: '${base.name} +$loop',
    startX: base.startX,
    startY: base.startY,
    launchVx: base.launchVx,
    launchVy: base.launchVy,
    finishX: base.finishX,
    killY: base.killY,
    range: base.range * (1 - 0.05 * loop).clamp(0.8, 1.0),
    pads: base.pads,
    spikes: base.spikes,
    checkpoints: base.checkpoints,
    anchors: [
      for (var k = 0; k < base.anchors.length; k++)
        base.anchors[k].moving
            ? SwingAnchor(
                base.anchors[k].x,
                base.anchors[k].y,
                dx: base.anchors[k].dx,
                dy: base.anchors[k].dy,
                period: base.anchors[k].period * speedUp,
                phase: base.anchors[k].phase,
              )
            : SwingAnchor(
                base.anchors[k].x,
                base.anchors[k].y,
                dy: bob,
                period: 3.2 + (k % 3) * 0.4,
                phase: k * 1.3,
              ),
    ],
  );
}

const List<SwingLevel> kSwingLevels = [
  // 1. Even, high anchors. Learn hold and release.
  SwingLevel(
    name: 'First Swing',
    finishX: 46,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 4),
      SwingAnchor(24, 4),
      SwingAnchor(32, 4),
      SwingAnchor(40, 4),
    ],
    checkpoints: [SwingCheckpoint(19, 8)],
  ),
  // 2. Wider and uneven gaps.
  SwingLevel(
    name: 'Long Reach',
    finishX: 52,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(17, 3),
      SwingAnchor(26, 5),
      SwingAnchor(35, 3),
      SwingAnchor(44, 4),
    ],
    checkpoints: [SwingCheckpoint(21, 8)],
  ),
  // 3. A spring pad catches a short swing.
  SwingLevel(
    name: 'Spring Step',
    finishX: 54,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 4),
      SwingAnchor(30, 3),
      SwingAnchor(38, 4),
      SwingAnchor(46, 3),
    ],
    pads: [SwingPad(18, 14, 9)],
    checkpoints: [SwingCheckpoint(26, 8)],
  ),
  // 4. The floor is lined with spikes.
  SwingLevel(
    name: 'Thorn Floor',
    finishX: 56,
    killY: 18,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 3),
      SwingAnchor(24, 4),
      SwingAnchor(32, 3),
      SwingAnchor(40, 4),
      SwingAnchor(48, 3),
    ],
    spikes: [SwingSpike(6, 14.5, 46, 1)],
    checkpoints: [SwingCheckpoint(28, 8)],
  ),
  // 5. Spike blocks hang between anchors; do not fly too high.
  SwingLevel(
    name: 'Hanging Thorns',
    finishX: 58,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 4),
      SwingAnchor(25, 4),
      SwingAnchor(34, 4),
      SwingAnchor(43, 4),
      SwingAnchor(51, 4),
    ],
    spikes: [SwingSpike(20, -6, 1.5, 4), SwingSpike(29, -6, 1.5, 4), SwingSpike(38, -6, 1.5, 4)],
    checkpoints: [SwingCheckpoint(30, 8)],
  ),
  // 6. Climb a staircase of anchors, then come back down.
  SwingLevel(
    name: 'Staircase',
    finishX: 58,
    anchors: [
      SwingAnchor(8, 5),
      SwingAnchor(15, 3),
      SwingAnchor(22, 1),
      SwingAnchor(29, -1),
      SwingAnchor(37, 1),
      SwingAnchor(44, 3),
      SwingAnchor(51, 5),
    ],
    checkpoints: [SwingCheckpoint(27, 4)],
  ),
  // 7. Springs between anchors.
  SwingLevel(
    name: 'Bounce House',
    finishX: 60,
    anchors: [SwingAnchor(8, 4), SwingAnchor(22, 3), SwingAnchor(37, 3), SwingAnchor(52, 4)],
    pads: [SwingPad(13, 13, 5), SwingPad(27, 13, 5), SwingPad(42, 13, 5)],
    spikes: [SwingSpike(18, 14.5, 3, 1), SwingSpike(32.5, 14.5, 3, 1)],
    checkpoints: [SwingCheckpoint(31, 7)],
  ),
  // 8. First moving anchors (they bob up and down).
  SwingLevel(
    name: 'Drifters',
    finishX: 56,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 4, dy: 1.5, period: 3),
      SwingAnchor(24, 4, dy: -1.5, period: 3),
      SwingAnchor(32, 4, dy: 1.5, period: 2.6, phase: 1),
      SwingAnchor(40, 4),
      SwingAnchor(48, 4, dy: 1.5, period: 3.4),
    ],
    checkpoints: [SwingCheckpoint(28, 8)],
  ),
  // 9. Anchors slide sideways over a spiked floor.
  SwingLevel(
    name: 'Sliders',
    finishX: 60,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(17, 3, dx: 2, period: 3.2),
      SwingAnchor(26, 4, dx: -2, period: 3.2),
      SwingAnchor(35, 3, dx: 2, period: 2.8, phase: 2),
      SwingAnchor(44, 4),
      SwingAnchor(52, 3, dx: 1.5, period: 3),
    ],
    spikes: [SwingSpike(10, 15, 40, 1)],
    checkpoints: [SwingCheckpoint(31, 8)],
  ),
  // 10. A long course with two checkpoints.
  SwingLevel(
    name: 'Long Haul',
    finishX: 84,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 3),
      SwingAnchor(25, 4),
      SwingAnchor(33, 2, dy: 1.2, period: 3),
      SwingAnchor(42, 4),
      SwingAnchor(50, 3),
      SwingAnchor(59, 4, dx: 1.5, period: 3),
      SwingAnchor(68, 3),
      SwingAnchor(77, 4),
    ],
    pads: [SwingPad(44, 14, 6)],
    spikes: [SwingSpike(20, -5, 1.5, 4), SwingSpike(54, 15, 10, 1)],
    checkpoints: [SwingCheckpoint(30, 8), SwingCheckpoint(56, 8)],
  ),
  // 11. Spikes above and below: keep the swing tidy.
  SwingLevel(
    name: 'Needle Run',
    finishX: 62,
    anchors: [
      SwingAnchor(8, 3),
      SwingAnchor(16, 3),
      SwingAnchor(24, 3),
      SwingAnchor(32, 3),
      SwingAnchor(40, 3),
      SwingAnchor(48, 3),
      SwingAnchor(56, 3),
    ],
    spikes: [SwingSpike(4, -5, 56, 1), SwingSpike(6, 14, 54, 1)],
    checkpoints: [SwingCheckpoint(28, 8)],
  ),
  // 12. Everything at once.
  SwingLevel(
    name: 'Grand Circus',
    finishX: 90,
    anchors: [
      SwingAnchor(8, 4),
      SwingAnchor(16, 3, dy: 1.2, period: 3),
      SwingAnchor(25, 2),
      SwingAnchor(34, 3, dx: 1.5, period: 3.2),
      SwingAnchor(50, 3),
      SwingAnchor(58, 4, dy: -1.2, period: 2.8),
      SwingAnchor(66, 3),
      SwingAnchor(75, 3, dx: -1.5, period: 3),
      SwingAnchor(83, 4),
    ],
    pads: [SwingPad(39, 13, 6)],
    spikes: [
      SwingSpike(20, -5, 1.5, 4),
      SwingSpike(36, 15, 2, 1),
      SwingSpike(46, 14.5, 4, 1),
      SwingSpike(62, -4, 1.5, 3.5),
      SwingSpike(70, 15, 10, 1),
    ],
    checkpoints: [SwingCheckpoint(30, 8), SwingCheckpoint(62, 8)],
  ),
];
