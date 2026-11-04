import 'dart:math' as math;

/// One horizontal mine shaft: a miner digs ore into the crate by the elevator.
class DigShaft {
  DigShaft(this.index);

  /// Depth index (0 = the shallowest shaft).
  final int index;
  int level = 1;
  bool manager = false;

  /// Ore waiting in the crate next to the elevator.
  double crate = 0;

  /// Whether a work cycle is running and how far into it (seconds).
  bool working = false;
  double cycle = 0;
}

/// Result of [DigWorld.applyOffline].
class OfflineReport {
  const OfflineReport({required this.seconds, required this.cash, required this.capped});

  /// Seconds of away time that were simulated (after the cap).
  final double seconds;

  /// Cash earned while away.
  final double cash;

  /// Whether the away time was longer than [DigWorld.offlineCap].
  final bool capped;
}

/// Phases of the elevator and hauler round trips.
enum TripPhase { idle, out, back }

/// Pure rules for Deep Dig, an idle mining manager.
///
/// Ore flows shaft crate -> elevator -> surface stock -> hauler -> cash.
/// Every station runs a work cycle; without a manager a cycle only starts when
/// the player taps the station ("tap to work"), with a manager cycles repeat on
/// their own and also earn while the player is away ([applyOffline]).
///
/// Everything is time-driven through [update] and fully deterministic.
class DigWorld {
  DigWorld({this.contract = 1}) : cash = startCash {
    shafts.add(DigShaft(0));
  }

  // ------------------------------------------------------------ constants
  /// Station id of the shared elevator. Shafts use their depth index (0..).
  static const int elevatorId = -1;

  /// Station id of the surface hauler.
  static const int haulerId = -2;

  static const int maxShafts = 10;
  static const int maxLevel = 800;
  static const double startCash = 25;
  static const double growth = 1.15;
  static const double shaftCycleTime = 3;
  static const Duration offlineCap = Duration(hours: 2);

  /// Seconds of production a shaft crate can hold.
  static const double crateSeconds = 20;

  /// Cash milestone of contract [c] (1-based): $1M, $10M, $100M, ...
  static double contractTargetFor(int c) => 1e6 * math.pow(10, math.max(0, c - 1)).toDouble();

  // ---------------------------------------------------------------- state
  final List<DigShaft> shafts = [];

  double cash;

  /// Cash earned during the current contract (the run score).
  double contractEarned = 0;

  /// Cash earned over the whole save.
  double totalEarned = 0;

  /// Current contract number (1-based).
  int contract;

  double time = 0;

  int elevatorLevel = 1;
  bool elevatorManager = false;
  TripPhase elevatorPhase = TripPhase.idle;

  /// 0 = surface stop, k + 1 = level of shaft k.
  double elevatorPos = 0;
  int elevatorNextStop = 0;
  double elevatorLoad = 0;

  int haulerLevel = 1;
  bool haulerManager = false;
  TripPhase haulerPhase = TripPhase.idle;

  /// 0 = at the elevator bin, 1 = at the warehouse.
  double haulerPos = 0;
  double haulerLoad = 0;

  /// Ore delivered to the surface, waiting for the hauler.
  double surfaceStock = 0;

  /// Event counters for the renderer (sounds, floaters).
  int sales = 0;
  double lastSale = 0;
  int elevatorTrips = 0;

  final List<double> _buckets = List<double>.filled(10, 0);
  int _bucketsFilled = 0;
  double _bucketTime = 0;
  double _bucketCash = 0;

  // ------------------------------------------------------------- derived
  int get shaftCount => shafts.length;
  double get contractTarget => contractTargetFor(contract);
  double get contractProgress => (contractEarned / contractTarget).clamp(0.0, 1.0);
  bool get won => contractEarned >= contractTarget;
  bool get isOver => won;

  /// Run score: cash earned toward the current contract.
  int get score => math.min(contractEarned, 9e15).floor();

  /// Live entities: miners, managers, elevator cage, hauler.
  int get entityCount =>
      shafts.length +
      2 +
      shafts.where((s) => s.manager).length +
      (elevatorManager ? 1 : 0) +
      (haulerManager ? 1 : 0);

  /// Cash earned per second, averaged over the last few seconds.
  double get incomePerSecond {
    if (_bucketsFilled == 0) return 0;
    var sum = 0.0;
    for (var i = 0; i < _bucketsFilled; i++) {
      sum += _buckets[i];
    }
    return sum / _bucketsFilled;
  }

