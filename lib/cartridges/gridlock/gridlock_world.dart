import 'dart:math' as math;

/// Pure-Dart rules for Gridlock, a traffic-escape puzzle. No Flutter/Flame
/// imports, so every rule is unit-testable and deterministic for a given
/// seed + level.
///
/// The lot is a [GridlockWorld.cols] x [GridlockWorld.rows] grid of cells.
/// Each [Vehicle] covers a straight run of 1x2 or 1x3 cells and faces one end
/// of its long axis. Tapping a vehicle drives it forward: if every cell from
/// its front bumper to the lot edge is empty it leaves the lot, otherwise it
/// bumps the first obstacle and rolls back to where it was (a strike). The
/// rules are instantaneous; any sliding/bumping is animated by the renderer.

enum GridlockPhase { playing, won, lost }

/// What a single tap did.
enum GridlockOutcome { exited, blocked, invalid }

/// Facing direction of a vehicle (screen axes: +x right, +y down).
enum Heading {
  up(0, -1),
  right(1, 0),
  down(0, 1),
  left(-1, 0);

  const Heading(this.dx, this.dy);
  final int dx;
  final int dy;

  bool get horizontal => dx != 0;
}

class Vehicle {
  Vehicle(this.id, this.col, this.row, this.length, this.heading, {this.kind = 0})
    : assert(length >= 2 && length <= 3);

  final int id;

  /// Top-left cell of the vehicle.
  final int col;
  final int row;
  final int length;
  final Heading heading;

  /// Cosmetic paint index, chosen by the generator.
  final int kind;

  /// Left the lot.
  bool exited = false;

  bool get horizontal => heading.horizontal;

  /// Cells covered, from the top-left cell along the long axis.
  List<(int, int)> get cells => [
    for (var i = 0; i < length; i++) horizontal ? (col + i, row) : (col, row + i),
  ];

  /// The cell holding the front bumper.
  (int, int) get front => switch (heading) {
    Heading.right => (col + length - 1, row),
    Heading.down => (col, row + length - 1),
    Heading.left || Heading.up => (col, row),
  };

  bool occupies(int c, int r) =>
      horizontal ? r == row && c >= col && c < col + length : c == col && r >= row && r < row + length;

  @override
  String toString() => 'Vehicle($id @$col,$row len$length ${heading.name})';
}

class GridlockTapResult {
  const GridlockTapResult(this.outcome, {this.vehicle, this.travel = 0, this.blockerId = -1});

  final GridlockOutcome outcome;
  final Vehicle? vehicle;

  /// Exited: cells between the front bumper and the edge.
  /// Blocked: free cells the vehicle could roll before hitting [blockerId].
  final int travel;

  /// The vehicle that stopped a blocked move, or -1.
  final int blockerId;
}

class GridlockWorld {
  GridlockWorld({required this.seed, this.level = 1})
    : assert(level >= 1),
      cols = colsForLevel(level),
      rows = rowsForLevel(level),
      _rng = math.Random(seed * 7919 + level * 104729) {
    _grid = List<int>.filled(cols * rows, -1);
    _generate();
  }

  /// A hand-built lot for tests and tools. Vehicle ids must equal their index
  /// and vehicles must not overlap. [solution] is left empty.
  GridlockWorld.custom(this.cols, this.rows, List<Vehicle> list, {this.seed = 0, this.level = 1})
    : _rng = math.Random(seed) {
    _grid = List<int>.filled(cols * rows, -1);
    for (var i = 0; i < list.length; i++) {
      final v = list[i];
      assert(v.id == i, 'vehicle ids must match their index');
      for (final (c, r) in v.cells) {
        assert(inBounds(c, r) && _grid[r * cols + c] < 0, 'vehicle $i is out of bounds or overlaps');
        _grid[r * cols + c] = v.id;
      }
      vehicles.add(v);
    }
  }

  final int seed;
  final int level;
  final int cols;
  final int rows;
  final math.Random _rng;
  late final List<int> _grid;

  // ---------------------------------------------------------------- constants
  static const int maxStrikes = 3;
  static const int startHints = 2;
  static const int pointsPerCar = 10;
  static const int perfectBonusPerCar = 5;
  static const int timeBonusPerSecond = 2;
  static const double parSecondsPerCar = 2.5;

  // ---------------------------------------------------------------- level shape
  static int _step(int level) => (level - 1) ~/ 3;
  static int colsForLevel(int level) => math.min(9, 6 + _step(level));
  static int rowsForLevel(int level) => math.min(12, 8 + 2 * _step(level));

