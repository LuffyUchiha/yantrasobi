import 'dart:math' as math;

/// Pure-Dart rules for Stack Runner. No Flutter/Flame imports, so every rule
/// is unit-testable and deterministic for a given seed + level.
///
/// World space: the track runs along +z (forward). x is lateral, the runner is
/// clamped to [-maxX, maxX] (five lanes centred on -2..2). Blocks are
/// [blockHeight] tall; a wall of height h is exactly h blocks tall.

enum StackPhase { ready, running, climbing, won, lost }

enum ItemKind { block, gem, wall, gap }

enum LossCause { none, wall, gap }

/// Something that happened this tick, consumed by the renderer for SFX/FX.
enum StackEventKind { block, gem, wallHit, crash, bridge, fall, finish, step, win }

class StackEvent {
  const StackEvent(this.kind, this.x, this.y, this.z, [this.count = 1]);
  final StackEventKind kind;
  final double x;
  final double y;
  final double z;
  final int count;
}

/// One thing on the track. Items are kept sorted by [z].
class TrackItem {
  TrackItem.block(this.x, this.z) : kind = ItemKind.block, x0 = x, x1 = x, height = 0, segments = 0;

  TrackItem.gem(this.x, this.z, {this.height = 0}) : kind = ItemKind.gem, x0 = x, x1 = x, segments = 0;

  TrackItem.wall(this.z, this.x0, this.x1, this.height)
    : kind = ItemKind.wall,
      x = (x0 + x1) / 2,
      segments = 0;

  TrackItem.gap(this.z, this.segments) : kind = ItemKind.gap, x = 0, x0 = -2.5, x1 = 2.5, height = 0;

  final ItemKind kind;
  final double z;

  /// Centre x (blocks, gems).
  final double x;

  /// Lateral span (walls, gaps).
  final double x0;
  final double x1;

  /// Wall height in blocks; for gems, 1 means "floating over a gap".
  final int height;

  /// Gap length in segments (one block bridges one segment).
  final int segments;

  /// Block/gem collected, or wall already struck.
  bool taken = false;

  /// Gap segments bridged so far.
  int bridged = 0;

  double get endZ => switch (kind) {
    ItemKind.gap => z + segments * StackWorld.gapSegment,
    ItemKind.wall => z + StackWorld.wallDepth,
    _ => z,
  };
}

/// A block left on the track: stripped by a wall (layer >= 0) or laid as a
/// bridge plank inside a gap (layer == -1).
class PlacedBlock {
  PlacedBlock(this.x, this.z, this.layer);
  final double x;
  final double z;
  final int layer;
}

class StackWorld {
  StackWorld({this.level = 1, int seed = 1})
    : assert(level >= 1),
      courseLength = courseLengthFor(level),
      speed = speedFor(level),
      _rng = math.Random(seed * 7919 + level * 104729) {
    _generate();
  }

  // ---------------------------------------------------------------- tuning
  static const double maxX = 2.0;
  static const double trackHalfWidth = 2.5;
  static const double runnerHalfWidth = 0.35;
  static const double pickupReach = 0.75;
  static const double blockHeight = 0.35;
  static const double gapSegment = 1.0;
  static const double wallDepth = 0.6;
  static const double stepDepth = 1.4;
  static const double stepHeight = 0.45;
  static const int maxMultiplier = 10;
  static const int startStack = 1;
  static const int maxStack = 120;
  static const int _maxPlaced = 240;

  static double courseLengthFor(int level) => math.min(420.0, 100.0 + 24.0 * (level - 1));
  static double speedFor(int level) => math.min(12.0, 7.5 + 0.35 * (level - 1));

  /// Blocks needed to climb from multiplier `m - 1` onto the x[m] step on
  /// [level]. Steps get pricier as levels (and their block hauls) grow.
  static int stepCostFor(int level, int m) => m <= 1 ? 0 : ((m - 1) * (1 + (level - 1) * 0.12)).round();

  /// Blocks needed on [level] to climb from the finish line to x[m].
  static int costToReachFor(int level, int m) {
    var total = 0;
    for (var i = 2; i <= m; i++) {
      total += stepCostFor(level, i);
    }
    return total;
  }

