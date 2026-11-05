import 'dart:math' as math;
import 'dart:typed_data';

/// Which of the two pen-and-paper games a [GridWorld] plays.
enum GridMode {
  /// Draw lines between dots; closing a box claims it and grants another turn.
  boxes,

  /// Drop discs into a 7x6 rack; four in a row wins.
  fourDrop,
}

enum CpuLevel { easy, normal, hard }

/// One discrete move: a line id (Boxes) or a column (Four Drop).
///
/// Every action (human tap, CPU, or a future remote peer) enters the rules
/// only through [GridWorld.submitMove] as one of these plain value objects.
class GridMove {
  const GridMove(this.index);

  final int index;

  @override
  bool operator ==(Object other) => other is GridMove && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => 'GridMove($index)';
}

/// Pure, deterministic, turn-based rules for both games.
///
/// Boxes geometry: `dots` x `dots` dots, row/column in dot units. Horizontal
/// line `r * (dots - 1) + c` joins dot (r, c) to (r, c + 1); vertical line
/// `hLineCount + r * dots + c` joins dot (r, c) to (r + 1, c). Box
/// `r * (dots - 1) + c` has its top-left corner on dot (r, c).
///
/// Four Drop geometry: [cols] x [rows] cells, row 0 at the top; cell index
/// `row * cols + col`. Discs fall to the lowest empty row of a column.
class GridWorld {
  GridWorld._(this.mode, this.dots, this.players, this.firstPlayer)
    : scores = List<int>.filled(players, 0),
      current = firstPlayer,
      boxSpan = dots - 1,
      hLineCount = dots * (dots - 1),
      lineCount = mode == GridMode.boxes ? 2 * dots * (dots - 1) : 0,
      lines = _filled(mode == GridMode.boxes ? 2 * dots * (dots - 1) : 0),
      boxes = _filled(mode == GridMode.boxes ? (dots - 1) * (dots - 1) : 0),
      sides = Int8List(mode == GridMode.boxes ? (dots - 1) * (dots - 1) : 0),
      cells = _filled(mode == GridMode.fourDrop ? cols * rows : 0),
      heights = Int8List(mode == GridMode.fourDrop ? cols : 0),
      _lineBoxes = mode == GridMode.boxes ? _buildLineBoxes(dots) : Int16List(0);

  static Int8List _filled(int n) => Int8List(n)..fillRange(0, n, -1);

  /// A dots-and-boxes match on a `dots` x `dots` grid for 2-4 players.
  factory GridWorld.boxes({int dots = 5, int players = 2, int firstPlayer = 0}) {
    if (dots < 3 || dots > 9) throw ArgumentError.value(dots, 'dots', 'must be 3..9');
    if (players < 2 || players > 4) throw ArgumentError.value(players, 'players', 'must be 2..4');
    return GridWorld._(GridMode.boxes, dots, players, firstPlayer % players);
  }

  /// A two-player Four Drop match.
  factory GridWorld.fourDrop({int firstPlayer = 0}) => GridWorld._(GridMode.fourDrop, 0, 2, firstPlayer % 2);

  static const int cols = 7;
  static const int rows = 6;
  static const int connect = 4;

  final GridMode mode;
  final int dots;
  final int players;
  final int firstPlayer;

  // ---------------------------------------------------------------- Boxes state
  final int boxSpan;
  final int hLineCount;
  final int lineCount;

  /// Who drew each line (-1 = not drawn).
  final Int8List lines;

  /// Who owns each box (-1 = open).
  final Int8List boxes;

  /// Number of drawn sides of each box (0..4).
  final Int8List sides;

  /// Up to two boxes touching each line (-1 = none), two entries per line.
  final Int16List _lineBoxes;
  int drawnLines = 0;

  /// Boxes claimed by the most recent move (0, 1 or 2).
  int lastClaimed = 0;

  // ---------------------------------------------------------------- Four Drop state
  /// Disc owner per cell (-1 = empty).
  final Int8List cells;

  /// Discs stacked in each column.
  final Int8List heights;
  int filled = 0;

  /// Cell of the most recent disc (-1 = none).
  int lastCell = -1;

  /// Cells of the winning run (empty until someone connects four).
  final List<int> winLine = [];

  // ---------------------------------------------------------------- shared state
  /// Boxes claimed per player (Boxes), or 1 for the Four Drop winner.
  final List<int> scores;

