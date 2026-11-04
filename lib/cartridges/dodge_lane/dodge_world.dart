import 'dart:math' as math;

/// What fills one lane of an obstacle row.
enum Cell { empty, block, low, high }

/// What the craft must be doing to pass a cell.
enum DodgeAction { none, jump, duck }

enum PickupKind { shield, magnet, slowmo }

enum DodgeEventKind { lane, jump, duck, coin, pickup, shieldBreak, crash, nearMiss, telegraph }

/// Something that happened during the last [DodgeWorld.update]; consumed by the renderer.
class DodgeEvent {
  const DodgeEvent(this.kind, this.x, this.z, {this.pickup});

  final DodgeEventKind kind;

  /// Lane coordinate (0 = left lane, 2 = right lane) and track distance.
  final double x;
  final double z;
  final PickupKind? pickup;
}

/// One row of the pattern library: three cells plus an optional mover.
///
/// Text form, one char per lane: `.` empty, `B` block, `L` low barrier (jump),
/// `H` high bar (duck), `>` / `<` a block that slides one lane right / left
/// shortly before it reaches the craft (its destination must be `.`).
class RowSpec {
  RowSpec(List<Cell> cells, {this.moverFrom = -1, this.moverTo = -1}) : cells = List.unmodifiable(cells) {
    if (cells.length != DodgeWorld.laneCount) {
      throw ArgumentError('a row needs ${DodgeWorld.laneCount} cells');
    }
  }

  factory RowSpec.parse(String code) {
    if (code.length != DodgeWorld.laneCount) throw ArgumentError('bad row "$code"');
    final cells = List<Cell>.filled(DodgeWorld.laneCount, Cell.empty);
    var from = -1, to = -1;
    for (var i = 0; i < code.length; i++) {
      switch (code[i]) {
        case '.':
          break;
        case 'B':
          cells[i] = Cell.block;
        case 'L':
          cells[i] = Cell.low;
        case 'H':
          cells[i] = Cell.high;
        case '>':
        case '<':
          if (from >= 0) throw ArgumentError('only one mover per row: "$code"');
          from = i;
          to = code[i] == '>' ? i + 1 : i - 1;
        default:
          throw ArgumentError('bad cell "${code[i]}" in "$code"');
      }
    }
    if (from >= 0 && (to < 0 || to >= DodgeWorld.laneCount || code[to] != '.')) {
      throw ArgumentError('mover in "$code" must slide into an empty lane');
    }
    return RowSpec(cells, moverFrom: from, moverTo: to);
  }

  final List<Cell> cells;
  final int moverFrom;
  final int moverTo;

  bool get hasMover => moverFrom >= 0;

  /// The cell once any mover has finished sliding (what the craft meets).
  Cell finalCell(int lane) => hasMover && lane == moverTo ? Cell.block : cells[lane];

  RowSpec mirrored() => RowSpec(
    cells.reversed.toList(),
    moverFrom: hasMover ? DodgeWorld.laneCount - 1 - moverFrom : -1,
    moverTo: hasMover ? DodgeWorld.laneCount - 1 - moverTo : -1,
  );

  String get code {
    final b = StringBuffer();
    for (var i = 0; i < cells.length; i++) {
      if (i == moverFrom) {
        b.write(moverTo > moverFrom ? '>' : '<');
        continue;
      }
      b.write(switch (cells[i]) {
        Cell.empty => '.',
        Cell.block => 'B',
        Cell.low => 'L',
        Cell.high => 'H',
      });
    }
    return b.toString();
  }

  @override
  String toString() => code;
}

/// A placed row: its obstacles' near edge sits at track distance [z].
class DodgeRow {
  DodgeRow(this.spec, this.z);

  final RowSpec spec;
  final double z;

  @override
  String toString() => '${spec.code}@${z.toStringAsFixed(2)}';
}

/// The passability validator.
///
/// Lanes are bit masks (bit 0 = left lane). Between two rows the craft has a
/// time window (gap minus obstacle depth and craft length, divided by the
/// speed at the later row, which is the fastest it will be going) in which it
/// can shift `floor(window / laneSwitchTime)` lanes. Low barriers need a jump
/// and high bars a duck; both are instant and cancel each other, so only the
/// lane shifts constrain a path.
class Passability {
  Passability._();

