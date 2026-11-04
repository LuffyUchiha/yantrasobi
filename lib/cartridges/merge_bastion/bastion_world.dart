import 'dart:math' as math;

/// Pure-Dart rules for Merge Bastion. No Flutter/Flame imports, so every rule
/// is unit-testable and deterministic for a given seed + level (and the same
/// sequence of player actions and time steps).
///
/// Geometry is in abstract *board units* (one grid cell = 1x1):
///
/// * x runs 0..[BastionWorld.cols] left to right;
/// * the enemy lane runs from y = 0 (spawn edge) down to y = [BastionWorld.wallY];
/// * the wall occupies [BastionWorld.wallY]..[BastionWorld.gridTop];
/// * the merge grid fills [BastionWorld.gridTop]..[BastionWorld.boardHeight],
///   row 0 being the front row next to the wall.
///
/// Grid cells are addressed by a single index `row * cols + col`.

enum BastionPhase { breakTime, fighting, won, lost }

/// What a drag-and-drop did.
enum DragOutcome { merged, moved, swapped, invalid }

enum EnemyKind { grunt, runner, brute, boss }

/// Something that happened this tick, consumed by the renderer for SFX/FX.
enum BastionEventKind { shot, kill, wallHit, waveStart, waveClear, won, lost }

class BastionEvent {
  const BastionEvent(this.kind, this.x, this.y, {this.x2 = 0, this.y2 = 0, this.tier = 0, this.enemy});

  final BastionEventKind kind;
  final double x;
  final double y;

  /// Shot target (for [BastionEventKind.shot]).
  final double x2;
  final double y2;

  /// Tier of the firing / killing unit.
  final int tier;
  final EnemyKind? enemy;
}

class BastionUnit {
  BastionUnit(this.id, this.tier);

  final int id;
  int tier;

  /// Seconds until the next shot.
  double cooldown = 0;

  /// Recoil timer for the renderer (counts down from ~0.15 after a shot).
  double recoil = 0;

  /// Rises from 0 to 1 right after the unit was summoned or merged.
  double age = 0;
}

class BastionEnemy {
  BastionEnemy(this.id, this.kind);

  final int id;
  final EnemyKind kind;
  double x = 0;
  double y = 0;
  double hp = 1;
  double maxHp = 1;
  double speed = 0.5;
  double radius = 0.22;
  int wallDamage = 10;
  int coins = 2;
  int points = 5;
  double flash = 0;
  bool alive = true;
}

class BastionWorld {
  BastionWorld({required this.seed, this.level = 1, this.finalWave = 15})
    : assert(level >= 1),
      _waveRng = math.Random(seed * 6151 + level * 97),
      _summonRng = math.Random(seed * 31 + 17) {
    phase = BastionPhase.breakTime;
    breakTimer = firstBreak;
  }

  final int seed;
  final int level;
  final int finalWave;
  final math.Random _waveRng;
  final math.Random _summonRng;

  // ---------------------------------------------------------------- constants
  static const int cols = 5;
  static const int rows = 3;
  static const int cellCount = cols * rows;
  static const int maxTier = 8;
  static const double wallY = 6.5;
  static const double wallThickness = 0.4;
  static const double gridTop = wallY + wallThickness;
  static const double boardHeight = gridTop + rows;

  /// Units fire at enemies within this distance (board units).
  static const double range = 5.6;
  static const int maxWallHp = 100;
  static const int startCoins = 30;
  static const int baseSummonCost = 10;
  static const int summonCostStep = 2;
  static const double breakDuration = 3;
  static const double firstBreak = 4;

  /// Damage of one shot from a unit of [tier]: 3, 6, 12, 24, ...
  static double damageForTier(int tier) => 3.0 * (1 << (tier - 1));

  /// Seconds between shots; higher tiers fire a little faster.
  static double fireIntervalForTier(int tier) => 0.8 * math.pow(0.94, tier - 1);

  /// Number of enemies (boss included) in [wave] on [level].
  static int waveSize(int wave, [int level = 1]) {
    final extra = (level - 1) ~/ 2;
    return isBossWave(wave) ? 3 + wave ~/ 2 + extra : 5 + wave + extra;
  }

