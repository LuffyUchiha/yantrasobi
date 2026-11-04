import 'dart:math' as math;

/// Arena rules: [classic] walls kill and levels have goals; [wrap] edges wrap
/// around and the run is an endless score attack.
enum SerpentMode { classic, wrap }

enum SerpentDir { up, right, down, left }

extension SerpentDirX on SerpentDir {
  int get dx => switch (this) {
    SerpentDir.left => -1,
    SerpentDir.right => 1,
    _ => 0,
  };

  int get dy => switch (this) {
    SerpentDir.up => -1,
    SerpentDir.down => 1,
    _ => 0,
  };

  SerpentDir get opposite => SerpentDir.values[(index + 2) % 4];
}

enum FoodKind { apple, golden, berry, phase }

enum DeathCause { wall, self, obstacle }

class SerpentFood {
  SerpentFood(this.kind, this.cell, this.life) : maxLife = life;

  final FoodKind kind;
  final int cell;

  /// Seconds left before the food vanishes; negative means it never expires.
  double life;
  final double maxLife;

  bool get expires => maxLife > 0;
}

enum SerpentEventKind { ate, expired, died, cleared, phaseEnded }

class SerpentEvent {
  const SerpentEvent(this.kind, this.cell, {this.food, this.cause});

  final SerpentEventKind kind;
  final int cell;
  final FoodKind? food;
  final DeathCause? cause;
}

/// Pure, deterministic rules for Serpent Loop.
///
/// The snake moves one cell per tick. Time advances in fixed sub-steps of
/// [simStep], so a run depends only on the seed and the input sequence.
class SerpentWorld {
  SerpentWorld({
    int seed = 1,
    this.mode = SerpentMode.classic,
    this.level = 1,
    this.spawnFood = true,
    bool obstacles = true,
  }) : _rng = math.Random(seed),
       _occ = List<int>.filled(cols * rows, 0),
       _blocked = List<bool>.filled(cols * rows, false) {
    if (mode == SerpentMode.classic && obstacles) {
      for (final c in obstacleLayout(level)) {
        _blocked[c] = true;
        obstacleCells.add(c);
      }
    }
    final hx = cols ~/ 2, hy = startRow;
    for (var i = 0; i < startLength; i++) {
      final c = cellOf(hx, hy + i);
      body.add(c);
      _occ[c]++;
    }
    prevTail = body.last;
    if (spawnFood) _ensureApple();
  }

  static const int cols = 20;
  static const int rows = 32;
  static const int startRow = 20;
  static const int startLength = 3;
  static const int minLength = 3;
  static const int maxQueuedTurns = 2;
  static const double simStep = 1 / 120;
  static const double minInterval = 0.07;
  static const double intervalPerCell = 0.0035;
  static const double goldenLife = 6;
  static const double berryLife = 12;
  static const double phasePickupLife = 10;
  static const double phaseDuration = 5;

  static const int applePoints = 10;
  static const int goldenPoints = 50;
  static const int berryPoints = 5;
  static const int phasePoints = 15;

  /// Length needed to clear a Classic level.
  static int goalForLevel(int level) => math.min(10 + 3 * (level - 1), 46);

  /// Tick interval at the start length; Classic levels start a little faster.
  static double baseIntervalFor(SerpentMode mode, int level) =>
      mode == SerpentMode.wrap ? 0.15 : 0.17 - 0.006 * (math.min(level, 10) - 1);

  static int clearBonusFor(int level) => 100 * level;

  final SerpentMode mode;
  final int level;
  final bool spawnFood;
  final math.Random _rng;

  /// Snake cells, head first.
  final List<int> body = [];

  /// Number of snake segments on each cell (more than one only while phasing).
  final List<int> _occ;
  final List<bool> _blocked;
  final List<int> obstacleCells = [];
  final List<SerpentFood> foods = [];
  final List<SerpentDir> _queue = [];

  /// Events produced since the start of the last [update] call.
  final List<SerpentEvent> events = [];

  /// Log of every food spawn as `kind@cell`, for determinism checks.
  final List<String> spawnLog = [];