  bool isShaft(int id) => id >= 0 && id < shafts.length;

  // Shafts -------------------------------------------------------------
  static double shaftBaseRate(int i) => math.pow(6, i).toDouble();

  /// Ore per second of shaft [i] at [level] (doubles at every 25th level).
  static double shaftRateAt(int i, int level) =>
      shaftBaseRate(i) * level * math.pow(2, level ~/ 25).toDouble();

  double shaftRate(int i) => shaftRateAt(i, shafts[i].level);
  double shaftStorage(int i) => shaftRate(i) * crateSeconds;
  double shaftProgress(int i) => shafts[i].working ? (shafts[i].cycle / shaftCycleTime).clamp(0.0, 1.0) : 0;
  double get totalShaftRate =>
      [for (var i = 0; i < shafts.length; i++) shaftRate(i)].fold(0.0, (a, b) => a + b);

  // Elevator -----------------------------------------------------------
  static double elevatorCapacityAt(int level) => 10 * level * math.pow(1.09, level - 1).toDouble();

  /// Rows travelled per second.
  static double elevatorSpeedAt(int level) => math.min(6.0, 1.5 + 0.06 * (level - 1));

  double get elevatorCapacity => elevatorCapacityAt(elevatorLevel);
  double get elevatorSpeed => elevatorSpeedAt(elevatorLevel);

  /// Best-case ore per second the elevator can lift with the current depth.
  double get elevatorThroughput => elevatorCapacity / (2 * shafts.length / elevatorSpeed);

  // Hauler -------------------------------------------------------------
  static double haulerCapacityAt(int level) => 10 * level * math.pow(1.09, level - 1).toDouble();

  /// Seconds for one leg of the bin <-> warehouse walk.
  static double haulerWalkAt(int level) => math.max(0.5, 2.0 / (1 + 0.05 * (level - 1)));

  double get haulerCapacity => haulerCapacityAt(haulerLevel);
  double get haulerWalk => haulerWalkAt(haulerLevel);
  double get haulerThroughput => haulerCapacity / (2 * haulerWalk);

  /// Ore -> cash price (1:1).
  static const double oreValue = 1;

  /// Cash per second the managed (automated) part of the mine makes on its own.
  double get idleIncomePerSecond {
    if (!elevatorManager || !haulerManager) return 0;
    var p = 0.0;
    for (var i = 0; i < shafts.length; i++) {
      if (shafts[i].manager) p += shaftRate(i);
    }
    return math.min(p, math.min(elevatorThroughput, haulerThroughput)) * oreValue;
  }

  // ------------------------------------------------------------ economy
  double _baseUpgradeCost(int id) {
    if (id == elevatorId || id == haulerId) return 40;
    return 10 * math.pow(9, id).toDouble();
  }

  int levelOf(int id) {
    if (id == elevatorId) return elevatorLevel;
    if (id == haulerId) return haulerLevel;
    return shafts[id].level;
  }

  void _setLevel(int id, int level) {
    if (id == elevatorId) {
      elevatorLevel = level;
    } else if (id == haulerId) {
      haulerLevel = level;
    } else {
      shafts[id].level = level;
    }
  }

  bool isStation(int id) => id == elevatorId || id == haulerId || isShaft(id);

  /// Price of the next [count] levels of station [id] (base * 1.15^level series).
  double upgradeCost(int id, [int count = 1]) {
    if (count <= 0) return 0;
    final first = _baseUpgradeCost(id) * math.pow(growth, levelOf(id) - 1);
    return first * (math.pow(growth, count) - 1) / (growth - 1);
  }

  /// How many levels of [id] the current cash can buy at once.
  int affordableLevels(int id) {
    final room = maxLevel - levelOf(id);
    if (room <= 0) return 0;
    final first = _baseUpgradeCost(id) * math.pow(growth, levelOf(id) - 1);
    var n = (math.log(cash * (growth - 1) / first + 1) / math.log(growth)).floor();
    n = n.clamp(0, room);
    // Guard against floating point at the boundary.
    while (n > 0 && upgradeCost(id, n) > cash) {
      n--;
    }
    return n;
  }