  static bool isBossWave(int wave) => wave % 5 == 0;

  // ---------------------------------------------------------------- state
  final List<BastionUnit?> grid = List<BastionUnit?>.filled(cellCount, null);
  final List<BastionEnemy> enemies = [];
  final List<BastionEvent> events = [];

  late BastionPhase phase;
  double breakTimer = 0;
  int wave = 0;
  int coins = startCoins;
  int summons = 0;
  int wallHp = maxWallHp;
  int kills = 0;
  int bossKills = 0;
  int merges = 0;
  int killPoints = 0;
  int wavesCleared = 0;
  double time = 0;

  int _toSpawn = 0;
  double _spawnTimer = 0;
  int _nextEnemyId = 0;
  int _nextUnitId = 0;

  bool get isOver => phase == BastionPhase.won || phase == BastionPhase.lost;
  bool get won => phase == BastionPhase.won;
  int get summonCost => baseSummonCost + summonCostStep * summons;
  int get unitCount => grid.where((u) => u != null).length;
  int get entityCount => unitCount + enemies.length;
  int get remainingInWave => _toSpawn + enemies.length;
  bool get hasEmptyCell => grid.any((u) => u == null);
  bool get canSummon => !isOver && hasEmptyCell && coins >= summonCost;

  /// The wave that is (or will next be) fought.
  int get displayWave => phase == BastionPhase.breakTime ? wave + 1 : wave;

  /// Kills weighted by the killing unit's tier, plus 100 per cleared wave,
  /// plus a bonus for leftover wall HP on a win.
  int get score => killPoints + wavesCleared * 100 + (won ? wallHp * 5 : 0);

  // ---------------------------------------------------------------- geometry
  static int cellIndex(int col, int row) => row * cols + col;
  static int colOf(int cell) => cell % cols;
  static int rowOf(int cell) => cell ~/ cols;
  static double cellCenterX(int cell) => colOf(cell) + 0.5;
  static double cellCenterY(int cell) => gridTop + rowOf(cell) + 0.5;

  /// Cell under the board point (x, y), or -1.
  static int cellAt(double x, double y) {
    if (x < 0 || x >= cols || y < gridTop || y >= boardHeight) return -1;
    return cellIndex(x.floor(), (y - gridTop).floor());
  }

  BastionUnit? unitAt(int cell) => cell >= 0 && cell < cellCount ? grid[cell] : null;

  // ---------------------------------------------------------------- actions
  /// Buys a tier-1 unit into a random empty cell. Returns the cell, or null
  /// when the grid is full, coins are short or the run is over.
  int? summon() {
    if (!canSummon) return null;
    final empty = [
      for (var i = 0; i < cellCount; i++)
        if (grid[i] == null) i,
    ];
    final cell = empty[_summonRng.nextInt(empty.length)];
    coins -= summonCost;
    summons++;
    grid[cell] = BastionUnit(_nextUnitId++, 1)..cooldown = 0.2;
    return cell;
  }

  /// Drops the unit at [from] onto [to]: identical tiers merge into tier+1,
  /// an empty cell is a move, a different tier swaps places.
  DragOutcome dragUnit(int from, int to) {
    if (isOver || from == to) return DragOutcome.invalid;
    if (from < 0 || from >= cellCount || to < 0 || to >= cellCount) return DragOutcome.invalid;
    final a = grid[from];
    if (a == null) return DragOutcome.invalid;
    final b = grid[to];
    if (b == null) {
      grid[to] = a;
      grid[from] = null;
      return DragOutcome.moved;
    }
    if (a.tier == b.tier) {
      if (a.tier >= maxTier) return DragOutcome.invalid;
      grid[from] = null;
      b
        ..tier += 1
        ..age = 0
        ..cooldown = math.min(b.cooldown, a.cooldown);
      merges++;
      return DragOutcome.merged;
    }
    grid[from] = b;
    grid[to] = a;
    return DragOutcome.swapped;
  }

  // ---------------------------------------------------------------- simulation
  /// Advances the simulation. Large steps are subdivided.
  void update(double dt) {
    events.clear();
    if (isOver) return;
    var remaining = math.min(dt, 0.25);
    while (remaining > 1e-9) {
      final step = math.min(remaining, 1 / 30);
      _step(step);
      remaining -= step;
      if (isOver) break;
    }
  }