  int stepCost(int m) => stepCostFor(level, m);
  int costToReach(int m) => costToReachFor(level, m);

  // ---------------------------------------------------------------- state
  final int level;
  final double courseLength;
  final double speed;
  final math.Random _rng;

  final List<TrackItem> items = [];
  final List<PlacedBlock> placed = [];
  final List<StackEvent> events = [];

  StackPhase phase = StackPhase.ready;
  LossCause lossCause = LossCause.none;
  double x = 0;
  double distance = 0;
  double time = 0;
  int stack = startStack;
  int gems = 0;
  int multiplier = 1;
  int blocksCollected = 0;
  int blocksLost = 0;
  int _cursor = 0;
  TrackItem? _activeGap;
  double _stepTimer = 0;

  bool get isOver => phase == StackPhase.won || phase == StackPhase.lost;
  bool get won => phase == StackPhase.won;

  /// Gems times the multiplier step reached (x1 until the finish line).
  int get score => gems * multiplier;

  int get entityCount {
    var n = 1 + placed.length + stack;
    for (var i = _cursor; i < items.length; i++) {
      if (!items[i].taken) n++;
    }
    return n;
  }

  double get finishZ => courseLength;

  /// 0..1 progress to the finish line.
  double get progress => (distance / courseLength).clamp(0.0, 1.0);

  /// Top of the floor/step under the runner.
  double get baseY {
    if (distance < finishZ) return 0;
    final step = ((distance - finishZ) / stepDepth).floor().clamp(0, maxMultiplier - 1);
    return step * stepHeight;
  }

  /// Centre z of the x[m] step.
  double stepCenterZ(int m) => finishZ + (m - 1 + 0.5) * stepDepth;

  /// Total blocks the course forces you to spend (wall heights + gap segments),
  /// a coarse difficulty measure.
  int get hazardCost {
    var n = 0;
    for (final it in items) {
      if (it.kind == ItemKind.wall) n += it.height;
      if (it.kind == ItemKind.gap) n += it.segments;
    }
    return n;
  }

  int countOf(ItemKind kind) => items.where((i) => i.kind == kind).length;

  // ---------------------------------------------------------------- input
  /// Begins running (first touch).
  void start() {
    if (phase == StackPhase.ready) phase = StackPhase.running;
  }

  /// Relative steering in track units; clamped to the track.
  void steer(double dx) {
    if (phase != StackPhase.ready && phase != StackPhase.running) return;
    x = (x + dx).clamp(-maxX, maxX);
  }

  // ---------------------------------------------------------------- sim
  void update(double dt) {
    events.clear();
    if (isOver || phase == StackPhase.ready) return;
    var remaining = math.min(dt, 0.25);
    while (remaining > 1e-9) {
      final step = math.min(remaining, 1 / 60);
      _step(step);
      remaining -= step;
      if (isOver) break;
    }
  }

  void _step(double dt) {
    time += dt;
    if (phase == StackPhase.climbing) {
      _climb(dt);
      return;
    }
    distance += speed * dt;
    while (_cursor < items.length && items[_cursor].z <= distance) {
      _resolve(items[_cursor]);
      _cursor++;
      if (isOver) return;
    }
    final gap = _activeGap;
    if (gap != null) {
      while (gap.bridged < gap.segments && distance >= gap.z + gap.bridged * gapSegment) {
        if (stack <= 0) {
          _lose(LossCause.gap, StackEventKind.fall);
          return;
        }
        stack--;
        blocksLost++;
        _place(x, gap.z + (gap.bridged + 0.5) * gapSegment, -1);
        gap.bridged++;
        events.add(StackEvent(StackEventKind.bridge, x, 0, gap.z + gap.bridged * gapSegment));
      }
      if (gap.bridged >= gap.segments) _activeGap = null;
    }
    if (distance >= finishZ) {
      distance = finishZ;
      phase = StackPhase.climbing;
      _stepTimer = 0;
      events.add(StackEvent(StackEventKind.finish, x, 0, finishZ, stack));
    }
  }

