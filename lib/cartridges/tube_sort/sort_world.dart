import 'dart:math' as math;

/// Pure-Dart rules for Tube Sort (colour sorting puzzle).
///
/// Tubes hold up to [capacity] balls. Pouring moves the contiguous run of
/// same-coloured balls from the top of one tube onto another tube whose top
/// matches (or which is empty), as far as space allows. A level is solved when
/// every tube is empty or holds [capacity] balls of a single colour.

enum SortPhase { playing, won, lost }

enum PourOutcome { poured, invalid }

class SortMove {
  const SortMove(this.from, this.to, this.count);
  final int from;
  final int to;
  final int count;
}

class SortWorld {
  SortWorld({this.level = 1, int seed = 1}) : capacity = 4 {
    final colors = colorsForLevel(level);
    final rng = math.Random(seed * 7919 + level);
    // Shuffle until the solver confirms the deal is solvable.
    for (var attempt = 0; attempt < 60; attempt++) {
      final deal = _deal(colors, rng);
      if (SortSolver(capacity).solve(deal) != null) {
        tubes = deal;
        break;
      }
    }
    tubes ??= _solvedFallback(colors);
  }

  /// Builds a world from explicit tubes (tests).
  SortWorld.custom(List<List<int>> tubes, {this.capacity = 4, this.level = 1}) {
    this.tubes = [for (final t in tubes) List<int>.of(t)];
  }

  static int colorsForLevel(int level) => math.min(10, 3 + (level + 1) ~/ 2);

  final int capacity;
  final int level;
  List<List<int>>? tubes;
  final List<SortMove> history = [];
  SortPhase phase = SortPhase.playing;
  int moves = 0;
  int undosLeft = 5;
  int extraTubesLeft = 1;
  double time = 0;

  List<List<int>> get t => tubes!;
  bool get isOver => phase != SortPhase.playing;
  int get entityCount => t.fold(0, (a, tube) => a + tube.length) + t.length;
  int get colorCount => t.expand((x) => x).toSet().length;

  int get score {
    if (phase != SortPhase.won) return completedTubes * 50;
    final par = colorCount * 3;
    final moveBonus = math.max<int>(0, (par - moves) * 15);
    final timeBonus = math.max<int>(0, 300 - time.round() * 2);
    return 300 + level * 50 + moveBonus + timeBonus;
  }

  int get completedTubes => t.where((tube) => tube.length == capacity && tube.toSet().length == 1).length;

  List<List<int>> _deal(int colors, math.Random rng) {
    final balls = <int>[for (var c = 0; c < colors; c++) ...List.filled(capacity, c)]..shuffle(rng);
    final result = <List<int>>[];
    for (var i = 0; i < colors; i++) {
      result.add(balls.sublist(i * capacity, (i + 1) * capacity));
    }
    // Avoid deals where a tube is already complete.
    for (final tube in result) {
      if (tube.toSet().length == 1) return _deal(colors, rng);
    }
    result
      ..add(<int>[])
      ..add(<int>[]);
    return result;
  }

  List<List<int>> _solvedFallback(int colors) => [
    for (var c = 0; c < colors; c++) List.filled(capacity, c),
    <int>[],
    <int>[],
  ];

  /// Number of balls that would move from [from] to [to] (0 = illegal).
  static int pourCount(List<List<int>> tubes, int from, int to, int capacity) {
    if (from == to || from < 0 || to < 0 || from >= tubes.length || to >= tubes.length) return 0;
    final a = tubes[from], b = tubes[to];
    if (a.isEmpty || b.length >= capacity) return 0;
    final color = a.last;
    if (b.isNotEmpty && b.last != color) return 0;
    var run = 0;
    for (var i = a.length - 1; i >= 0 && a[i] == color; i--) {
      run++;
    }
    return math.min(run, capacity - b.length);
  }

  bool canPour(int from, int to) => !isOver && pourCount(t, from, to, capacity) > 0;

  PourOutcome pour(int from, int to) {
    if (isOver) return PourOutcome.invalid;
    final n = pourCount(t, from, to, capacity);
    if (n == 0) return PourOutcome.invalid;
    for (var i = 0; i < n; i++) {
      t[to].add(t[from].removeLast());
    }
    history.add(SortMove(from, to, n));
    moves++;
    _checkState();
    return PourOutcome.poured;
  }

  bool undo() {
    if (isOver || history.isEmpty || undosLeft <= 0) return false;
    final m = history.removeLast();
    for (var i = 0; i < m.count; i++) {
      t[m.from].add(t[m.to].removeLast());
    }
    undosLeft--;
    moves++;
    return true;
  }

  bool addTube() {
    if (isOver || extraTubesLeft <= 0) return false;
    extraTubesLeft--;
    t.add(<int>[]);
    return true;
  }

  bool get solved => t.every((tube) => tube.isEmpty || (tube.length == capacity && tube.toSet().length == 1));

  bool get hasLegalMove {
    for (var a = 0; a < t.length; a++) {
      for (var b = 0; b < t.length; b++) {
        if (pourCount(t, a, b, capacity) > 0) return true;
      }
    }
    return false;
  }

  void _checkState() {
    if (solved) {
      phase = SortPhase.won;
    } else if (!hasLegalMove && undosLeft == 0 && extraTubesLeft == 0) {
      phase = SortPhase.lost;
    }
  }

  /// True when the player is stuck but can still rescue the run with a power.
  bool get stuck => !isOver && !hasLegalMove;

  void update(double dt) {
    if (!isOver) time += dt;
  }

  /// Gives up (used when stuck with no powers).
  void concede() {
    if (!isOver) phase = SortPhase.lost;
  }
}

/// Depth-first solver with memoisation, used to guarantee solvable deals.
class SortSolver {
  SortSolver(this.capacity, {this.nodeLimit = 60000});

  final int capacity;
  final int nodeLimit;
  int _nodes = 0;

  /// Returns a list of (from, to) moves solving [start], or null.
  List<(int, int)>? solve(List<List<int>> start) {
    _nodes = 0;
    final seen = <String>{};
    final path = <(int, int)>[];
    final state = [for (final t in start) List<int>.of(t)];
    return _dfs(state, seen, path) ? path : null;
  }

  static String _key(List<List<int>> s) {
    final parts = [for (final t in s) t.join(',')]..sort();
    return parts.join('|');
  }

  bool _solved(List<List<int>> s) =>
      s.every((t) => t.isEmpty || (t.length == capacity && t.every((b) => b == t.first)));

  bool _dfs(List<List<int>> s, Set<String> seen, List<(int, int)> path) {
    if (_solved(s)) return true;
    if (++_nodes > nodeLimit) return false;
    if (!seen.add(_key(s))) return false;
    for (var a = 0; a < s.length; a++) {
      final src = s[a];
      if (src.isEmpty) continue;
      // Skip moving a complete tube or a uniform tube into an empty tube.
      final uniform = src.every((b) => b == src.first);
      if (uniform && src.length == capacity) continue;
      for (var b = 0; b < s.length; b++) {
        if (uniform && s[b].isEmpty) continue;
        final n = SortWorld.pourCount(s, a, b, capacity);
        if (n == 0) continue;
        for (var i = 0; i < n; i++) {
          s[b].add(s[a].removeLast());
        }
        path.add((a, b));
        if (_dfs(s, seen, path)) return true;
        path.removeLast();
        for (var i = 0; i < n; i++) {
          s[a].add(s[b].removeLast());
        }
      }
    }
    return false;
  }
}