  void _step(double dt) {
    time += dt;
    for (final u in grid) {
      if (u == null) continue;
      if (u.recoil > 0) u.recoil -= dt;
      if (u.age < 1) u.age = math.min(1, u.age + dt * 4);
    }
    for (final e in enemies) {
      if (e.flash > 0) e.flash -= dt;
    }
    if (phase == BastionPhase.breakTime) {
      breakTimer -= dt;
      if (breakTimer <= 0) _beginWave(wave + 1);
      return;
    }
    _spawn(dt);
    _moveEnemies(dt);
    if (wallHp <= 0) {
      wallHp = 0;
      phase = BastionPhase.lost;
      events.add(const BastionEvent(BastionEventKind.lost, cols / 2, wallY));
      return;
    }
    _fire(dt);
    enemies.removeWhere((e) => !e.alive);
    if (_toSpawn == 0 && enemies.isEmpty) {
      wavesCleared = wave;
      coins += 4 + wave;
      events.add(BastionEvent(BastionEventKind.waveClear, cols / 2, wallY / 2, tier: wave));
      if (wave >= finalWave) {
        phase = BastionPhase.won;
        events.add(const BastionEvent(BastionEventKind.won, cols / 2, wallY / 2));
      } else {
        phase = BastionPhase.breakTime;
        breakTimer = breakDuration;
      }
    }
  }

  void _beginWave(int n) {
    wave = n;
    phase = BastionPhase.fighting;
    _toSpawn = waveSize(n, level);
    _spawnTimer = 0.3;
    events.add(BastionEvent(BastionEventKind.waveStart, cols / 2, 0, tier: n));
  }

  void _spawn(double dt) {
    if (_toSpawn <= 0) return;
    _spawnTimer -= dt;
    if (_spawnTimer > 0) return;
    final boss = isBossWave(wave) && _toSpawn == 1;
    final kind = boss ? EnemyKind.boss : _pickKind();
    enemies.add(_makeEnemy(kind));
    _toSpawn--;
    _spawnTimer = boss ? 0 : math.max(0.45, 1.25 - 0.04 * wave) * (0.8 + 0.4 * _waveRng.nextDouble());
    // The boss trails the escort by a beat.
    if (isBossWave(wave) && _toSpawn == 1) _spawnTimer += 1.2;
  }

  EnemyKind _pickKind() {
    final r = _waveRng.nextDouble();
    if (wave >= 6 && r < 0.18) return EnemyKind.brute;
    if (wave >= 3 && r < 0.42) return EnemyKind.runner;
    return EnemyKind.grunt;
  }

  /// Base hit points of a grunt on [wave]; other kinds scale from this.
  double hpForWave(int wave) => 7.0 * math.pow(1.215, wave - 1) * (1 + 0.12 * (level - 1));

  BastionEnemy _makeEnemy(EnemyKind kind) {
    final e = BastionEnemy(_nextEnemyId++, kind);
    final base = hpForWave(wave);
    final speedScale = (1 + 0.025 * (wave - 1)) * (1 + 0.04 * (level - 1));
    final coinBonus = wave ~/ 3;
    switch (kind) {
      case EnemyKind.grunt:
        e
          ..maxHp = base
          ..speed = 0.42 * speedScale
          ..radius = 0.22
          ..wallDamage = 10
          ..coins = 3 + coinBonus
          ..points = 5;
      case EnemyKind.runner:
        e
          ..maxHp = base * 0.6
          ..speed = 0.7 * speedScale
          ..radius = 0.18
          ..wallDamage = 8
          ..coins = 3 + coinBonus
          ..points = 6;
      case EnemyKind.brute:
        e
          ..maxHp = base * 2.8
          ..speed = 0.3 * speedScale
          ..radius = 0.3
          ..wallDamage = 20
          ..coins = 6 + 2 * coinBonus
          ..points = 12;
      case EnemyKind.boss:
        e
          ..maxHp = base * (9 + wave * 0.6)
          ..speed = 0.24 * speedScale
          ..radius = 0.42
          ..wallDamage = 45
          ..coins = 25 + 3 * wave
          ..points = 60;
    }
    e
      ..hp = e.maxHp
      ..x = e.radius + _waveRng.nextDouble() * (cols - 2 * e.radius)
      ..y = -e.radius;
    return e;
  }