  void _resolve(TrackItem it) {
    if (it.taken) return;
    switch (it.kind) {
      case ItemKind.block:
        if ((it.x - x).abs() < pickupReach) {
          it.taken = true;
          blocksCollected++;
          if (stack < maxStack) stack++;
          events.add(StackEvent(StackEventKind.block, it.x, stack * blockHeight, it.z, stack));
        }
      case ItemKind.gem:
        if ((it.x - x).abs() < pickupReach) {
          it.taken = true;
          gems++;
          events.add(StackEvent(StackEventKind.gem, it.x, stack * blockHeight + 0.6, it.z));
        }
      case ItemKind.wall:
        if (x + runnerHalfWidth > it.x0 && x - runnerHalfWidth < it.x1) {
          it.taken = true;
          if (stack < it.height) {
            _lose(LossCause.wall, StackEventKind.crash, it.z);
            return;
          }
          stack -= it.height;
          blocksLost += it.height;
          for (var i = 0; i < it.height; i++) {
            _place(x, it.z - 0.45, i);
          }
          events.add(StackEvent(StackEventKind.wallHit, x, it.height * blockHeight, it.z, it.height));
        }
      case ItemKind.gap:
        _activeGap = it;
    }
  }

  void _lose(LossCause cause, StackEventKind kind, [double? z]) {
    phase = StackPhase.lost;
    lossCause = cause;
    events.add(StackEvent(kind, x, 0, z ?? distance));
  }

  void _place(double px, double pz, int layer) {
    if (placed.length >= _maxPlaced) placed.removeAt(0);
    placed.add(PlacedBlock(px, pz, layer));
  }

  void _climb(double dt) {
    final target = stepCenterZ(multiplier);
    if (distance < target) {
      distance = math.min(target, distance + speed * 0.6 * dt);
      return;
    }
    _stepTimer -= dt;
    if (_stepTimer > 0) return;
    final next = multiplier + 1;
    if (next <= maxMultiplier && stack >= stepCost(next)) {
      stack -= stepCost(next);
      multiplier = next;
      _stepTimer = 0.08;
      events.add(StackEvent(StackEventKind.step, x, (next - 1) * stepHeight, stepCenterZ(next), next));
    } else {
      phase = StackPhase.won;
      events.add(StackEvent(StackEventKind.win, x, baseY, distance, multiplier));
    }
  }