  SerpentDir dir = SerpentDir.up;

  /// The tail cell before the last tick, for interpolated rendering.
  int prevTail = 0;
  int pendingGrowth = 0;
  double phaseTimer = 0;
  double time = 0;
  int ticks = 0;
  int score = 0;
  bool dead = false;
  bool cleared = false;
  DeathCause? cause;
  int apples = 0, goldens = 0, berries = 0, phases = 0;
  int maxLength = startLength;

  double _acc = 0;
  double _tickAcc = 0;

  // ---------------------------------------------------------------- queries
  bool get isOver => dead || cleared;

  /// Classic: true on clear, false on death. Wrap is endless: always null.
  bool? get won {
    if (mode == SerpentMode.wrap) return null;
    if (cleared) return true;
    if (dead) return false;
    return null;
  }

  int get length => body.length;
  int get head => body.first;
  int get goal => mode == SerpentMode.classic ? goalForLevel(level) : 0;
  bool get phasing => phaseTimer > 0;
  int get entityCount => body.length + foods.length + obstacleCells.length;
  List<SerpentDir> get queuedTurns => List.unmodifiable(_queue);

  double get tickInterval => math.max(
    minInterval,
    baseIntervalFor(mode, level) - intervalPerCell * math.max(0, body.length - startLength),
  );

  /// Progress from the previous tick to the next, in [0, 1] (1 before the
  /// first tick, so the snake starts fully drawn).
  double get alpha => isOver || ticks == 0 ? 1 : (_tickAcc / tickInterval).clamp(0.0, 1.0);

  static int cellOf(int x, int y) => y * cols + x;
  static int cellX(int c) => c % cols;
  static int cellY(int c) => c ~/ cols;

  bool isObstacle(int cell) => _blocked[cell];
  int occupancy(int cell) => _occ[cell];

  SerpentFood? foodAt(int cell) {
    for (final f in foods) {
      if (f.cell == cell) return f;
    }
    return null;
  }

  SerpentFood? foodOf(FoodKind kind) {
    for (final f in foods) {
      if (f.kind == kind) return f;
    }
    return null;
  }

  /// The cell one step from [cell] in [d], or -1 when that step leaves a
  /// Classic arena.
  int neighbor(int cell, SerpentDir d) {
    var x = cellX(cell) + d.dx;
    var y = cellY(cell) + d.dy;
    if (mode == SerpentMode.wrap) {
      x = (x + cols) % cols;
      y = (y + rows) % rows;
    } else if (x < 0 || y < 0 || x >= cols || y >= rows) {
      return -1;
    }
    return cellOf(x, y);
  }

  // ---------------------------------------------------------------- input
  /// Queues a turn. Turns that repeat or reverse the last queued heading are
  /// ignored, and at most [maxQueuedTurns] wait for the next ticks.
  bool turn(SerpentDir d) {
    if (isOver) return false;
    final ref = _queue.isNotEmpty ? _queue.last : dir;
    if (d == ref || d == ref.opposite) return false;
    if (_queue.length >= maxQueuedTurns) return false;
    _queue.add(d);
    return true;
  }

  // ---------------------------------------------------------------- update
  void update(double dt) {
    events.clear();
    if (isOver) return;
    _acc += math.min(dt, 0.25);
    while (_acc >= simStep && !isOver) {
      _acc -= simStep;
      _subStep(simStep);
    }
  }

  void _subStep(double h) {
    time += h;
    if (phaseTimer > 0) {
      phaseTimer -= h;
      if (phaseTimer <= 0) {
        phaseTimer = 0;
        events.add(SerpentEvent(SerpentEventKind.phaseEnded, head));
      }
    }
    for (var i = foods.length - 1; i >= 0; i--) {
      final f = foods[i];
      if (!f.expires) continue;
      f.life -= h;
      if (f.life <= 0) {
        foods.removeAt(i);
        events.add(SerpentEvent(SerpentEventKind.expired, f.cell, food: f.kind));
      }
    }
    _tickAcc += h;
    final interval = tickInterval;
    if (_tickAcc >= interval) {
      _tickAcc -= interval;
      tick();
    }
  }