  /// Buys [count] levels of station [id]. Returns the number of levels bought
  /// (0 if unaffordable or invalid).
  int upgrade(int id, [int count = 1]) {
    if (!isStation(id) || count <= 0) return 0;
    final n = math.min(count, maxLevel - levelOf(id));
    if (n <= 0) return 0;
    final cost = upgradeCost(id, n);
    if (cost > cash) return 0;
    cash -= cost;
    _setLevel(id, levelOf(id) + n);
    return n;
  }

  bool managerOf(int id) {
    if (id == elevatorId) return elevatorManager;
    if (id == haulerId) return haulerManager;
    return isShaft(id) && shafts[id].manager;
  }

  double managerCost(int id) {
    if (id == elevatorId || id == haulerId) return 150;
    return 100 * math.pow(12, id).toDouble();
  }

  /// Hires the manager of station [id] so it works on its own.
  bool hireManager(int id) {
    if (!isStation(id) || managerOf(id)) return false;
    final cost = managerCost(id);
    if (cost > cash) return false;
    cash -= cost;
    if (id == elevatorId) {
      elevatorManager = true;
    } else if (id == haulerId) {
      haulerManager = true;
    } else {
      shafts[id].manager = true;
    }
    return true;
  }

  bool get canDigDeeper => shafts.length < maxShafts;

  /// Price of the next shaft (infinite when the mine is at bedrock).
  double get unlockCost => canDigDeeper ? 500 * math.pow(25, shafts.length - 1).toDouble() : double.infinity;

  /// Opens a new, deeper shaft.
  bool unlockShaft() {
    if (!canDigDeeper || unlockCost > cash) return false;
    cash -= unlockCost;
    shafts.add(DigShaft(shafts.length));
    return true;
  }

  // ---------------------------------------------------------------- work
  bool isWorking(int id) {
    if (id == elevatorId) return elevatorPhase != TripPhase.idle;
    if (id == haulerId) return haulerPhase != TripPhase.idle;
    return isShaft(id) && shafts[id].working;
  }

  bool get _hasCrateOre => shafts.any((s) => s.crate > 1e-6);

  /// "Tap to work": starts exactly one cycle of an idle, unmanaged station.
  /// Returns false if it is managed, already busy, or has nothing to move.
  bool tapStation(int id) {
    if (!isStation(id) || managerOf(id) || isWorking(id)) return false;
    if (id == elevatorId) {
      if (!_hasCrateOre && !shafts.any((s) => s.working)) return false;
      _startElevator();
    } else if (id == haulerId) {
      if (surfaceStock <= 1e-6) return false;
      _startHauler();
    } else {
      shafts[id]
        ..working = true
        ..cycle = 0;
    }
    return true;
  }

  void _startElevator() {
    elevatorPhase = TripPhase.out;
    elevatorNextStop = 0;
    elevatorLoad = 0;
  }

  void _startHauler() {
    haulerLoad = math.min(surfaceStock, haulerCapacity);
    surfaceStock -= haulerLoad;
    haulerPhase = TripPhase.out;
  }

  void update(double dt) {
    if (dt <= 0) return;
    time += dt;
    _updateShafts(dt);
    _updateElevator(dt);
    _updateHauler(dt);
    _bucketTime += dt;
    while (_bucketTime >= 1) {
      _bucketTime -= 1;
      for (var i = _buckets.length - 1; i > 0; i--) {
        _buckets[i] = _buckets[i - 1];
      }
      _buckets[0] = _bucketCash;
      _bucketCash = 0;
      if (_bucketsFilled < _buckets.length) _bucketsFilled++;
    }
  }

  void _updateShafts(double dt) {
    for (var i = 0; i < shafts.length; i++) {
      final s = shafts[i];
      if (!s.working) {
        if (!s.manager) continue;
        s
          ..working = true
          ..cycle = 0;
      }
      var active = dt;
      s.cycle += dt;
      if (s.cycle >= shaftCycleTime) {
        if (s.manager) {
          s.cycle %= shaftCycleTime;
        } else {
          active = dt - (s.cycle - shaftCycleTime);
          s
            ..working = false
            ..cycle = 0;
        }
      }
      s.crate = math.min(shaftStorage(i), s.crate + shaftRate(i) * active);
    }
  }