  static const int allLanes = (1 << DodgeWorld.laneCount) - 1;

  /// The action that passes [cell], or null if it can't be passed at all.
  static DodgeAction? actionFor(Cell cell) => switch (cell) {
    Cell.empty => DodgeAction.none,
    Cell.low => DodgeAction.jump,
    Cell.high => DodgeAction.duck,
    Cell.block => null,
  };

  /// Lanes of [row] passable with some action.
  static int safeMask(RowSpec row) {
    var m = 0;
    for (var l = 0; l < DodgeWorld.laneCount; l++) {
      if (actionFor(row.finalCell(l)) != null) m |= 1 << l;
    }
    return m;
  }

  /// Whole lanes the craft can shift in [seconds].
  static int stepsFor(double seconds) {
    if (seconds <= 0) return 0;
    return math.min(DodgeWorld.laneCount - 1, (seconds / DodgeWorld.laneSwitchTime + 1e-9).floor());
  }

  /// Lanes reachable from [mask] within [steps] lane shifts.
  static int spread(int mask, int steps) {
    var m = mask;
    for (var i = 0; i < steps; i++) {
      m = (m | (m << 1) | (m >> 1)) & allLanes;
    }
    return m;
  }

  /// Seconds between the craft's tail leaving the row at [zFrom] and its nose
  /// reaching the row at [zTo].
  static double windowBetween(double zFrom, double zTo) {
    final travel = zTo - zFrom - DodgeWorld.obstacleDepth - 2 * DodgeWorld.halfLength;
    return travel / DodgeWorld.speedAt(zTo);
  }

  /// Seconds before the craft's nose (now at [distance]) reaches the row at [zTo].
  static double windowFromCraft(double distance, double zTo) =>
      (zTo - DodgeWorld.halfLength - distance) / DodgeWorld.speedAt(zTo);

  /// Lanes of [row] the craft can be in, given the lanes [fromMask] it could
  /// be in at the previous row and the [window] in seconds between them.
  static int reach(int fromMask, RowSpec row, double window) =>
      spread(fromMask, stepsFor(window)) & safeMask(row);

  /// Index of the first row (sorted by z) with no reachable lane, or -1 if
  /// the whole sequence can be survived from [startLane] at [startDistance].
  static int firstFailure(List<DodgeRow> rows, {double startDistance = 0, int startLane = 1}) {
    var mask = 1 << startLane;
    for (var i = 0; i < rows.length; i++) {
      final w = i == 0 ? windowFromCraft(startDistance, rows[0].z) : windowBetween(rows[i - 1].z, rows[i].z);
      mask = reach(mask, rows[i].spec, w);
      if (mask == 0) return i;
    }
    return -1;
  }
}

class Obstacle {
  Obstacle(this.kind, this.x, this.lane, this.z, {this.mover = false});

  final Cell kind;

  /// Current lane coordinate (movers slide toward [lane]).
  double x;
  final int lane;
  final double z;
  final bool mover;
  bool telegraphed = false;
  bool moving = false;
  bool hit = false;
  bool passed = false;
}

class Coin {
  Coin(this.x, this.z);
  double x;
  final double z;
}

class Pickup {
  Pickup(this.kind, this.x, this.z);
  final PickupKind kind;
  final double x;
  final double z;
}

/// The lane and action the validator recommends for the next row.
class DodgeAdvice {
  const DodgeAdvice(this.lane, this.action, this.rowZ);

  final int lane;
  final DodgeAction action;

  /// Near edge of the row the advice is for (null when no row is ahead).
  final double? rowZ;
}

/// Endless three-lane dodge run. Pure rules: no Flutter, deterministic per seed.
///
/// Track coordinates: `x` is a lane coordinate (0..2), `z` metres along the
/// track. The craft's centre is at [distance]; it spans ±[halfLength].
class DodgeWorld {
  DodgeWorld({int seed = 1, this.generate = true, this.recordRows = false}) : _rng = math.Random(seed) {
    _nextPickupZ = 220 + _rng.nextDouble() * 120;
    if (generate) _generateUntil(distance + spawnAhead);
  }

