import 'dart:math' as math;

/// Pure-Dart rules for Jam Tray. No Flutter/Flame imports, so every rule is
/// unit-testable and deterministic for a given seed + level.
///
/// Board geometry is in abstract *tile units*: a tile is a 1x1 square whose
/// top-left corner sits on a half-unit grid ([JamTile.x], [JamTile.y]). Even
/// layers sit on whole-unit positions, odd layers are offset by half a tile,
/// so upper tiles partially overlap the ones below. The board is
/// [JamWorld.boardWidth] x [JamWorld.boardHeight] units; the renderer scales it.

enum JamPhase { playing, won, lost }

/// What a single tap did, so the renderer can pick sounds and effects.
enum JamOutcome { ignored, blocked, moved, triple, won, lost }

class JamTile {
  JamTile(this.id, this.gx, this.gy, this.layer, this.kind);

  final int id;

  /// Position on the half-unit grid (0..[JamWorld.gridCols]-2 etc).
  final int gx;
  final int gy;
  final int layer;
  int kind;

  /// Still on the board (not in the tray and not cleared).
  bool onBoard = true;

  double get x => gx / 2;
  double get y => gy / 2;

  /// True when this tile's square overlaps [o]'s square with positive area.
  bool overlaps(JamTile o) => (gx - o.gx).abs() < 2 && (gy - o.gy).abs() < 2;

  bool contains(double px, double py) => px >= x && px < x + 1 && py >= y && py < y + 1;
}

class JamTapResult {
  const JamTapResult(this.outcome, {this.tile, this.slot = -1, this.clearedSlot = -1, this.clearedKind = -1});

  final JamOutcome outcome;
  final JamTile? tile;

  /// Tray index the tile was inserted at (before any triple was removed).
  final int slot;

  /// First tray index of the cleared triple, or -1.
  final int clearedSlot;
  final int clearedKind;

  bool get cleared => clearedSlot >= 0;
}

class JamWorld {
  JamWorld({required this.seed, this.level = 1})
    : assert(level >= 1),
      _rng = math.Random(seed * 7919 + level * 104729) {
    _generate();
  }

  /// A hand-built board for tests and tools. Tile ids must equal their index.
  JamWorld.custom(List<JamTile> board, {this.seed = 0, this.level = 1}) : _rng = math.Random(seed) {
    for (var i = 0; i < board.length; i++) {
      assert(board[i].id == i, 'tile ids must match their index');
    }
    tiles.addAll(board);
  }

  final int seed;
  final int level;
  final math.Random _rng;

  // ---------------------------------------------------------------- constants
  static const int trayCapacity = 7;
  static const int pointsPerTriple = 30;
  static const int startUndos = 3;
  static const int startShuffles = 2;

  /// Half-unit grid size; tiles are 2x2 half-cells.
  static const int gridCols = 14;
  static const int gridRows = 16;
  static const double boardWidth = gridCols / 2;
  static const double boardHeight = gridRows / 2;

  // ---------------------------------------------------------------- level shape
  static int tilesForLevel(int level) => math.min(24 + (level - 1) * 6, 84);
  static int kindsForLevel(int level) => level == 1 ? 3 : math.min(4 + (level - 2) ~/ 2, 10);
  static int layersForLevel(int level) => level <= 2 ? 2 : 3;

  /// Chance that two consecutive triples in the clearing order are interleaved.
  static double mixChanceFor(int level) => math.min(0.6, (level - 1) * 0.08);

  /// Seconds under which a win still earns a time bonus.
  double get parTime => tiles.length * 2.0;

  // ---------------------------------------------------------------- state
  final List<JamTile> tiles = [];
  final List<JamTile> tray = [];
  final List<int> _history = []; // tile ids currently in the tray, in tap order

  /// The reverse-play clearing order used to deal the kinds (tile ids). Tapping
  /// in this order always wins, which proves every generated board solvable.
  final List<int> solution = [];
  JamPhase phase = JamPhase.playing;
  int score = 0;
  int triples = 0;
  int moves = 0;
  int timeBonus = 0;
  double time = 0;
  int undosLeft = startUndos;
  int shufflesLeft = startShuffles;