  void _updateElevator(double dt) {
    var rem = dt;
    final speed = elevatorSpeed;
    while (rem > 1e-12) {
      if (elevatorPhase == TripPhase.idle) {
        if (elevatorManager && _hasCrateOre) {
          _startElevator();
        } else {
          return;
        }
      }
      if (elevatorPhase == TripPhase.out) {
        final target = elevatorNextStop + 1.0;
        final need = (target - elevatorPos) / speed;
        if (rem >= need) {
          rem -= need;
          elevatorPos = target;
          final s = shafts[elevatorNextStop];
          final take = math.min(s.crate, elevatorCapacity - elevatorLoad);
          s.crate -= take;
          elevatorLoad += take;
          final full = elevatorLoad >= elevatorCapacity - 1e-9;
          if (full || elevatorNextStop >= shafts.length - 1) {
            elevatorPhase = TripPhase.back;
          } else {
            elevatorNextStop++;
          }
        } else {
          elevatorPos += rem * speed;
          rem = 0;
        }
      } else {
        final need = elevatorPos / speed;
        if (rem >= need) {
          rem -= need;
          elevatorPos = 0;
          surfaceStock += elevatorLoad;
          elevatorLoad = 0;
          elevatorPhase = TripPhase.idle;
          elevatorTrips++;
        } else {
          elevatorPos -= rem * speed;
          rem = 0;
        }
      }
    }
  }

  void _updateHauler(double dt) {
    var rem = dt;
    final walk = haulerWalk;
    while (rem > 1e-12) {
      if (haulerPhase == TripPhase.idle) {
        if (haulerManager && surfaceStock > 1e-6) {
          _startHauler();
        } else {
          return;
        }
      }
      if (haulerPhase == TripPhase.out) {
        final need = (1 - haulerPos) * walk;
        if (rem >= need) {
          rem -= need;
          haulerPos = 1;
          _sell(haulerLoad);
          haulerLoad = 0;
          haulerPhase = TripPhase.back;
        } else {
          haulerPos += rem / walk;
          rem = 0;
        }
      } else {
        final need = haulerPos * walk;
        if (rem >= need) {
          rem -= need;
          haulerPos = 0;
          haulerPhase = TripPhase.idle;
        } else {
          haulerPos -= rem / walk;
          rem = 0;
        }
      }
    }
  }

  void _sell(double ore) {
    final earned = ore * oreValue;
    if (earned <= 0) return;
    _earn(earned);
    sales++;
    lastSale = earned;
    _bucketCash += earned;
  }

  void _earn(double amount) {
    cash += amount;
    contractEarned += amount;
    totalEarned += amount;
  }

  /// Starts the next, bigger contract after a win. The mine itself is kept.
  void advanceContract() {
    contract++;
    contractEarned = 0;
  }

  // ------------------------------------------------------------- offline
  /// Grants the earnings of automated stations for [away] (capped at
  /// [offlineCap]). Unmanaged stations do nothing while the player is away.
  OfflineReport applyOffline(Duration away) {
    final capped = away > offlineCap;
    final t = (capped ? offlineCap : away).inMilliseconds / 1000.0;
    if (t <= 0) return const OfflineReport(seconds: 0, cash: 0, capped: false);
    final produced = [for (var i = 0; i < shafts.length; i++) shafts[i].manager ? shaftRate(i) * t : 0.0];
    final weights = [for (var i = 0; i < shafts.length; i++) shafts[i].crate + produced[i]];
    final available = weights.fold(0.0, (a, b) => a + b);
    final moved = elevatorManager ? math.min(available, elevatorThroughput * t) : 0.0;
    if (available > 0) {
      final keep = (available - moved) / available;
      for (var i = 0; i < shafts.length; i++) {
        shafts[i].crate = math.min(shaftStorage(i), weights[i] * keep);
      }
    }
    final atSurface = surfaceStock + moved;
    final sold = haulerManager ? math.min(atSurface, haulerThroughput * t) : 0.0;
    surfaceStock = atSurface - sold;
    final earned = sold * oreValue;
    if (earned > 0) _earn(earned);
    return OfflineReport(seconds: t, cash: earned, capped: capped);
  }

  // ---------------------------------------------------------------- save
  Map<String, Object?> toJson() => {
    'v': 1,
    'cash': _finite(cash),
    'earned': _finite(contractEarned),
    'total': _finite(totalEarned),
    'contract': contract,
    'time': _finite(time),
    'stock': _finite(surfaceStock),
    'shafts': [
      for (final s in shafts)
        {'l': s.level, 'm': s.manager, 'c': _finite(s.crate), 'w': s.working, 't': _finite(s.cycle)},
    ],
    'elev': {
      'l': elevatorLevel,
      'm': elevatorManager,
      'p': elevatorPhase.index,
      'y': _finite(elevatorPos),
      'n': elevatorNextStop,
      'o': _finite(elevatorLoad),
    },
    'haul': {
      'l': haulerLevel,
      'm': haulerManager,
      'p': haulerPhase.index,
      'x': _finite(haulerPos),
      'o': _finite(haulerLoad),
    },
  };