  // ---------------------------------------------------------------- tuning
  static const int laneCount = 3;
  static const double laneSwitchTime = 0.15;
  static const double jumpTime = 0.6;
  static const double reboostWindow = 0.3;
  static const double duckTime = 0.6;
  static const double obstacleDepth = 0.8;
  static const double halfLength = 0.4;
  static const double hitHalfWidth = 0.65;
  static const double startSpeed = 12;
  static const double maxSpeed = 32;
  static const double accel = 0.12;
  static const double slowFactor = 0.55;
  static const double slowDuration = 3;
  static const double magnetDuration = 8;
  static const double magnetReach = 1.6;
  static const double shieldGrace = 0.6;
  static const double spawnAhead = 90;
  static const double firstRowZ = 40;
  static const double moverTelegraph = 2.2;
  static const double moverLead = 1.0;
  static const double moverShiftTime = 0.25;
  static const double nearMissSpeed = 16;
  static const int nearMissBonus = 5;
  static const int coinValue = 10;

  /// Base speed at track distance [z]: constant acceleration, capped. Speed is
  /// a function of distance (not time), so the validator knows exactly how
  /// fast the craft will be going at every row.
  static double speedAt(double z) => math.min(maxSpeed, math.sqrt(startSpeed * startSpeed + 2 * accel * z));

  // ---------------------------------------------------------------- pattern library
  static const List<List<String>> tier0 = [
    ['.B.'],
    ['B..'],
    ['..B'],
    ['BB.'],
    ['B.B'],
    ['LLL'],
    ['HHH'],
    ['.L.'],
    ['L.L'],
    ['.H.'],
    ['B..', '..B'],
  ];
  static const List<List<String>> tier1 = [
    ['BL.'],
    ['B.H'],
    ['BLB'],
    ['BHB'],
    ['LBL'],
    ['HBH'],
    ['>..'],
    ['.>.'],
    ['L>.'],
    ['BB.', 'B.B'],
    ['B.B', '.B.'],
    ['LLL', 'HHH'],
    ['.B.', 'B.B', '.B.'],
    ['B..', '.B.', '..B'],
  ];
  static const List<List<String>> tier2 = [
    ['BLB', 'BHB'],
    ['LHB'],
    ['HLH'],
    ['>.B'],
    ['B>.', 'B.B'],
    ['BB.', '.BB'],
    ['BB.', 'B.B', '.BB'],
    ['HHH', 'LLL', 'HHH'],
    ['LBH', 'HBL'],
    ['.>.', 'B.H', 'BB.'],
    ['BH.', '.BL', 'L.B'],
  ];
  static final List<RowSpec> _fallbacks = [RowSpec.parse('LLL'), RowSpec.parse('HHH')];

  // ---------------------------------------------------------------- state
  final math.Random _rng;
  final bool generate;
  final bool recordRows;

  /// Debug: ignore collisions (lets tests drive the generator for a long run).
  bool invincible = false;

  double time = 0;
  double distance = 0;
  double speed = startSpeed;
  double topSpeed = startSpeed;

  /// Craft lane coordinate and the lane it is sliding toward.
  double x = 1;
  int targetLane = 1;

  double airTime = 0;
  double airElapsed = 0;
  double duckTimer = 0;
  bool shield = false;
  double magnetTimer = 0;
  double slowTimer = 0;
  double _grace = 0;

  int coins = 0;
  int bonus = 0;
  int nearMisses = 0;
  bool isOver = false;
  Obstacle? crashedInto;

  final List<Obstacle> obstacles = [];
  final List<Coin> coinItems = [];
  final List<Pickup> pickups = [];

  /// Rows the craft has not fully passed yet, sorted by z.
  final List<DodgeRow> rows = [];

  /// Every generated row, kept only when [recordRows] is set.
  final List<DodgeRow> rowLog = [];
  final List<DodgeEvent> events = [];