  /// Whose turn it is.
  int current;

  /// Every accepted move in order; replaying them into [fresh] reproduces this world.
  final List<GridMove> history = [];

  int _tick = 0;

  /// Accepted moves so far.
  int get tick => _tick;

  /// Turns started so far (an extra Boxes turn does not start a new turn).
  int turnNumber = 1;

  /// Index of the most recent move (line or column), -1 before the first.
  int lastMove = -1;
  int lastMover = -1;

  /// Winner once the game is over, null while playing or on a draw.
  int? winner;
  bool isDraw = false;

  bool get isOver => winner != null || isDraw;

  /// Player 0 (the local player) won.
  bool get won => winner == 0;

  /// Boxes claimed by player 0, or 1 if player 0 connected four.
  int get score => scores[0];

  int get entityCount => mode == GridMode.boxes ? drawnLines + boxes.where((b) => b >= 0).length : filled;

  /// A brand-new world with the same configuration.
  GridWorld fresh() => mode == GridMode.boxes
      ? GridWorld.boxes(dots: dots, players: players, firstPlayer: firstPlayer)
      : GridWorld.fourDrop(firstPlayer: firstPlayer);

  /// Rebuilds a world purely from [source]'s configuration and move history.
  static GridWorld replay(GridWorld source) {
    final w = source.fresh();
    for (final m in source.history) {
      if (!w.submitMove(w.current, m)) throw StateError('history move $m rejected on replay');
    }
    return w;
  }

  /// A deep copy (used by CPU look-ahead).
  GridWorld copy() {
    final w = fresh();
    w.lines.setAll(0, lines);
    w.boxes.setAll(0, boxes);
    w.sides.setAll(0, sides);
    w.cells.setAll(0, cells);
    w.heights.setAll(0, heights);
    w.scores.setAll(0, scores);
    w.drawnLines = drawnLines;
    w.lastClaimed = lastClaimed;
    w.filled = filled;
    w.lastCell = lastCell;
    w.winLine.addAll(winLine);
    w.current = current;
    w.history.addAll(history);
    w._tick = _tick;
    w.turnNumber = turnNumber;
    w.lastMove = lastMove;
    w.lastMover = lastMover;
    w.winner = winner;
    w.isDraw = isDraw;
    return w;
  }

  // ---------------------------------------------------------------- moves
  /// Whether [move] is legal for whoever is to move now.
  bool isLegal(GridMove move) {
    if (isOver) return false;
    final i = move.index;
    if (mode == GridMode.boxes) return i >= 0 && i < lineCount && lines[i] < 0;
    return i >= 0 && i < cols && heights[i] < rows;
  }

  /// All legal move indices in ascending order.
  List<int> legalIndices() {
    if (isOver) return const [];
    final out = <int>[];
    final n = mode == GridMode.boxes ? lineCount : cols;
    for (var i = 0; i < n; i++) {
      if (mode == GridMode.boxes ? lines[i] < 0 : heights[i] < rows) out.add(i);
    }
    return out;
  }

  /// Applies [move] for [player]. Returns false (and changes nothing) when the
  /// game is over, it is not [player]'s turn, or the move is illegal.
  bool submitMove(int player, GridMove move) {
    if (player != current || !isLegal(move)) return false;
    history.add(move);
    _tick++;
    lastMove = move.index;
    lastMover = player;
    if (mode == GridMode.boxes) {
      _drawLine(player, move.index);
    } else {
      _drop(player, move.index);
    }
    return true;
  }

  /// Convenience for tests and tools: [current] plays [index].
  bool play(int index) => submitMove(current, GridMove(index));

  void _advance() {
    current = (current + 1) % players;
    turnNumber++;
  }

  // ---------------------------------------------------------------- Boxes rules
  int hLine(int r, int c) => r * boxSpan + c;
  int vLine(int r, int c) => hLineCount + r * dots + c;
  int boxAt(int r, int c) => r * boxSpan + c;
  bool isHorizontal(int line) => line < hLineCount;

  /// The two end dots of [line] as (row, col) pairs.
  ({int r1, int c1, int r2, int c2}) lineEnds(int line) {
    if (line < hLineCount) {
      final r = line ~/ boxSpan, c = line % boxSpan;
      return (r1: r, c1: c, r2: r, c2: c + 1);
    }
    final v = line - hLineCount;
    final r = v ~/ dots, c = v % dots;
    return (r1: r, c1: c, r2: r + 1, c2: c);
  }