  /// Restores a world from [toJson] output, tolerating missing or corrupt
  /// fields by falling back to a fresh mine.
  factory DigWorld.fromJson(Map<String, Object?>? json) {
    final w = DigWorld();
    if (json == null) return w;
    try {
      double d(Object? v, [double f = 0]) => v is num && v.isFinite ? v.toDouble() : f;
      int n(Object? v, int f, int lo, int hi) => v is num ? v.toInt().clamp(lo, hi) : f;
      bool b(Object? v) => v == true;
      TripPhase phase(Object? v) => TripPhase.values[n(v, 0, 0, TripPhase.values.length - 1)];
      w
        ..cash = math.max(0, d(json['cash'], startCash))
        ..contractEarned = math.max(0, d(json['earned']))
        ..totalEarned = math.max(0, d(json['total']))
        ..contract = n(json['contract'], 1, 1, 99)
        ..time = d(json['time'])
        ..surfaceStock = math.max(0, d(json['stock']));
      final list = json['shafts'];
      if (list is List && list.isNotEmpty) {
        w.shafts.clear();
        for (final raw in list.take(maxShafts)) {
          final m = raw is Map ? raw : const {};
          w.shafts.add(
            DigShaft(w.shafts.length)
              ..level = n(m['l'], 1, 1, maxLevel)
              ..manager = b(m['m'])
              ..crate = math.max(0, d(m['c']))
              ..working = b(m['w'])
              ..cycle = d(m['t']).clamp(0.0, shaftCycleTime),
          );
        }
      }
      final e = json['elev'];
      if (e is Map) {
        w
          ..elevatorLevel = n(e['l'], 1, 1, maxLevel)
          ..elevatorManager = b(e['m'])
          ..elevatorPhase = phase(e['p'])
          ..elevatorPos = d(e['y']).clamp(0.0, w.shafts.length.toDouble())
          ..elevatorNextStop = n(e['n'], 0, 0, w.shafts.length - 1)
          ..elevatorLoad = math.max(0, d(e['o']));
      }
      final h = json['haul'];
      if (h is Map) {
        w
          ..haulerLevel = n(h['l'], 1, 1, maxLevel)
          ..haulerManager = b(h['m'])
          ..haulerPhase = phase(h['p'])
          ..haulerPos = d(h['x']).clamp(0.0, 1.0)
          ..haulerLoad = math.max(0, d(h['o']));
      }
      return w;
    } on Object {
      return DigWorld();
    }
  }

  static double _finite(double v) => v.isFinite ? v : 0;
}

const List<String> _suffixes = ['', 'K', 'M', 'B', 'T', 'Qa', 'Qi', 'Sx', 'Sp', 'Oc', 'No', 'Dc'];

/// Short number formatting for idle-game HUDs: 950, 1.23K, 45.6M, 789B ...
/// Values are truncated (never rounded up) to three significant digits.
String shortNumber(double v) {
  if (v.isNaN) return '0';
  if (v < 0) return '-${shortNumber(-v)}';
  if (v.isInfinite) return 'inf';
  if (v < 1000) return v.floor().toString();
  var tier = 0;
  var x = v;
  while (x >= 1000 && tier < _suffixes.length - 1) {
    x /= 1000;
    tier++;
  }
  if (x >= 1000) {
    final e = (math.log(v) / math.ln10).floor();
    final m = (v / math.pow(10, e) * 10 + 1e-9).floor() / 10;
    return '${m.toStringAsFixed(1)}e$e';
  }
  final digits = x >= 100 ? 0 : (x >= 10 ? 1 : 2);
  final scale = math.pow(10, digits);
  final t = (x * scale + 1e-6).floor() / scale;
  var s = t.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return '$s${_suffixes[tier]}';
}

/// Cash with a dollar sign: `$1.5K`.
String formatCash(double v) => v < 0 ? '-\$${shortNumber(-v)}' : '\$${shortNumber(v)}';