  /// Fraction of cells the generator tries to fill with vehicles.
  static double densityForLevel(int level) => math.min(0.78, 0.5 + 0.03 * (level - 1));

  /// Chance that a new vehicle is a 3-cell truck.
  static double truckChanceFor(int level) => math.min(0.45, 0.1 + 0.035 * (level - 1));

  /// Chance the generator picks the placement that blocks the most existing
  /// exit paths (otherwise a random legal placement). Higher = more interlocked.
  static double tangleFor(int level) => math.min(0.85, 0.35 + 0.05 * (level - 1));

  /// Target vehicle count; the real count may be lower if the lot fills up.
  static int targetCarsFor(int level) =>
      (colsForLevel(level) * rowsForLevel(level) * densityForLevel(level) / 2.3).round();

  // ---------------------------------------------------------------- state
  final List<Vehicle> vehicles = [];

  /// A guaranteed winning tap order (vehicle ids): the reverse of the
  /// construction order. Each vehicle's exit path was clear of every vehicle
  /// placed before it, and those are exactly the ones still parked when it is
  /// its turn to leave.
  final List<int> solution = [];

  GridlockPhase phase = GridlockPhase.playing;
  int score = 0;
  int strikes = 0;
  int moves = 0;
  int exitedCount = 0;
  int hintsLeft = startHints;
  int timeBonus = 0;
  int perfectBonus = 0;
  double time = 0;

  bool get isOver => phase != GridlockPhase.playing;
  bool get won => phase == GridlockPhase.won;
  bool get lost => phase == GridlockPhase.lost;
  int get carsLeft => vehicles.length - exitedCount;
  int get entityCount => carsLeft;
  int get strikesLeft => maxStrikes - strikes;
  bool get canHint => !isOver && hintsLeft > 0 && carsLeft > 0;

  /// Seconds under which a win still earns a time bonus.
  double get parTime => vehicles.length * parSecondsPerCar + 10;

  Iterable<Vehicle> get parked => vehicles.where((v) => !v.exited);

  bool inBounds(int c, int r) => c >= 0 && r >= 0 && c < cols && r < rows;

  Vehicle? vehicleById(int id) => id >= 0 && id < vehicles.length ? vehicles[id] : null;

  /// The parked vehicle covering cell ([col], [row]), or null.
  Vehicle? vehicleAt(int col, int row) {
    if (!inBounds(col, row)) return null;
    final id = _grid[row * cols + col];
    return id < 0 ? null : vehicles[id];
  }

  /// Walks from the front bumper towards the edge. Returns the number of free
  /// cells before the first obstacle and that obstacle's id (-1 if none).
  (int, int) probe(Vehicle v) {
    var (c, r) = v.front;
    var free = 0;
    while (true) {
      c += v.heading.dx;
      r += v.heading.dy;
      if (!inBounds(c, r)) return (free, -1);
      final id = _grid[r * cols + c];
      if (id >= 0) return (free, id);
      free++;
    }
  }

  /// True if vehicle [id] is parked and its path to the edge is clear now.
  bool canExit(int id) {
    final v = vehicleById(id);
    if (v == null || v.exited) return false;
    return probe(v).$2 < 0;
  }

  List<Vehicle> exitable() => [
    for (final v in vehicles)
      if (!v.exited && probe(v).$2 < 0) v,
  ];

  void update(double dt) {
    if (phase == GridlockPhase.playing) time += dt;
  }

  // ---------------------------------------------------------------- actions
  GridlockTapResult tap(int id) {
    final v = vehicleById(id);
    if (isOver || v == null || v.exited) return const GridlockTapResult(GridlockOutcome.invalid);
    moves++;
    final (free, blocker) = probe(v);
    if (blocker >= 0) {
      strikes++;
      if (strikes >= maxStrikes) phase = GridlockPhase.lost;
      return GridlockTapResult(GridlockOutcome.blocked, vehicle: v, travel: free, blockerId: blocker);
    }
    v.exited = true;
    for (final (c, r) in v.cells) {
      _grid[r * cols + c] = -1;
    }
    exitedCount++;
    score += pointsPerCar;
    if (carsLeft == 0) {
      phase = GridlockPhase.won;
      if (strikes == 0) perfectBonus = vehicles.length * perfectBonusPerCar;
      timeBonus = math.max(0, (parTime - time).round()) * timeBonusPerSecond;
      score += perfectBonus + timeBonus;
    }
    return GridlockTapResult(GridlockOutcome.exited, vehicle: v, travel: free);
  }