  int generatedRows = 0;
  double _nextZ = firstRowZ;
  double? _lastRowZ;
  int _mask = 1 << 1;
  late double _nextPickupZ;

  bool get airborne => airTime > 0;
  bool get ducking => duckTimer > 0;
  int get score => distance.floor() + coins * coinValue + bonus;
  int get entityCount => obstacles.length + coinItems.length + pickups.length;

  // ---------------------------------------------------------------- input
  void laneLeft() => _shift(-1);
  void laneRight() => _shift(1);

  void _shift(int d) {
    if (isOver) return;
    final t = targetLane + d;
    if (t < 0 || t >= laneCount) return;
    targetLane = t;
    events.add(DodgeEvent(DodgeEventKind.lane, t.toDouble(), distance));
  }

  /// Jumps (clears low barriers). In the last [reboostWindow] seconds of a
  /// jump, pressing again re-boosts the hop so back-to-back barriers work.
  void jump() {
    if (isOver) return;
    if (airborne) {
      if (airTime >= reboostWindow) return;
      airTime += reboostWindow;
    } else {
      airTime = jumpTime;
      airElapsed = 0;
    }
    duckTimer = 0;
    events.add(DodgeEvent(DodgeEventKind.jump, x, distance));
  }

  /// Ducks under high bars; cancels a jump (fast drop).
  void duck() {
    if (isOver) return;
    duckTimer = duckTime;
    airTime = 0;
    events.add(DodgeEvent(DodgeEventKind.duck, x, distance));
  }

  // ---------------------------------------------------------------- simulation
  void update(double dt) {
    events.clear();
    if (isOver || dt <= 0) return;
    var left = math.min(dt, 0.1);
    while (left > 1e-9 && !isOver) {
      final step = math.min(left, 1 / 60);
      _step(step);
      left -= step;
    }
  }

  void _step(double dt) {
    time += dt;
    if (airTime > 0) {
      airTime = math.max(0, airTime - dt);
      airElapsed += dt;
    }
    if (duckTimer > 0) duckTimer = math.max(0, duckTimer - dt);
    if (magnetTimer > 0) magnetTimer = math.max(0, magnetTimer - dt);
    if (slowTimer > 0) slowTimer = math.max(0, slowTimer - dt);
    if (_grace > 0) _grace = math.max(0, _grace - dt);

    speed = speedAt(distance) * (slowTimer > 0 ? slowFactor : 1);
    topSpeed = math.max(topSpeed, speed);
    distance += speed * dt;

    // Slide toward the target lane at a constant rate.
    final maxMove = dt / laneSwitchTime;
    final dx = targetLane - x;
    x = dx.abs() <= maxMove ? targetLane.toDouble() : x + maxMove * dx.sign;

    if (generate) _generateUntil(distance + spawnAhead);

    final front = distance + halfLength;
    final back = distance - halfLength;
    for (final o in obstacles) {
      if (o.mover) {
        final dz = o.z - front;
        if (!o.telegraphed && dz < speed * moverTelegraph) {
          o.telegraphed = true;
          events.add(DodgeEvent(DodgeEventKind.telegraph, o.x, o.z));
        }
        if (!o.moving && dz < speed * moverLead) o.moving = true;
        if (o.moving && o.x != o.lane) {
          final step = dt / moverShiftTime;
          final d = o.lane - o.x;
          o.x = d.abs() <= step ? o.lane.toDouble() : o.x + step * d.sign;
        }
      }
      if (o.hit || o.passed) continue;
      if (o.z + obstacleDepth < back) {
        o.passed = true;
        final side = (o.x - x).abs();
        if (o.kind == Cell.block && speed >= nearMissSpeed && side >= hitHalfWidth && side < 1.35) {
          nearMisses++;
          bonus += nearMissBonus;
          events.add(DodgeEvent(DodgeEventKind.nearMiss, o.x, o.z));
        }
        continue;
      }
      if (o.z >= front || (o.x - x).abs() >= hitHalfWidth) continue;
      final blocked = switch (o.kind) {
        Cell.block => true,
        Cell.low => !airborne,
        Cell.high => !ducking,
        Cell.empty => false,
      };
      if (!blocked || invincible || _grace > 0) continue;
      if (shield) {
        shield = false;
        o.hit = true;
        _grace = shieldGrace;
        events.add(DodgeEvent(DodgeEventKind.shieldBreak, o.x, o.z));
        continue;
      }
      isOver = true;
      crashedInto = o;
      events.add(DodgeEvent(DodgeEventKind.crash, x, distance));
      return;
    }

    // Coins, pulled in by the magnet.
    final reachX = magnetTimer > 0 ? magnetReach : hitHalfWidth;
    for (var i = coinItems.length - 1; i >= 0; i--) {
      final c = coinItems[i];
      final dz = c.z - distance;
      if (magnetTimer > 0 && dz < 12 && dz > -1 && (c.x - x).abs() < magnetReach) {
        final pull = dt * 6;
        final d = x - c.x;
        c.x = d.abs() <= pull ? x : c.x + pull * d.sign;
      }
      if (dz.abs() < 0.9 && (c.x - x).abs() < reachX) {
        coins++;
        coinItems.removeAt(i);
        events.add(DodgeEvent(DodgeEventKind.coin, c.x, c.z));
      } else if (dz < -3) {
        coinItems.removeAt(i);
      }
    }
    for (var i = pickups.length - 1; i >= 0; i--) {
      final p = pickups[i];
      final dz = p.z - distance;
      if (dz.abs() < 0.9 && (p.x - x).abs() < hitHalfWidth) {
        pickups.removeAt(i);
        switch (p.kind) {
          case PickupKind.shield:
            shield = true;
          case PickupKind.magnet:
            magnetTimer = magnetDuration;
          case PickupKind.slowmo:
            slowTimer = slowDuration;
        }
        events.add(DodgeEvent(DodgeEventKind.pickup, p.x, p.z, pickup: p.kind));
      } else if (dz < -3) {
        pickups.removeAt(i);
      }
    }
    obstacles.removeWhere((o) => o.z + obstacleDepth < distance - 6);
    while (rows.isNotEmpty && rows.first.z + obstacleDepth < back) {
      rows.removeAt(0);
    }
  }

