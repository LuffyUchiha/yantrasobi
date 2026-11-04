import 'dart:math' as math;

/// Phases of a Digit Barrage run: the upgrade shop, then one level of play.
enum BarragePhase { shop, playing, won, lost }

/// Things the shop sells.
enum UpgradeKind { fireRate, damage, coinValue }

/// Persistent upgrade levels, stored in the save as a small JSON map.
class BarrageUpgrades {
  BarrageUpgrades({int fireRate = 0, int damage = 0, int coinValue = 0})
    : _levels = [fireRate, damage, coinValue];

  /// Reads upgrades from a save value, tolerating missing or bad data.
  factory BarrageUpgrades.fromJson(Object? json) {
    if (json is! Map) return BarrageUpgrades();
    int read(String k) {
      final v = json[k];
      return v is num ? v.toInt().clamp(0, maxLevel) : 0;
    }

    return BarrageUpgrades(fireRate: read('fire'), damage: read('damage'), coinValue: read('coin'));
  }

  static const int maxLevel = 12;
  static const List<String> _keys = ['fire', 'damage', 'coin'];

  final List<int> _levels;

  int level(UpgradeKind k) => _levels[k.index];
  bool isMaxed(UpgradeKind k) => level(k) >= maxLevel;

  /// Coins needed to buy the next level of [k].
  int cost(UpgradeKind k) => costForLevel(level(k));

  /// Price of going from [lv] to lv+1: 6, 15, 30, 51, 78, ...
  static int costForLevel(int lv) => 6 + 6 * lv + 3 * lv * lv;

  void raise(UpgradeKind k) => _levels[k.index] = math.min(maxLevel, _levels[k.index] + 1);

  /// Bullets per second while the trigger is held.
  double get shotsPerSecond => 5 + 1.5 * level(UpgradeKind.fireRate);

  /// Number knocked off a rock per bullet.
  int get damage => 1 + level(UpgradeKind.damage);

  /// Coins each dropped coin is worth.
  int get coinValue => 1 + level(UpgradeKind.coinValue);

  Map<String, Object?> toJson() => {for (var i = 0; i < 3; i++) _keys[i]: _levels[i]};
}

class BarrageRock {
  BarrageRock({
    required this.id,
    required this.x,
    required this.y,
    required this.size,
    required this.value,
    this.vx = 0,
    this.vy = 0,
    int? hp,
  }) : hp = hp ?? value;

  final int id;
  double x;
  double y;
  double vx;
  double vy;

  /// 0 (smallest, pops at zero) .. 3 (largest).
  final int size;

  /// The number the rock started with; children get half of it (rounded up).
  final int value;

  /// Current number shown on the rock.
  int hp;

  /// Brief white flash after a hit, for the renderer.
  double flash = 0;

  double get r => BarrageWorld.radiusFor(size);
}

class BarrageBullet {
  BarrageBullet(this.x, this.y);
  double x;
  double y;
}

class BarrageCoin {
  BarrageCoin(this.x, this.y, this.value, {this.vx = 0, this.vy = -160});
  double x;
  double y;
  double vx;
  double vy;
  final int value;
  bool landed = false;

  /// Seconds left on the floor before it fades away.
  double life = BarrageWorld.coinLife;
}

enum BarrageEventKind { shot, hit, split, pop, coin, lost, won }

class BarrageEvent {
  const BarrageEvent(this.kind, this.x, this.y, {this.size = 0, this.value = 0});
  final BarrageEventKind kind;
  final double x;
  final double y;
  final int size;
  final int value;
}

/// Pure rules for Digit Barrage: a cannon cart at the floor fires upward at
/// bouncing numbered rocks. Each hit lowers the number; at zero a rock splits
/// into two smaller rocks worth half its starting number (rounded up), and the
/// smallest size just pops. Touching a rock loses; clearing every rock wins.
///
/// The arena is a fixed [width] x [height] logical space so the simulation is
/// independent of screen size, and it advances in fixed [step]s.
class BarrageWorld {
  BarrageWorld({
    required int seed,
    this.level = 1,
    BarrageUpgrades? upgrades,
    this.wallet = 0,
    List<BarrageRock>? rocks,
    bool startInShop = true,
  }) : upgrades = upgrades ?? BarrageUpgrades(),
       _rng = math.Random(seed) {
    if (rocks != null) {
      this.rocks.addAll(rocks);
      _nextId = rocks.fold(0, (m, r) => math.max(m, r.id + 1));
      phase = BarragePhase.playing;
    } else {
      _buildLevel();
      phase = startInShop ? BarragePhase.shop : BarragePhase.playing;
    }
  }