  /// Advances the snake by one cell immediately (also used by tests).
  void tick() {
    if (isOver) return;
    ticks++;
    if (_queue.isNotEmpty) dir = _queue.removeAt(0);
    final from = head;
    final next = neighbor(from, dir);
    if (next < 0) return _die(DeathCause.wall, from);
    if (_blocked[next]) return _die(DeathCause.obstacle, next);
    final tail = body.last;
    final tailMoves = pendingGrowth == 0;
    if (!phasing) {
      var occ = _occ[next];
      if (tailMoves && next == tail) occ--;
      if (occ > 0) return _die(DeathCause.self, next);
    }
    body.insert(0, next);
    _occ[next]++;
    if (tailMoves) {
      body.removeLast();
      _occ[tail]--;
    } else {
      pendingGrowth--;
    }
    prevTail = tail;
    final food = foodAt(next);
    if (food != null) _eat(food);
    maxLength = math.max(maxLength, body.length);
    if (mode == SerpentMode.classic && body.length >= goal) {
      cleared = true;
      score += clearBonusFor(level);
      events.add(SerpentEvent(SerpentEventKind.cleared, head));
    }
  }

  void _die(DeathCause c, int cell) {
    dead = true;
    cause = c;
    _queue.clear();
    events.add(SerpentEvent(SerpentEventKind.died, cell, cause: c));
  }

  void _eat(SerpentFood f) {
    foods.remove(f);
    events.add(SerpentEvent(SerpentEventKind.ate, f.cell, food: f.kind));
    switch (f.kind) {
      case FoodKind.apple:
        apples++;
        score += applePoints;
        pendingGrowth += 1;
        if (spawnFood) {
          _ensureApple();
          _rollSpecials();
        }
      case FoodKind.golden:
        goldens++;
        score += goldenPoints;
        pendingGrowth += 3;
      case FoodKind.berry:
        berries++;
        score += berryPoints;
        _shrink(2);
      case FoodKind.phase:
        phases++;
        score += phasePoints;
        phaseTimer = phaseDuration;
    }
  }

  void _shrink(int n) {
    while (n > 0 && pendingGrowth > 0) {
      pendingGrowth--;
      n--;
    }
    while (n > 0 && body.length > minLength) {
      final t = body.removeLast();
      _occ[t]--;
      n--;
    }
    prevTail = body.last;
  }

  void _ensureApple() {
    if (foodOf(FoodKind.apple) == null) _spawn(FoodKind.apple);
  }

  void _rollSpecials() {
    final g = _rng.nextDouble();
    final b = _rng.nextDouble();
    final p = _rng.nextDouble();
    if (apples >= 2 && g < 0.2 && foodOf(FoodKind.golden) == null) _spawn(FoodKind.golden);
    if (body.length >= 6 && b < 0.16 && foodOf(FoodKind.berry) == null) _spawn(FoodKind.berry);
    if (body.length >= 8 && p < 0.1 && foodOf(FoodKind.phase) == null) _spawn(FoodKind.phase);
  }

  /// Spawns [kind] on a random free cell (never on the snake, an obstacle or
  /// another food). Returns null when the arena is full.
  SerpentFood? _spawn(FoodKind kind) {
    var free = 0;
    for (var c = 0; c < cols * rows; c++) {
      if (_isFree(c)) free++;
    }
    if (free == 0) return null;
    var k = _rng.nextInt(free);
    for (var c = 0; c < cols * rows; c++) {
      if (!_isFree(c)) continue;
      if (k-- == 0) return _place(kind, c);
    }
    return null;
  }

  bool _isFree(int c) => _occ[c] == 0 && !_blocked[c] && foodAt(c) == null;

  SerpentFood _place(FoodKind kind, int cell) {
    final life = switch (kind) {
      FoodKind.apple => -1.0,
      FoodKind.golden => goldenLife,
      FoodKind.berry => berryLife,
      FoodKind.phase => phasePickupLife,
    };
    final f = SerpentFood(kind, cell, life);
    foods.add(f);
    spawnLog.add('${kind.name}@$cell');
    return f;
  }