  // ---------------------------------------------------------------- generation
  void _generateUntil(double zLimit) {
    while (_nextZ < zLimit) {
      _emitSequence();
    }
  }

  List<RowSpec> _pickSequence() {
    final z = _nextZ;
    final r = _rng.nextDouble();
    final List<List<String>> tier;
    if (z < 250) {
      tier = tier0;
    } else if (z < 800) {
      tier = r < 0.4 ? tier0 : tier1;
    } else {
      tier = r < 0.2 ? tier0 : (r < 0.65 ? tier1 : tier2);
    }
    final seq = tier[_rng.nextInt(tier.length)];
    final mirror = _rng.nextBool();
    return [
      for (final code in seq)
        if (mirror) RowSpec.parse(code).mirrored() else RowSpec.parse(code),
    ];
  }

  static double difficultyAt(double z) => (z / 3000).clamp(0.0, 1.0);

  void _emitSequence() {
    final seq = _pickSequence();
    var z = _nextZ;
    for (var i = 0; i < seq.length; i++) {
      if (i > 0) z += speedAt(z) * (0.45 - 0.13 * difficultyAt(z));
      var spec = seq[i];
      final last = _lastRowZ;
      final window = last == null ? Passability.windowFromCraft(0, z) : Passability.windowBetween(last, z);
      var mask = Passability.reach(_mask, spec, window);
      if (mask == 0) {
        // The pattern can't be reached from where the craft could be: swap in
        // an all-lanes row (jump or duck), which is always passable.
        spec = _fallbacks[_rng.nextInt(_fallbacks.length)];
        mask = Passability.reach(_mask, spec, window);
      }
      _place(DodgeRow(spec, z));
      _mask = mask;
      _lastRowZ = z;
    }
    var gap = speedAt(z) * (1.25 - 0.45 * difficultyAt(z));
    if (_rng.nextDouble() < 0.12) gap *= 1.6;
    final lanes = [
      for (var l = 0; l < laneCount; l++)
        if (_mask & (1 << l) != 0) l,
    ];
    var pickupLane = -1;
    final pickupZ = z + gap / 2;
    if (pickupZ >= _nextPickupZ) {
      pickupLane = lanes[_rng.nextInt(lanes.length)];
      pickups.add(
        Pickup(PickupKind.values[_rng.nextInt(PickupKind.values.length)], pickupLane.toDouble(), pickupZ),
      );
      _nextPickupZ = pickupZ + 260 + _rng.nextDouble() * 220;
    }
    if (_rng.nextDouble() < 0.65) {
      final lane = lanes[_rng.nextInt(lanes.length)];
      final count = ((gap - 6) / 2.2).floor().clamp(0, 6);
      for (var i = 0; i < count; i++) {
        final cz = z + 3 + i * 2.2;
        if (lane == pickupLane && (cz - pickupZ).abs() < 1.5) continue;
        coinItems.add(Coin(lane.toDouble(), cz));
      }
    }
    _nextZ = z + gap;
  }