  /// Uses one hint and returns a vehicle that can leave right now (the next
  /// step of [solution] among the parked vehicles), or null if no hint is left.
  Vehicle? hint() {
    if (!canHint) return null;
    final v = peekHint();
    if (v != null) hintsLeft--;
    return v;
  }

  /// The vehicle [hint] would suggest, without spending a hint.
  ///
  /// Exiting only ever frees cells, so the first parked vehicle in [solution]
  /// order is always exitable. Custom lots (no solution) fall back to a scan.
  Vehicle? peekHint() {
    for (final id in solution) {
      if (canExit(id)) return vehicles[id];
    }
    final list = exitable();
    return list.isEmpty ? null : list.first;
  }

  // ---------------------------------------------------------------- debug
  /// ASCII picture of the lot: arrows for front bumpers, letters for bodies.
  String debugAscii() {
    final b = StringBuffer();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final v = vehicleAt(c, r);
        if (v == null) {
          b.write('.');
        } else if (v.front == (c, r)) {
          b.write(switch (v.heading) {
            Heading.up => '^',
            Heading.right => '>',
            Heading.down => 'v',
            Heading.left => '<',
          });
        } else {
          b.write(String.fromCharCode(97 + v.id % 26));
        }
      }
      if (r < rows - 1) b.writeln();
    }
    return b.toString();
  }

  /// Snapshot of the generated layout, for determinism checks.
  String debugSignature() =>
      vehicles.map((v) => '${v.col},${v.row},${v.length},${v.heading.index},${v.kind}').join(';');

  // ---------------------------------------------------------------- generation
  /// Reverse construction: repeatedly park a vehicle in free cells whose exit
  /// path is clear on the current lot. Removing vehicles in reverse order is
  /// then always legal, so the lot is solvable by construction.
  void _generate() {
    final target = targetCarsFor(level);
    final truckChance = truckChanceFor(level);
    final tangle = tangleFor(level);
    final built = <int>[];
    var failures = 0;
    while (vehicles.length < target && failures < 2) {
      final wantTruck = _rng.nextDouble() < truckChance;
      var cands = _candidates(wantTruck ? 3 : 2);
      if (cands.isEmpty) cands = _candidates(wantTruck ? 2 : 3);
      if (cands.isEmpty) {
        failures++;
        continue;
      }
      Vehicle pick;
      if (vehicles.isNotEmpty && _rng.nextDouble() < tangle) {
        // Prefer the placement that sits across the most existing exit paths.
        var best = -1;
        final bestList = <Vehicle>[];
        for (final c in cands) {
          final s = _blockScore(c);
          if (s > best) {
            best = s;
            bestList.clear();
          }
          if (s == best) bestList.add(c);
        }
        pick = bestList[_rng.nextInt(bestList.length)];
      } else {
        pick = cands[_rng.nextInt(cands.length)];
      }
      final v = Vehicle(
        vehicles.length,
        pick.col,
        pick.row,
        pick.length,
        pick.heading,
        kind: _rng.nextInt(1 << 16),
      );
      vehicles.add(v);
      for (final (c, r) in v.cells) {
        _grid[r * cols + c] = v.id;
      }
      built.add(v.id);
    }
    solution.addAll(built.reversed);
  }

  /// Every legal placement of a [length]-cell vehicle on the current lot.
  List<Vehicle> _candidates(int length) {
    final out = <Vehicle>[];
    for (final h in Heading.values) {
      final maxC = h.horizontal ? cols - length : cols - 1;
      final maxR = h.horizontal ? rows - 1 : rows - length;
      for (var r = 0; r <= maxR; r++) {
        for (var c = 0; c <= maxC; c++) {
          final v = Vehicle(-1, c, r, length, h);
          if (v.cells.every((p) => _grid[p.$2 * cols + p.$1] < 0) && probe(v).$2 < 0) out.add(v);
        }
      }
    }
    return out;
  }

  /// How strongly candidate [v] tangles the lot: cutting a currently clear
  /// exit path counts most, cutting an already blocked one a little, and a
  /// long open road ahead of [v] (room for later vehicles to block it) adds a
  /// tie-breaker.
  int _blockScore(Vehicle v) {
    var n = 0;
    for (final o in vehicles) {
      final (_, blocker) = probe(o);
      var (c, r) = o.front;
      while (true) {
        c += o.heading.dx;
        r += o.heading.dy;
        if (!inBounds(c, r)) break;
        if (v.occupies(c, r)) {
          n += blocker < 0 ? 8 : 2;
          break;
        }
      }
    }
    return n + probe(v).$1;
  }
}