  // ---------------------------------------------------------------- level generation
  void _generate() {
    final lvl = level;
    final maxWallH = math.min(4, 1 + (lvl + 1) ~/ 2);
    final maxWallLanes = math.min(4, 2 + lvl ~/ 2);
    final maxGap = math.min(6, 2 + lvl ~/ 2);
    final hazardChance = math.min(0.7, 0.36 + 0.04 * lvl);
    final spacing = math.max(3.0, 6.0 - 0.25 * lvl);
    // Blocks the player can reasonably have banked (collectible minus forced).
    var budget = startStack.toDouble();
    var z = 10.0;
    final end = courseLength - 12;

    double lane() => _rng.nextInt(5) - 2.0;

    void row(double laneX, int n, double startZ) {
      for (var i = 0; i < n; i++) {
        items.add(TrackItem.block(laneX, startZ + i * 1.1));
      }
      budget += n * 0.7;
    }

    while (z < end) {
      final roll = _rng.nextDouble();
      if (roll < hazardChance && z > 18) {
        if (_rng.nextDouble() < 0.55) {
          // Wall: a slab across some lanes; a reward row waits behind it.
          final forced = lvl >= 2 && _rng.nextDouble() < math.min(0.45, 0.1 + 0.04 * lvl);
          final lanes = forced ? 5 : 2 + _rng.nextInt(maxWallLanes - 1);
          final h = forced ? 1 + _rng.nextInt(math.min(3, 1 + lvl ~/ 3)) : 1 + _rng.nextInt(maxWallH);
          if (forced && budget < h + 2) {
            row(lane(), h + 3, z);
            z += (h + 3) * 1.1 + spacing;
          }
          final start = _rng.nextInt(5 - lanes + 1);
          final x0 = start - 2.5;
          items.add(TrackItem.wall(z, x0, x0 + lanes, h));
          if (forced) budget -= h;
          // Tempting reward behind the wall, inside its span.
          final rewardLane = start + _rng.nextInt(lanes) - 2.0;
          for (var i = 0; i < h + 1; i++) {
            items.add(TrackItem.block(rewardLane, z + 1.6 + i * 1.1));
          }
          // Gems in the open lane, if any.
          if (lanes < 5) {
            final openLane = start > 0 ? start - 1 - 2.0 : start + lanes - 2.0;
            for (var i = 0; i < 3; i++) {
              items.add(TrackItem.gem(openLane, z - 1 + i * 1.3));
            }
          }
          z += 1.6 + (h + 1) * 1.1 + spacing;
        } else {
          // Gap: spans the whole track, one block per segment.
          final n = 1 + _rng.nextInt(maxGap);
          if (budget < n + 2) {
            row(lane(), n + 3, z);
            z += (n + 3) * 1.1 + spacing;
          }
          items.add(TrackItem.gap(z, n));
          budget -= n;
          // Gems float over longer gaps.
          if (n >= 2) {
            final gx = lane();
            for (var i = 0; i < n; i++) {
              items.add(TrackItem.gem(gx, z + (i + 0.5) * gapSegment, height: 1));
            }
          }
          z += n * gapSegment + spacing;
        }
      } else {
        final kind = _rng.nextInt(4);
        switch (kind) {
          case 0:
            row(lane(), 3 + _rng.nextInt(4), z);
            z += 9 + spacing * 0.5;
          case 1:
            // Slalom of blocks.
            final n = 6 + _rng.nextInt(4);
            final phase0 = _rng.nextDouble() * math.pi * 2;
            for (var i = 0; i < n; i++) {
              items.add(TrackItem.block((math.sin(phase0 + i * 0.55) * 1.8).clamp(-maxX, maxX), z + i * 1.2));
            }
            budget += n * 0.6;
            z += n * 1.2 + spacing * 0.5;
          case 2:
            // Two parallel rows: blocks on one lane, gems on another.
            final a = _rng.nextInt(5);
            final b = (a + 2 + _rng.nextInt(2)) % 5;
            final n = 4 + _rng.nextInt(3);
            row(a - 2.0, n, z);
            for (var i = 0; i < n; i++) {
              items.add(TrackItem.gem(b - 2.0, z + i * 1.1));
            }
            z += n * 1.1 + spacing;
          default:
            // Gem diagonal.
            final from = lane();
            final dir = from > 0 ? -1.0 : 1.0;
            for (var i = 0; i < 5; i++) {
              items.add(TrackItem.gem((from + dir * i).clamp(-maxX, maxX), z + i * 1.5));
            }
            z += 7.5 + spacing * 0.5;
        }
      }
    }
    // Final bonus run of blocks before the stairs.
    final bonusLane = lane();
    for (var i = 0; i < 5 + math.min(5, lvl); i++) {
      final bz = courseLength - 11 + i * 1.0;
      if (bz < courseLength - 0.5) items.add(TrackItem.block(bonusLane, bz));
    }
    _sortItems();
  }

  void _sortItems() {
    // Stable insertion order for ties keeps generation deterministic.
    final indexed = List.generate(items.length, (i) => i);
    indexed.sort((a, b) {
      final c = items[a].z.compareTo(items[b].z);
      return c != 0 ? c : a.compareTo(b);
    });
    final sorted = [for (final i in indexed) items[i]];
    items
      ..clear()
      ..addAll(sorted.where((it) => it.z < courseLength));
  }

  // ---------------------------------------------------------------- test helpers
  /// Removes every generated item so tests can build a custom course.
  void debugClearTrack() {
    items.clear();
    _cursor = 0;
    _activeGap = null;
  }

  void debugAdd(TrackItem item) {
    var i = items.length;
    while (i > 0 && items[i - 1].z > item.z) {
      i--;
    }
    items.insert(i, item);
  }

  void debugSetStack(int n) => stack = n;

  void debugSetGems(int n) => gems = n;

  /// Runs at 60 Hz for [seconds] of game time.
  void debugRun(double seconds) {
    for (var t = 0.0; t < seconds - 1e-9; t += 1 / 60) {
      update(1 / 60);
    }
  }
}