  /// Boxes touching [line] (one on the border, two inside).
  List<int> boxesOfLine(int line) => [
    for (var k = 0; k < 2; k++)
      if (_lineBoxes[line * 2 + k] >= 0) _lineBoxes[line * 2 + k],
  ];

  /// The four side lines of [box]: top, bottom, left, right.
  List<int> linesOfBox(int box) {
    final r = box ~/ boxSpan, c = box % boxSpan;
    return [hLine(r, c), hLine(r + 1, c), vLine(r, c), vLine(r, c + 1)];
  }

  /// Whether drawing [line] would complete at least one box.
  bool completesBox(int line) {
    for (var k = 0; k < 2; k++) {
      final b = _lineBoxes[line * 2 + k];
      if (b >= 0 && sides[b] == 3) return true;
    }
    return false;
  }

  /// Number of boxes that drawing [line] would leave on exactly three sides
  /// (handing them to the next player).
  int givesAway(int line) {
    var n = 0;
    for (var k = 0; k < 2; k++) {
      final b = _lineBoxes[line * 2 + k];
      if (b >= 0 && sides[b] == 2) n++;
    }
    return n;
  }

  static Int16List _buildLineBoxes(int dots) {
    final span = dots - 1;
    final hCount = dots * span;
    final out = Int16List(2 * 2 * dots * span)..fillRange(0, 2 * 2 * dots * span, -1);
    for (var r = 0; r < dots; r++) {
      for (var c = 0; c < span; c++) {
        final l = r * span + c;
        if (r > 0) out[l * 2] = (r - 1) * span + c;
        if (r < span) out[l * 2 + 1] = r * span + c;
      }
    }
    for (var r = 0; r < span; r++) {
      for (var c = 0; c < dots; c++) {
        final l = hCount + r * dots + c;
        if (c > 0) out[l * 2] = r * span + c - 1;
        if (c < span) out[l * 2 + 1] = r * span + c;
      }
    }
    return out;
  }

  void _drawLine(int player, int line) {
    lines[line] = player;
    drawnLines++;
    var claimed = 0;
    for (var k = 0; k < 2; k++) {
      final b = _lineBoxes[line * 2 + k];
      if (b < 0) continue;
      sides[b]++;
      if (sides[b] == 4) {
        boxes[b] = player;
        scores[player]++;
        claimed++;
      }
    }
    lastClaimed = claimed;
    if (drawnLines == lineCount) {
      _finishBoxes();
    } else if (claimed == 0) {
      _advance();
    }
  }

  void _finishBoxes() {
    final top = leaders();
    if (top.length == 1) {
      winner = top.first;
    } else {
      isDraw = true;
    }
  }

  /// Players sharing the highest score, in seat order.
  List<int> leaders() {
    final best = scores.reduce(math.max);
    return [
      for (var p = 0; p < players; p++)
        if (scores[p] == best) p,
    ];
  }