  // ---------------------------------------------------------------- debug
  /// Places a food at (x, y), replacing anything there. Test helper.
  SerpentFood debugPlaceFood(FoodKind kind, int x, int y) {
    final c = cellOf(x, y);
    foods.removeWhere((f) => f.cell == c);
    return _place(kind, c);
  }

  void debugClearFood() => foods.clear();

  /// Replaces the snake with [cells] (head first) heading [heading].
  void debugSetSnake(List<int> cells, SerpentDir heading) {
    for (final c in body) {
      _occ[c]--;
    }
    body
      ..clear()
      ..addAll(cells);
    for (final c in body) {
      _occ[c]++;
    }
    dir = heading;
    _queue.clear();
    pendingGrowth = 0;
    prevTail = body.last;
  }

  void debugAddObstacle(int x, int y) {
    final c = cellOf(x, y);
    if (_blocked[c]) return;
    _blocked[c] = true;
    obstacleCells.add(c);
  }

  // ---------------------------------------------------------------- levels
  /// Deterministic, mirrored obstacle layout for a Classic level (none before
  /// level 3). Every free cell stays reachable and the start lane stays clear.
  static List<int> obstacleLayout(int level) {
    if (level < 3) return const [];
    final rng = math.Random(level * 7919 + 101);
    final blocked = List<bool>.filled(cols * rows, false);
    final out = <int>[];
    final pieces = math.min(2 + (level - 3), 7);
    var placed = 0;
    for (var attempt = 0; attempt < 400 && placed < pieces; attempt++) {
      final shape = rng.nextInt(4);
      final len = 3 + rng.nextInt(4);
      final x0 = 2 + rng.nextInt(cols ~/ 2 - 3);
      final y0 = 3 + rng.nextInt(rows - 7);
      final cells = <int>[];
      void add(int x, int y) {
        if (x < 2 || y < 2 || x >= cols - 2 || y >= rows - 2) return;
        cells.add(cellOf(x, y));
        cells.add(cellOf(cols - 1 - x, y));
      }

      switch (shape) {
        case 0: // horizontal bar
          for (var i = 0; i < len; i++) {
            add(x0 + i, y0);
          }
        case 1: // vertical bar
          for (var i = 0; i < len; i++) {
            add(x0, y0 + i);
          }
        case 2: // L
          for (var i = 0; i < len; i++) {
            add(x0, y0 + i);
          }
          add(x0 + 1, y0 + len - 1);
          add(x0 + 2, y0 + len - 1);
        default: // 2x2 block
          add(x0, y0);
          add(x0 + 1, y0);
          add(x0, y0 + 1);
          add(x0 + 1, y0 + 1);
      }
      if (cells.isEmpty) continue;
      var ok = true;
      for (final c in cells) {
        final x = cellX(c), y = cellY(c);
        final inStartLane = x >= cols ~/ 2 - 3 && x <= cols ~/ 2 + 2 && y >= startRow - 8;
        if (blocked[c] || inStartLane) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      for (final c in cells) {
        blocked[c] = true;
      }
      if (!_connected(blocked)) {
        for (final c in cells) {
          blocked[c] = false;
        }
        continue;
      }
      for (final c in cells) {
        if (!out.contains(c)) out.add(c);
      }
      placed++;
    }
    return out;
  }

  static bool _connected(List<bool> blocked) {
    var start = -1, free = 0;
    for (var c = 0; c < blocked.length; c++) {
      if (!blocked[c]) {
        free++;
        if (start < 0) start = c;
      }
    }
    if (start < 0) return false;
    final seen = List<bool>.filled(blocked.length, false);
    final stack = <int>[start];
    seen[start] = true;
    var count = 0;
    while (stack.isNotEmpty) {
      final c = stack.removeLast();
      count++;
      final x = cellX(c), y = cellY(c);
      for (final d in SerpentDir.values) {
        final nx = x + d.dx, ny = y + d.dy;
        if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
        final n = cellOf(nx, ny);
        if (blocked[n] || seen[n]) continue;
        seen[n] = true;
        stack.add(n);
      }
    }
    return count == free;
  }
}