  // ---------------------------------------------------------------- constants
  static const double width = 360;
  static const double height = 640;
  static const double floorY = 610;
  static const double gravity = 520;
  static const double step = 1 / 120;

  static const double cartHalfWidth = 26;
  static const double cartHeight = 30;

  /// Hitbox is a little smaller than the drawn cart to feel fair.
  static const double cartHitHalfWidth = 21;
  static const double cartHitHeight = 25;
  static const double cartSpeed = 1100;

  static const double bulletSpeed = 950;
  static const double bulletRadius = 4;
  static const double coinRadius = 9;
  static const double coinLife = 7;

  static const List<double> _radii = [16, 24, 34, 46];
  static const List<double> _apex = [200, 260, 320, 380];
  static const List<double> _hSpeed = [100, 90, 80, 70];

  static double radiusFor(int size) => _radii[size.clamp(0, 3)];

  /// Upward speed after each floor bounce: every size bounces to a fixed apex.
  static double bounceSpeedFor(int size) => math.sqrt(2 * gravity * _apex[size.clamp(0, 3)]);
  static double sideSpeedFor(int size) => _hSpeed[size.clamp(0, 3)];

  /// Value of each child after a rock of [value] reaches zero.
  static int childValue(int value) => (value + 1) ~/ 2;

  /// Total damage needed to clear a rock of [size] starting at [value],
  /// including all of its splits.
  static int treeHp(int size, int value) =>
      size <= 0 ? value : value + 2 * treeHp(size - 1, childValue(value));

  /// Target total HP for a level; grows ~32% per level.
  static int hpBudget(int level) => (36 * math.pow(1.32, math.max(0, level - 1))).round();

  static int rockCountFor(int level) => math.min(5, 1 + level ~/ 2);
  static int maxSizeFor(int level) => math.min(3, 2 + (level - 1) ~/ 3);

  // ---------------------------------------------------------------- state
  final int level;
  final BarrageUpgrades upgrades;
  final math.Random _rng;

  /// Banked coins available in the shop (outside the run's own pickups).
  int wallet;
  late BarragePhase phase;

  final List<BarrageRock> rocks = [];
  final List<BarrageBullet> bullets = [];
  final List<BarrageCoin> coins = [];
  final List<BarrageEvent> events = [];

  /// Rocks still waiting to roll in, with the delay before each appears.
  final List<BarrageRock> _pending = [];
  final List<double> _pendingDelay = [];

  double cartX = width / 2;
  double cartTarget = width / 2;
  bool firing = false;

  double time = 0;
  double _acc = 0;
  double _cooldown = 0;
  int _nextId = 0;
  int _shotSide = 0;
  bool _lastLeft = false;

  int damageDealt = 0;
  int coinsRun = 0;
  int splits = 0;
  int pops = 0;

  /// Total HP generated for this level (all rocks and their splits).
  int levelHp = 0;

  bool get isOver => phase == BarragePhase.won || phase == BarragePhase.lost;
  bool get won => phase == BarragePhase.won;
  int get score => damageDealt + coinsRun;
  int get entityCount => rocks.length + bullets.length + coins.length + _pending.length + 1;
  int get pendingCount => _pending.length;

  /// HP still standing (rocks on screen, their future splits, and rocks to come).
  int get remainingHp {
    var t = 0;
    for (final r in rocks) {
      t += r.hp + (r.size > 0 ? 2 * treeHp(r.size - 1, childValue(r.value)) : 0);
    }
    for (final r in _pending) {
      t += treeHp(r.size, r.value);
    }
    return t;
  }

  double get progress => levelHp <= 0 ? 0 : (1 - remainingHp / levelHp).clamp(0.0, 1.0);

  // ---------------------------------------------------------------- level gen
  void _buildLevel() {
    final count = rockCountFor(level);
    final maxSize = maxSizeFor(level);
    final sizes = <int>[];
    for (var i = 0; i < count; i++) {
      sizes.add(i == 0 ? maxSize : math.max(0, maxSize - _rng.nextInt(2)));
    }
    final weight = sizes.fold<int>(0, (s, z) => s + z + 1);
    final budget = hpBudget(level);
    for (var i = 0; i < count; i++) {
      final s = sizes[i];
      final share = budget * (s + 1) / weight;
      final value = math.max(1, (share / (s + 1)).round());
      final left = i == 0 ? _rng.nextBool() : !_lastLeft;
      _lastLeft = left;
      final r = radiusFor(s);
      final rock = BarrageRock(
        id: _nextId++,
        x: left ? r + 4 : width - r - 4,
        y: 70 + r + _rng.nextDouble() * 40,
        size: s,
        value: value,
        vx: left ? sideSpeedFor(s) : -sideSpeedFor(s),
      );
      _pending.add(rock);
      _pendingDelay.add(i == 0 ? 0.6 : 3.2);
      levelHp += treeHp(s, value);
    }
  }

