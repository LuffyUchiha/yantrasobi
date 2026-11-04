/// Reference turn-based rules wired to [TurnSync]: a 7×6 drop-a-disc,
/// four-in-a-row board game. It is the smallest complete example of a
/// multiplayer cartridge's rules file: pure Dart, deterministic, and the only
/// network-facing part is `apply(seat, move) → nextSeat`.
library;

import 'package:asobi_party/asobi_party.dart';

class GravityFour {
  static const int cols = 7;
  static const int rows = 6;

  /// board[c][r], r = 0 is the bottom; -1 empty, otherwise seat.
  final List<List<int>> board = List.generate(cols, (_) => List.filled(rows, -1));
  int? winner;
  bool get isFull => board.every((c) => c.last != -1);
  bool get isOver => winner != null || isFull;

  bool canDrop(int col) => !isOver && col >= 0 && col < cols && board[col].last == -1;

  /// [TurnSync.apply] callback. Illegal moves (which a correct client never
  /// sends) leave the board untouched and hand the turn back.
  int apply(int seat, Map<String, Object?> move) {
    final col = (move['col'] as num?)?.toInt() ?? -1;
    if (!canDrop(col)) return seat;
    final r = board[col].indexOf(-1);
    board[col][r] = seat;
    if (_wins(col, r, seat)) winner = seat;
    return 1 - seat;
  }

  bool _wins(int c, int r, int seat) {
    const dirs = [(1, 0), (0, 1), (1, 1), (1, -1)];
    for (final (dc, dr) in dirs) {
      var n = 1;
      for (final sign in const [1, -1]) {
        var cc = c + dc * sign, rr = r + dr * sign;
        while (cc >= 0 && cc < cols && rr >= 0 && rr < rows && board[cc][rr] == seat) {
          n++;
          cc += dc * sign;
          rr += dr * sign;
        }
      }
      if (n >= 4) return true;
    }
    return false;
  }

  String snapshot() => board.map((c) => c.map((v) => v < 0 ? '.' : '$v').join()).join('|');

  static const spec = MultiplayerSpec(
    sync: SyncModel.turnBased,
    sameDevice: true,
    summary: 'Take turns dropping discs; four in a row wins',
  );
}