  int get kindCount => kindsForLevel(level);
  int get layerCount => layersForLevel(level);
  bool get isOver => phase != JamPhase.playing;
  bool get won => phase == JamPhase.won;
  int get boardCount => tiles.where((t) => t.onBoard).length;
  int get entityCount => boardCount + tray.length;
  bool get canUndo => !isOver && undosLeft > 0 && _history.isNotEmpty;
  bool get canShuffle => !isOver && shufflesLeft > 0 && boardCount > 1;

  JamTile tileById(int id) => tiles[id];

  /// Count of each kind among tiles still on the board.
  Map<int, int> boardKindCounts() {
    final m = <int, int>{};
    for (final t in tiles) {
      if (t.onBoard) m[t.kind] = (m[t.kind] ?? 0) + 1;
    }
    return m;
  }

  int trayCountOf(int kind) => tray.where((t) => t.kind == kind).length;

  /// A tile is free when no higher-layer board tile overlaps it.
  bool isFree(JamTile t) {
    if (!t.onBoard) return false;
    for (final o in tiles) {
      if (o.onBoard && o.layer > t.layer && o.overlaps(t)) return false;
    }
    return true;
  }

  List<JamTile> freeTiles() => [
    for (final t in tiles)
      if (isFree(t)) t,
  ];

  /// Board tiles in draw order (bottom layer first).
  List<JamTile> drawOrder() {
    final list = tiles.where((t) => t.onBoard).toList()
      ..sort((a, b) => a.layer != b.layer ? a.layer - b.layer : a.id - b.id);
    return list;
  }

  /// Topmost board tile under the point (board units), or null.
  JamTile? tileAt(double x, double y) {
    JamTile? best;
    for (final t in tiles) {
      if (!t.onBoard || !t.contains(x, y)) continue;
      if (best == null || t.layer > best.layer || (t.layer == best.layer && t.id > best.id)) best = t;
    }
    return best;
  }

  void update(double dt) {
    if (phase == JamPhase.playing) time += dt;
  }

  // ---------------------------------------------------------------- actions
  JamTapResult tapAt(double x, double y) {
    final t = tileAt(x, y);
    if (t == null) return const JamTapResult(JamOutcome.ignored);
    return tap(t.id);
  }

  JamTapResult tap(int tileId) {
    if (isOver || tileId < 0 || tileId >= tiles.length) return const JamTapResult(JamOutcome.ignored);
    final t = tiles[tileId];
    if (!t.onBoard) return const JamTapResult(JamOutcome.ignored);
    if (!isFree(t)) return JamTapResult(JamOutcome.blocked, tile: t);
    t.onBoard = false;
    moves++;
    final slot = _insertSorted(t);
    _history.add(t.id);
    var clearedSlot = -1;
    var clearedKind = -1;
    if (trayCountOf(t.kind) >= 3) {
      clearedSlot = tray.indexWhere((e) => e.kind == t.kind);
      clearedKind = t.kind;
      final gone = tray.where((e) => e.kind == t.kind).map((e) => e.id).toSet();
      tray.removeWhere((e) => gone.contains(e.id));
      _history.removeWhere(gone.contains);
      triples++;
      score += pointsPerTriple;
    }
    var outcome = clearedSlot >= 0 ? JamOutcome.triple : JamOutcome.moved;
    if (boardCount == 0 && tray.isEmpty) {
      phase = JamPhase.won;
      timeBonus = math.max(0, (parTime - time).round()) * 5;
      score += timeBonus;
      outcome = JamOutcome.won;
    } else if (tray.length >= trayCapacity) {
      phase = JamPhase.lost;
      outcome = JamOutcome.lost;
    }
    return JamTapResult(outcome, tile: t, slot: slot, clearedSlot: clearedSlot, clearedKind: clearedKind);
  }

  /// Inserts right after the last tray tile of the same kind (or at the end),
  /// keeping identical kinds adjacent. Returns the index used.
  int _insertSorted(JamTile t) {
    final last = tray.lastIndexWhere((e) => e.kind == t.kind);
    final at = last >= 0 ? last + 1 : tray.length;
    tray.insert(at, t);
    return at;
  }