  // ---------------------------------------------------------------- input
  /// Buys one level of [k] from the wallet. Only works in the shop.
  bool buy(UpgradeKind k) {
    if (phase != BarragePhase.shop || upgrades.isMaxed(k)) return false;
    final c = upgrades.cost(k);
    if (wallet < c) return false;
    wallet -= c;
    upgrades.raise(k);
    return true;
  }

  bool canBuy(UpgradeKind k) =>
      phase == BarragePhase.shop && !upgrades.isMaxed(k) && wallet >= upgrades.cost(k);

  /// Leaves the shop and starts the level.
  void start() {
    if (phase == BarragePhase.shop) phase = BarragePhase.playing;
  }

  static double get cartMin => cartHalfWidth;
  static double get cartMax => width - cartHalfWidth;

  void setCartTarget(double x) => cartTarget = x.clamp(cartMin, cartMax);
  void moveCartBy(double dx) => setCartTarget(cartTarget + dx);
  void setFiring(bool on) => firing = on;

  // ---------------------------------------------------------------- update
  void update(double dt) {
    events.clear();
    if (phase != BarragePhase.playing) return;
    _acc += math.min(dt, 0.1);
    while (_acc >= step && phase == BarragePhase.playing) {
      _acc -= step;
      _tick(step);
    }
  }

  void _tick(double dt) {
    time += dt;
    // Spawn queue.
    if (_pending.isNotEmpty) {
      _pendingDelay[0] -= dt;
      if (_pendingDelay[0] <= 0) {
        rocks.add(_pending.removeAt(0));
        _pendingDelay.removeAt(0);
      }
    }
    // Cart.
    final d = cartTarget - cartX;
    final maxMove = cartSpeed * dt;
    cartX += d.abs() <= maxMove ? d : maxMove * d.sign;
    // Firing.
    _cooldown -= dt;
    if (firing && _cooldown <= 0) {
      _cooldown = 1 / upgrades.shotsPerSecond;
      _shotSide = 1 - _shotSide;
      final bx = cartX + (_shotSide == 0 ? -4.0 : 4.0);
      bullets.add(BarrageBullet(bx, floorY - cartHeight - 6));
      events.add(BarrageEvent(BarrageEventKind.shot, bx, floorY - cartHeight));
    }
    if (_cooldown < 0) _cooldown = 0;
    // Rocks.
    for (final r in rocks) {
      stepRock(r, dt);
      if (r.flash > 0) r.flash -= dt;
    }
    // Bullets.
    for (var i = bullets.length - 1; i >= 0; i--) {
      final b = bullets[i];
      b.y -= bulletSpeed * dt;
      if (b.y < -bulletRadius) {
        bullets.removeAt(i);
        continue;
      }
      for (var j = 0; j < rocks.length; j++) {
        final r = rocks[j];
        final dx = b.x - r.x, dy = b.y - r.y;
        final rr = r.r + bulletRadius;
        if (dx * dx + dy * dy <= rr * rr) {
          bullets.removeAt(i);
          hitRock(r, upgrades.damage);
          break;
        }
      }
    }
    // Coins.
    for (var i = coins.length - 1; i >= 0; i--) {
      final c = coins[i];
      if (!c.landed) {
        c.vy += gravity * dt;
        c.x += c.vx * dt;
        c.y += c.vy * dt;
        if (c.x < coinRadius || c.x > width - coinRadius) {
          c.vx = -c.vx;
          c.x = c.x.clamp(coinRadius, width - coinRadius);
        }
        if (c.y >= floorY - coinRadius) {
          c.y = floorY - coinRadius;
          c.landed = true;
        }
      } else {
        c.life -= dt;
        if (c.life <= 0) {
          coins.removeAt(i);
          continue;
        }
      }
      if ((c.x - cartX).abs() <= cartHalfWidth + coinRadius && c.y + coinRadius >= floorY - cartHeight - 2) {
        _collect(i);
      }
    }
    // Rock vs cart.
    for (final r in rocks) {
      if (rockTouchesCart(r, cartX)) {
        phase = BarragePhase.lost;
        firing = false;
        events.add(BarrageEvent(BarrageEventKind.lost, r.x, r.y, size: r.size));
        return;
      }
    }
    if (rocks.isEmpty && _pending.isEmpty) {
      // Sweep up any coins left on screen as a clear reward.
      for (var i = coins.length - 1; i >= 0; i--) {
        _collect(i);
      }
      phase = BarragePhase.won;
      firing = false;
      events.add(const BarrageEvent(BarrageEventKind.won, width / 2, height / 2));
    }
  }