  /// The undrawn line nearest to the point ([gx], [gy]) in dot units (x =
  /// column, y = row), or -1 if none lies within [maxDist]. Used for generous
  /// tap targets.
  int nearestLine(double gx, double gy, {double maxDist = 0.42}) {
    var best = -1;
    var bestD = maxDist * maxDist;
    for (var l = 0; l < lineCount; l++) {
      if (lines[l] >= 0) continue;
      final e = lineEnds(l);
      // Segment from (c1, r1) to (c2, r2); axis-aligned with length 1.
      final double dx, dy;
      if (e.r1 == e.r2) {
        dx = gx < e.c1 ? e.c1 - gx : (gx > e.c2 ? gx - e.c2 : 0);
        dy = gy - e.r1;
      } else {
        dx = gx - e.c1;
        dy = gy < e.r1 ? e.r1 - gy : (gy > e.r2 ? gy - e.r2 : 0);
      }
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = l;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- Four Drop rules
  int cellAt(int row, int col) => cells[row * cols + col];

  void _drop(int player, int col) {
    final row = rows - 1 - heights[col];
    final cell = row * cols + col;
    cells[cell] = player;
    heights[col]++;
    filled++;
    lastCell = cell;
    final run = winningRun(cells, row, col, player);
    if (run != null) {
      winLine.addAll(run);
      winner = player;
      scores[player] = 1;
    } else if (filled == cols * rows) {
      isDraw = true;
    } else {
      _advance();
    }
  }

  static const List<List<int>> _dirs = [
    [0, 1],
    [1, 0],
    [1, 1],
    [1, -1],
  ];

  /// The run of [player] discs through (row, col) if it is at least four long.
  static List<int>? winningRun(Int8List cells, int row, int col, int player) {
    for (final d in _dirs) {
      final run = <int>[row * cols + col];
      for (final sign in const [1, -1]) {
        var r = row + d[0] * sign, c = col + d[1] * sign;
        while (r >= 0 && r < rows && c >= 0 && c < cols && cells[r * cols + c] == player) {
          run.add(r * cols + c);
          r += d[0] * sign;
          c += d[1] * sign;
        }
      }
      if (run.length >= connect) {
        run.sort();
        return run;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- lockstep
  /// Cheap hash of everything that matters, for desync detection. Stays within
  /// 30 bits so it is identical on the VM and on the web.
  int stateHash() {
    var h = 17;
    void mix(int v) => h = (h * 31 + v + 7) & 0x3fffffff;
    mix(mode.index);
    mix(dots);
    mix(players);
    mix(current);
    mix(_tick);
    mix(turnNumber);
    mix(winner ?? -1);
    mix(isDraw ? 1 : 0);
    for (final s in scores) {
      mix(s);
    }
    for (final v in lines) {
      mix(v);
    }
    for (final v in boxes) {
      mix(v);
    }
    for (final v in cells) {
      mix(v);
    }
    return h;
  }
}

/// A CPU opponent: reads the world and returns a [GridMove] that the caller
/// feeds through [GridWorld.submitMove], exactly like a human tap.
class AiController {
  AiController({required this.player, this.level = CpuLevel.normal, int seed = 0, int? depth})
    : searchDepth = depth ?? depthFor(level),
      _rng = math.Random(seed);

  final int player;
  final CpuLevel level;

  /// Four Drop search depth in plies.
  final int searchDepth;
  final math.Random _rng;

  static int depthFor(CpuLevel level) => switch (level) {
    CpuLevel.easy => 1,
    CpuLevel.normal => 4,
    CpuLevel.hard => 6,
  };

  /// The move this CPU wants to play now, or null when it is not its turn.
  GridMove? think(GridWorld w) {
    if (w.isOver || w.current != player) return null;
    final i = w.mode == GridMode.boxes ? _boxes(w) : _fourDrop(w);
    return GridMove(i);
  }

  // ---------------------------------------------------------------- Boxes
  int _boxes(GridWorld w) {
    final legal = w.legalIndices();
    final taking = [
      for (final l in legal)
        if (w.completesBox(l)) l,
    ];
    if (level == CpuLevel.easy) {
      if (taking.isNotEmpty && _rng.nextDouble() < 0.7) return taking[_rng.nextInt(taking.length)];
      return legal[_rng.nextInt(legal.length)];
    }
    // Greedy: always take a box when one is on offer.
    if (taking.isNotEmpty) return taking.first;
    // Avoid drawing the third side of any box.
    final safe = [
      for (final l in legal)
        if (w.givesAway(l) == 0) l,
    ];
    if (safe.isNotEmpty) return safe[_rng.nextInt(safe.length)];
    if (level == CpuLevel.normal) {
      // Hand over as few boxes as possible right now.
      var bestN = 3;
      final picks = <int>[];
      for (final l in legal) {
        final n = w.givesAway(l);
        if (n < bestN) {
          bestN = n;
          picks.clear();
        }
        if (n == bestN) picks.add(l);
      }
      return picks[_rng.nextInt(picks.length)];
    }
    // Hard: count the whole chain each sacrifice gives away and pick the smallest.
    var best = legal.first;
    var bestLoss = 1 << 20;
    for (final l in legal) {
      final loss = chainLoss(w, l);
      if (loss < bestLoss) {
        bestLoss = loss;
        best = l;
      }
    }
    return best;
  }

  /// Boxes the opponents would grab greedily after [w.current] draws [line].
  static int chainLoss(GridWorld w, int line) {
    final sim = w.copy();
    final me = sim.current;
    sim.play(line);
    var lost = 0;
    while (!sim.isOver && sim.current != me) {
      var took = -1;
      for (final l in sim.legalIndices()) {
        if (sim.completesBox(l)) {
          took = l;
          break;
        }
      }
      if (took < 0) break;
      final p = sim.current;
      final before = sim.scores[p];
      sim.play(took);
      lost += sim.scores[p] - before;
    }
    return lost;
  }

  // ---------------------------------------------------------------- Four Drop
  /// Centre-first column order: deterministic tie-breaking.
  static const List<int> columnOrder = [3, 2, 4, 1, 5, 0, 6];
  static const int _win = 1000000;

  int _fourDrop(GridWorld w) {
    if (level == CpuLevel.easy && _rng.nextDouble() < 0.25) {
      final legal = w.legalIndices();
      return legal[_rng.nextInt(legal.length)];
    }
    return bestColumn(w, searchDepth);
  }

  /// Negamax with alpha-beta to [depth] plies; the first best column in
  /// [columnOrder] wins ties.
  static int bestColumn(GridWorld w, int depth) {
    final s = _Search(Int8List.fromList(w.cells), Int8List.fromList(w.heights), w.filled);
    final me = w.current;
    var best = -1;
    var bestScore = -_win * 4;
    var alpha = -_win * 4;
    const beta = _win * 4;
    for (final c in columnOrder) {
      if (s.heights[c] >= GridWorld.rows) continue;
      final row = s.play(c, me);
      final int score;
      if (GridWorld.winningRun(s.cells, row, c, me) != null) {
        score = _win + depth;
      } else if (s.filled == GridWorld.cols * GridWorld.rows || depth <= 1) {
        score = s.filled == GridWorld.cols * GridWorld.rows ? 0 : s.evaluate(me);
      } else {
        score = -s.negamax(depth - 1, -beta, -alpha, 1 - me);
      }
      s.undo(c);
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
      if (bestScore > alpha) alpha = bestScore;
    }
    return best;
  }
}

class _Search {
  _Search(this.cells, this.heights, this.filled);

  final Int8List cells;
  final Int8List heights;
  int filled;

  static const int _cols = GridWorld.cols;
  static const int _rows = GridWorld.rows;
  static final Int16List _windows = _buildWindows();

  static Int16List _buildWindows() {
    final out = <int>[];
    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        for (final d in GridWorld._dirs) {
          final er = r + d[0] * 3, ec = c + d[1] * 3;
          if (er < 0 || er >= _rows || ec < 0 || ec >= _cols) continue;
          for (var k = 0; k < 4; k++) {
            out.add((r + d[0] * k) * _cols + c + d[1] * k);
          }
        }
      }
    }
    return Int16List.fromList(out);
  }

  int play(int col, int player) {
    final row = _rows - 1 - heights[col];
    cells[row * _cols + col] = player;
    heights[col]++;
    filled++;
    return row;
  }

  void undo(int col) {
    heights[col]--;
    final row = _rows - 1 - heights[col];
    cells[row * _cols + col] = -1;
    filled--;
  }

  int negamax(int depth, int alpha, int beta, int side) {
    var best = -AiController._win * 4;
    for (final c in AiController.columnOrder) {
      if (heights[c] >= _rows) continue;
      final row = play(c, side);
      final int score;
      if (GridWorld.winningRun(cells, row, c, side) != null) {
        score = AiController._win + depth;
      } else if (filled == _cols * _rows) {
        score = 0;
      } else if (depth <= 1) {
        score = evaluate(side);
      } else {
        score = -negamax(depth - 1, -beta, -alpha, 1 - side);
      }
      undo(c);
      if (score > best) best = score;
      if (best > alpha) alpha = best;
      if (alpha >= beta) break;
    }
    return best;
  }

  /// Static score of the position from [side]'s point of view.
  int evaluate(int side) {
    var total = 0;
    final w = _windows;
    for (var i = 0; i < w.length; i += 4) {
      var mine = 0, theirs = 0;
      for (var k = 0; k < 4; k++) {
        final v = cells[w[i + k]];
        if (v == side) {
          mine++;
        } else if (v >= 0) {
          theirs++;
        }
      }
      if (theirs == 0) {
        if (mine == 3) {
          total += 6;
        } else if (mine == 2) {
          total += 2;
        }
      } else if (mine == 0) {
        if (theirs == 3) {
          total -= 6;
        } else if (theirs == 2) {
          total -= 2;
        }
      }
    }
    for (var r = 0; r < _rows; r++) {
      final v = cells[r * _cols + 3];
      if (v == side) {
        total += 3;
      } else if (v >= 0) {
        total -= 3;
      }
    }
    return total;
  }
}