  void _moveEnemies(double dt) {
    for (final e in enemies) {
      if (!e.alive) continue;
      e.y += e.speed * dt;
      if (e.y + e.radius >= wallY) {
        e.alive = false;
        wallHp -= e.wallDamage;
        events.add(BastionEvent(BastionEventKind.wallHit, e.x, wallY, enemy: e.kind));
      }
    }
  }

  void _fire(double dt) {
    for (var cell = 0; cell < cellCount; cell++) {
      final u = grid[cell];
      if (u == null) continue;
      if (u.cooldown > 0) u.cooldown -= dt;
      if (u.cooldown > 0) continue;
      final ux = cellCenterX(cell);
      final uy = cellCenterY(cell);
      final target = _nearestInRange(ux, uy);
      if (target == null) {
        u.cooldown = 0;
        continue;
      }
      u.cooldown += fireIntervalForTier(u.tier);
      u.recoil = 0.15;
      target.hp -= damageForTier(u.tier);
      target.flash = 0.08;
      events.add(BastionEvent(BastionEventKind.shot, ux, uy, x2: target.x, y2: target.y, tier: u.tier));
      if (target.hp <= 0) {
        target.alive = false;
        kills++;
        if (target.kind == EnemyKind.boss) bossKills++;
        coins += target.coins;
        killPoints += target.points * u.tier;
        events.add(BastionEvent(BastionEventKind.kill, target.x, target.y, tier: u.tier, enemy: target.kind));
      }
    }
  }

  BastionEnemy? _nearestInRange(double x, double y) {
    BastionEnemy? best;
    var bestD = range * range;
    for (final e in enemies) {
      if (!e.alive || e.y < 0) continue;
      final dx = e.x - x, dy = e.y - y;
      final d = dx * dx + dy * dy;
      if (d <= bestD) {
        bestD = d;
        best = e;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- debug helpers
  /// Places (or clears, with tier 0) a unit directly. For tests and tools.
  void debugSetUnit(int cell, int tier) {
    grid[cell] = tier <= 0 ? null : BastionUnit(_nextUnitId++, tier.clamp(1, maxTier));
  }

  /// Spawns an enemy at (x, y) right now, starting a wave if needed.
  BastionEnemy debugSpawnEnemy({
    double x = cols / 2,
    double y = 0,
    double hp = 5,
    double speed = 0.5,
    int wallDamage = 10,
    int coins = 3,
    EnemyKind kind = EnemyKind.grunt,
  }) {
    if (phase == BastionPhase.breakTime) {
      wave = math.max(1, wave + 1);
      phase = BastionPhase.fighting;
      _toSpawn = 0;
    }
    final e = BastionEnemy(_nextEnemyId++, kind)
      ..x = x
      ..y = y
      ..hp = hp
      ..maxHp = hp
      ..speed = speed
      ..wallDamage = wallDamage
      ..coins = coins;
    enemies.add(e);
    return e;
  }

  /// Jumps to the break before [n] (so the next wave fought is [n]).
  void debugSkipToWave(int n) {
    enemies.clear();
    _toSpawn = 0;
    wave = n - 1;
    wavesCleared = n - 1;
    phase = BastionPhase.breakTime;
    breakTimer = 0;
  }

  /// Removes every queued and live enemy of the current wave.
  void debugClearWave() {
    enemies.clear();
    _toSpawn = 0;
  }

  /// A compact text snapshot of the state, for determinism checks.
  String debugSnapshot() {
    final units = grid.map((u) => u?.tier ?? 0).join('');
    final foes = enemies
        .map((e) => '${e.kind.index}:${e.x.toStringAsFixed(3)},${e.y.toStringAsFixed(3)}')
        .join(';');
    return 'w$wave p${phase.index} c$coins h$wallHp k$kills s$score [$units] {$foes}';
  }
}