  void _collect(int i) {
    final c = coins.removeAt(i);
    coinsRun += c.value;
    events.add(BarrageEvent(BarrageEventKind.coin, c.x, c.y, value: c.value));
  }

  /// Advances one rock by [dt] with gravity, wall bounces and a fixed-height
  /// floor bounce. Static so bots and tests can predict motion.
  static void stepRock(BarrageRock r, double dt) {
    final rad = r.r;
    r.vy += gravity * dt;
    r.x += r.vx * dt;
    r.y += r.vy * dt;
    if (r.x < rad) {
      r.x = rad;
      r.vx = r.vx.abs();
    } else if (r.x > width - rad) {
      r.x = width - rad;
      r.vx = -r.vx.abs();
    }
    if (r.y > floorY - rad) {
      r.y = floorY - rad;
      r.vy = -bounceSpeedFor(r.size);
    } else if (r.y < rad) {
      r.y = rad;
      r.vy = r.vy.abs();
    }
  }

  /// Whether rock [r] overlaps the cart's hitbox with the cart centred at [x].
  static bool rockTouchesCart(BarrageRock r, double x, {double margin = 0}) {
    final left = x - cartHitHalfWidth - margin;
    final right = x + cartHitHalfWidth + margin;
    final top = floorY - cartHitHeight - margin;
    final nx = r.x.clamp(left, right);
    final ny = r.y.clamp(top, floorY);
    final dx = r.x - nx, dy = r.y - ny;
    return dx * dx + dy * dy < r.r * r.r;
  }

  /// Applies [damage] to [r]; at zero it splits (or pops at the smallest size)
  /// and drops a coin.
  void hitRock(BarrageRock r, int damage) {
    final dealt = math.min(damage, r.hp);
    r.hp -= dealt;
    damageDealt += dealt;
    r.flash = 0.08;
    events.add(BarrageEvent(BarrageEventKind.hit, r.x, r.y, size: r.size, value: dealt));
    if (r.hp > 0) return;
    rocks.remove(r);
    coins.add(BarrageCoin(r.x, r.y, upgrades.coinValue, vx: (_rng.nextDouble() - 0.5) * 80));
    if (r.size <= 0) {
      pops++;
      events.add(BarrageEvent(BarrageEventKind.pop, r.x, r.y, size: r.size, value: r.value));
      return;
    }
    splits++;
    final s = r.size - 1;
    final v = childValue(r.value);
    final cr = radiusFor(s);
    final kick = -bounceSpeedFor(s) * 0.8;
    for (final dir in const [-1.0, 1.0]) {
      final child = BarrageRock(
        id: _nextId++,
        x: (r.x + dir * cr * 0.7).clamp(cr, width - cr),
        y: math.min(r.y, floorY - cr - 1),
        size: s,
        value: v,
        vx: dir * sideSpeedFor(s),
        vy: kick,
      );
      rocks.add(child);
    }
    events.add(BarrageEvent(BarrageEventKind.split, r.x, r.y, size: r.size, value: v));
  }

  // ---------------------------------------------------------------- helpers
  /// Predicts whether any rock will touch the cart within [horizon] seconds
  /// if it drives from its current spot toward [x] at full speed and stays
  /// there (ignores future hits). Used by bots and tests.
  bool dangerAt(double x, {double horizon = 0.5, double margin = 6}) {
    const dt = 1 / 60;
    final goal = x.clamp(cartMin, cartMax);
    for (final r in rocks) {
      final g = BarrageRock(id: -1, x: r.x, y: r.y, size: r.size, value: r.value, vx: r.vx, vy: r.vy);
      var cx = cartX;
      for (var t = 0.0; t <= horizon; t += dt) {
        if (rockTouchesCart(g, cx, margin: margin)) return true;
        stepRock(g, dt);
        final d = goal - cx;
        cx += d.abs() <= cartSpeed * dt ? d : cartSpeed * dt * d.sign;
      }
    }
    return false;
  }

  /// Debug: adds a rock right away (tests).
  BarrageRock addRock({
    required double x,
    required double y,
    required int size,
    required int value,
    double vx = 0,
    double vy = 0,
  }) {
    final r = BarrageRock(id: _nextId++, x: x, y: y, size: size, value: value, vx: vx, vy: vy);
    rocks.add(r);
    return r;
  }

  /// Debug: snapshot string for determinism tests.
  String snapshot() =>
      '${phase.name}|${time.toStringAsFixed(3)}|$damageDealt|$coinsRun|${cartX.toStringAsFixed(2)}|'
      '${rocks.map((r) => '${r.id}:${r.size}:${r.hp}:${r.x.toStringAsFixed(2)},${r.y.toStringAsFixed(2)}').join(';')}';
}