  /// Returns the most recently tapped tile still in the tray to its board spot.
  JamTile? undo() {
    if (!canUndo) return null;
    final id = _history.removeLast();
    final t = tiles[id];
    tray.removeWhere((e) => e.id == id);
    t.onBoard = true;
    undosLeft--;
    moves++;
    return t;
  }

  /// Randomly reassigns kinds among the tiles left on the board. The multiset
  /// of kinds is kept, so every kind's board+tray total stays a multiple of 3.
  bool shuffle() {
    if (!canShuffle) return false;
    final board = tiles.where((t) => t.onBoard).toList();
    final kinds = board.map((t) => t.kind).toList()..shuffle(_rng);
    for (var i = 0; i < board.length; i++) {
      board[i].kind = kinds[i];
    }
    shufflesLeft--;
    return true;
  }

  // ---------------------------------------------------------------- generation
  void _generate() {
    final total = tilesForLevel(level);
    final layers = layerCount;
    final weights = layers == 2 ? const [0.6, 0.4] : const [0.45, 0.33, 0.22];
    final perLayer = <int>[];
    var assigned = 0;
    for (var l = 0; l < layers; l++) {
      final n = l == layers - 1 ? total - assigned : (total * weights[l]).round();
      perLayer.add(n);
      assigned += n;
    }
    final placed = <JamTile>[];
    var id = 0;
    for (var l = 0; l < layers; l++) {
      final odd = l.isOdd;
      final candidates = <(int, int)>[];
      for (var gy = odd ? 1 : 0; gy <= gridRows - 2; gy += 2) {
        for (var gx = odd ? 1 : 0; gx <= gridCols - 2; gx += 2) {
          candidates.add((gx, gy));
        }
      }
      // Layer 0 grows outward from the centre so the board looks like a heap;
      // upper layers only sit where they rest on a tile of the layer below.
      final below = placed.where((t) => t.layer == l - 1).toList();
      final scored = <((int, int), double)>[];
      for (final c in candidates) {
        final probe = JamTile(-1, c.$1, c.$2, l, 0);
        if (l > 0 && !below.any(probe.overlaps)) continue;
        final dx = (c.$1 + 1) - gridCols / 2;
        final dy = (c.$2 + 1) - gridRows / 2;
        final dist = math.sqrt(dx * dx * 1.2 + dy * dy);
        scored.add((c, dist + _rng.nextDouble() * 3.0));
      }
      scored.sort((a, b) => a.$2.compareTo(b.$2));
      final take = math.min(perLayer[l], scored.length);
      if (take < perLayer[l] && l + 1 < layers) perLayer[l + 1] += perLayer[l] - take;
      for (var i = 0; i < take; i++) {
        placed.add(JamTile(id++, scored[i].$1.$1, scored[i].$1.$2, l, 0));
      }
    }
    tiles.addAll(placed);
    _assignKindsByReversePlay();
  }

  /// Reverse play: repeatedly remove a random free tile to get a legal
  /// clearing order, then deal kinds along that order in consecutive triples
  /// (sometimes two triples interleaved). Each kind's count is therefore a
  /// multiple of 3, and following the order never needs more than four tray
  /// slots, so every generated board is solvable.
  void _assignKindsByReversePlay() {
    final order = <JamTile>[];
    while (true) {
      final free = freeTiles();
      if (free.isEmpty) break;
      final t = free[_rng.nextInt(free.length)];
      t.onBoard = false;
      order.add(t);
    }
    for (final t in tiles) {
      t.onBoard = true;
    }
    solution.addAll(order.map((t) => t.id));
    final bag = <int>[];
    int nextKind([int? avoid]) {
      if (bag.isEmpty || (bag.length == 1 && bag.first == avoid)) {
        bag.addAll(List<int>.generate(kindCount, (i) => i)..shuffle(_rng));
      }
      return bag.removeAt(bag.indexWhere((k) => k != avoid));
    }

    final mix = mixChanceFor(level);
    var i = 0;
    while (i < order.length) {
      final List<int> block;
      if (order.length - i >= 6 && _rng.nextDouble() < mix) {
        final a = nextKind();
        final b = nextKind(a);
        block = [a, a, a, b, b, b]..shuffle(_rng);
      } else {
        final a = nextKind();
        block = [a, a, a];
      }
      for (final k in block) {
        order[i++].kind = k;
      }
    }
  }
}