  void _place(DodgeRow row) {
    generatedRows++;
    if (recordRows) rowLog.add(row);
    var i = rows.length;
    while (i > 0 && rows[i - 1].z > row.z) {
      i--;
    }
    rows.insert(i, row);
    final s = row.spec;
    for (var l = 0; l < laneCount; l++) {
      if (s.cells[l] != Cell.empty) obstacles.add(Obstacle(s.cells[l], l.toDouble(), l, row.z));
    }
    if (s.hasMover) {
      obstacles.add(Obstacle(Cell.block, s.moverFrom.toDouble(), s.moverTo, row.z, mover: true));
    }
  }

  // ---------------------------------------------------------------- advice (validator-driven)
  /// Plans through every visible row (backwards, with [Passability]) and
  /// returns the lane to hold for the nearest row, plus the action it needs.
  DodgeAdvice advise() {
    if (rows.isEmpty) return DodgeAdvice(targetLane, DodgeAction.none, null);
    final n = rows.length;
    final good = List<int>.filled(n, 0);
    good[n - 1] = Passability.safeMask(rows[n - 1].spec);
    for (var i = n - 2; i >= 0; i--) {
      final steps = Passability.stepsFor(Passability.windowBetween(rows[i].z, rows[i + 1].z));
      good[i] = Passability.safeMask(rows[i].spec) & Passability.spread(good[i + 1], steps);
    }
    var mask = good[0] != 0 ? good[0] : Passability.safeMask(rows[0].spec);
    if (mask == 0) mask = 1 << targetLane;
    var best = targetLane;
    var bestD = double.infinity;
    for (var l = 0; l < laneCount; l++) {
      if (mask & (1 << l) == 0) continue;
      final d = (l - x).abs() + (l == targetLane ? -0.01 : 0);
      if (d < bestD) {
        bestD = d;
        best = l;
      }
    }
    final action = Passability.actionFor(rows[0].spec.finalCell(best)) ?? DodgeAction.none;
    return DodgeAdvice(best, action, rows[0].z);
  }

  // ---------------------------------------------------------------- debug helpers
  /// Places a row (see [RowSpec.parse]) with its near edge [ahead] metres in
  /// front of the craft's nose.
  DodgeRow injectRow(String code, {double ahead = 20}) {
    final row = DodgeRow(RowSpec.parse(code), distance + halfLength + ahead);
    _place(row);
    return row;
  }

  void injectCoin(int lane, {double ahead = 10}) => coinItems.add(Coin(lane.toDouble(), distance + ahead));

  void injectPickup(PickupKind kind, int lane, {double ahead = 10}) =>
      pickups.add(Pickup(kind, lane.toDouble(), distance + ahead));

  /// Runs the generator out to track distance [z] without simulating.
  void debugGenerateTo(double z) => _generateUntil(z);

  /// Removes everything generated ahead (obstacles, rows, coins, pickups).
  void debugClear() {
    obstacles.clear();
    rows.clear();
    coinItems.clear();
    pickups.clear();
  }
}
