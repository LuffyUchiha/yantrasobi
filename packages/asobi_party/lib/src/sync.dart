import 'dart:async';

import 'party.dart';
import 'spec.dart';

/// Events surfaced by the sync helpers on top of raw [MatchEvent]s.
sealed class SyncEvent {
  const SyncEvent();
}

/// An opponent's telemetry changed ([ParallelRace]).
class TelemetryChanged extends SyncEvent {
  const TelemetryChanged(this.seat);
  final int seat;
}

/// An opponent sent an attack/event ([ParallelRace.attack]).
class AttackReceived extends SyncEvent {
  const AttackReceived(this.seat, this.payload);
  final int seat;
  final Map<String, Object?> payload;
}

/// A move was applied, locally or from the network ([TurnSync]).
class MoveApplied extends SyncEvent {
  const MoveApplied(this.seat, this.move, this.nextSeat);
  final int seat;
  final Map<String, Object?> move;
  final int nextSeat;
}

/// Copies disagree; the match can no longer be trusted. The console should
/// end the match as a draw and tell the players.
class DesyncDetected extends SyncEvent {
  const DesyncDetected(this.reason);
  final String reason;
}

class SeatDropped extends SyncEvent {
  const SeatDropped(this.seat);
  final int seat;
}

class SeatDone extends SyncEvent {
  const SeatDone(this.result);
  final SeatResult result;
}

class MatchEnded extends SyncEvent {
  const MatchEnded(this.standings);
  final List<SeatResult> standings;
}

abstract class _SyncBase {
  _SyncBase(this.match) {
    _sub = match.events.listen(_onEvent, onDone: () => _out.close());
  }

  final PartyMatch match;
  late final StreamSubscription<MatchEvent> _sub;
  final StreamController<SyncEvent> _out = StreamController<SyncEvent>.broadcast(sync: true);
  bool _desynced = false;

  Stream<SyncEvent> get events => _out.stream;
  bool get desynced => _desynced;

  void _emit(SyncEvent e) {
    if (!_out.isClosed) _out.add(e);
  }

  void _desync(String reason) {
    if (_desynced) return;
    _desynced = true;
    _emit(DesyncDetected(reason));
  }

  void _onEvent(MatchEvent e) {
    switch (e) {
      case MatchData(:final seat, :final body):
        onData(seat, body);
      case SeatLeft(:final seat):
        onSeatLeft(seat);
        _emit(SeatDropped(seat));
      case SeatFinished(:final result):
        _emit(SeatDone(result));
      case MatchOver(:final standings):
        _emit(MatchEnded(standings));
    }
  }

  void onData(int seat, Map<String, Object?> body);
  void onSeatLeft(int seat) {}

  Future<void> dispose() => _sub.cancel();
}

// ------------------------------------------------------------------ parallel

class Telemetry {
  const Telemetry({this.score = 0, this.progress, this.alive = true, this.extra = const {}});

  final int score;

  /// 0..1 through a level/track, if the game has one (drives a race bar).
  final double? progress;
  final bool alive;

  /// Game-specific, e.g. a ghost position {'x': .., 'y': ..}.
  final Map<String, Object?> extra;
}

/// Same seed, separate worlds, live scoreboard. Turns any deterministic
/// single-player cartridge into a head-to-head race. Optional [attack]s let a
/// cartridge add interaction (e.g. cleared rows push junk to the opponent).
class ParallelRace extends _SyncBase {
  ParallelRace(
    super.match, {
    this.minInterval = const Duration(milliseconds: 150),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Telemetry is throttled to this rate; changes in [Telemetry.alive] always go out.
  final Duration minInterval;
  final DateTime Function() _clock;
  final Map<int, Telemetry> _opponents = {};
  DateTime? _lastSent;
  bool _lastAlive = true;

  Map<int, Telemetry> get opponents => Map.unmodifiable(_opponents);

  /// Report local progress. Cheap to call every frame; it self-throttles.
  /// Returns true if a packet was sent.
  bool report({
    required int score,
    double? progress,
    bool alive = true,
    Map<String, Object?> extra = const {},
  }) {
    final now = _clock();
    final due = _lastSent == null || now.difference(_lastSent!) >= minInterval || alive != _lastAlive;
    if (!due) return false;
    _lastSent = now;
    _lastAlive = alive;
    match.send({'k': 'tel', 's': score, 'p': progress, 'a': alive, 'x': extra});
    return true;
  }

  /// Sends a one-off gameplay event to every opponent.
  void attack(Map<String, Object?> payload) => match.send({'k': 'atk', 'x': payload});

  void finish({required int score, bool? won}) {
    report(score: score, alive: false);
    match.finish(score: score, won: won);
  }

  /// Best-first ranking of everyone's latest known score, including self.
  List<int> liveRanking(int localScore) {
    final scores = {match.localSeat: localScore, for (final e in _opponents.entries) e.key: e.value.score};
    return scores.keys.toList()..sort((a, b) => scores[b]!.compareTo(scores[a]!));
  }

  @override
  void onData(int seat, Map<String, Object?> body) {
    switch (body['k']) {
      case 'tel':
        _opponents[seat] = Telemetry(
          score: (body['s'] as num?)?.toInt() ?? 0,
          progress: (body['p'] as num?)?.toDouble(),
          alive: body['a'] != false,
          extra: (body['x'] as Map?)?.cast<String, Object?>() ?? const {},
        );
        _emit(TelemetryChanged(seat));
      case 'atk':
        _emit(AttackReceived(seat, (body['x'] as Map?)?.cast<String, Object?>() ?? const {}));
    }
  }
}

// ---------------------------------------------------------------- turn-based

/// Ordered move log for turn-based games.
///
/// The game's own rules decide whose turn is next ([apply] returns it), so
/// "pot a ball, shoot again" or "roll a six, roll again" need no special
/// cases. Every copy applies the same moves in the same order; each move
/// carries the sender's idea of the next seat so a disagreement is caught.
class TurnSync extends _SyncBase {
  TurnSync(super.match, {required int firstSeat, required this.apply}) : _current = firstSeat;

  /// Applies [move] by [seat] to the game state; returns the next seat.
  final int Function(int seat, Map<String, Object?> move) apply;

  int _current;
  int _count = 0;
  final Set<int> _skipped = {};

  int get currentSeat => _current;
  int get moveCount => _count;

  /// True when a player on this phone should act now.
  bool get isMyTurn => !match.isOver && match.isLocal(_current);

  /// Plays [move] for the current (local) seat.
  void submit(Map<String, Object?> move) {
    if (!isMyTurn) throw StateError('Not your turn (seat $_current to play)');
    if (_desynced) return;
    final seat = _current;
    final next = _advance(seat, move);
    match.send({'k': 'mv', 'n': _count - 1, 'seat': seat, 'next': next, 'mv': move});
  }

  int _advance(int seat, Map<String, Object?> move) {
    var next = apply(seat, move);
    _count++;
    // Skip seats that have left so the game doesn't wait on them forever.
    for (var guard = 0; _skipped.contains(next) && guard < match.playerCount; guard++) {
      next = (next + 1) % match.playerCount;
    }
    _current = next;
    _emit(MoveApplied(seat, move, next));
    return next;
  }

  @override
  void onData(int seat, Map<String, Object?> body) {
    if (body['k'] != 'mv' || _desynced) return;
    final n = (body['n'] as num?)?.toInt();
    if (seat != _current || body['seat'] != seat) {
      _desync('seat $seat moved out of turn (expected $_current)');
      return;
    }
    if (n != _count) {
      _desync('move $n arrived, expected $_count');
      return;
    }
    final move = (body['mv'] as Map?)?.cast<String, Object?>() ?? const {};
    final next = _advance(seat, move);
    if (body['next'] != next) _desync('seat $seat thinks ${body['next']} is next, we think $next');
  }

  @override
  void onSeatLeft(int seat) {
    _skipped.add(seat);
    if (_current == seat && _skipped.length < match.playerCount) {
      var next = seat;
      do {
        next = (next + 1) % match.playerCount;
      } while (_skipped.contains(next));
      _current = next;
    }
  }
}

// ------------------------------------------------------------------ lockstep

/// Deterministic real-time sync: nobody simulates tick T until they hold
/// every seat's input for T. Local input is scheduled [inputDelay] ticks
/// ahead, so remote input normally arrives before it is needed and the game
/// never visibly waits on a decent connection.
///
/// Drive it from the game's fixed-step loop:
///
/// ```dart
/// while (accumulator >= dt) {
///   final inputs = lockstep.step({lockstep.match.localSeat: currentSwipe});
///   if (inputs == null) break; // waiting for the network: render "waiting"
///   world.step(inputs);
///   accumulator -= dt;
/// }
/// ```
class Lockstep extends _SyncBase {
  Lockstep(super.match, {int? inputDelay, this.checksumEvery = 30})
    : inputDelay = inputDelay ?? match.spec.inputDelayTicks.clamp(1, 1 << 16) {
    for (var t = 0; t < this.inputDelay; t++) {
      _inputs[t] = {for (var s = 0; s < match.playerCount; s++) s: null};
    }
  }

  final int inputDelay;

  /// Ticks between state checksums; 0 disables desync detection.
  final int checksumEvery;

  final Map<int, Map<int, Object?>> _inputs = {};
  final Map<int, Map<int, int>> _checksums = {};
  final Set<int> _gone = {};
  int _tick = 0;
  int _scheduled = -1;

  /// Next tick to simulate.
  int get tick => _tick;

  /// True when the last [step] could not advance.
  bool stalled = false;

  /// Schedules [localInputs] (seat → JSON-compatible input, null = idle) and,
  /// if everyone's input for [tick] is here, returns all inputs for it and
  /// advances. Returns null while waiting on the network.
  Map<int, Object?>? step(Map<int, Object?> localInputs) {
    final target = _tick + inputDelay;
    if (_scheduled < target && !_desynced) {
      _scheduled = target;
      final slot = _inputs[target] ??= {};
      for (final seat in match.localSeats) {
        final input = localInputs[seat.index];
        slot[seat.index] = input;
        match.send({'k': 'in', 't': target, 's': seat.index, 'i': input});
      }
    }
    final slot = _inputs[_tick] ?? const {};
    for (var s = 0; s < match.playerCount; s++) {
      if (!slot.containsKey(s) && !_gone.contains(s)) {
        stalled = true;
        return null;
      }
    }
    stalled = false;
    _inputs.remove(_tick);
    _tick++;
    return {for (var s = 0; s < match.playerCount; s++) s: slot[s]};
  }

  /// Call after simulating tick `tick - 1` with a hash of the world state.
  /// Compared across copies every [checksumEvery] ticks.
  void checksum(int simulatedTick, int hash) {
    if (checksumEvery <= 0 || simulatedTick % checksumEvery != 0) return;
    if (match.connection == Connection.sameDevice) return; // one copy, nothing to compare
    final mine = match.localSeat;
    _recordChecksum(simulatedTick, mine, hash);
    match.send({'k': 'ck', 't': simulatedTick, 'h': hash});
  }

  void _recordChecksum(int t, int seat, int hash) {
    final m = _checksums[t] ??= {};
    m[seat] = hash;
    if (m.values.toSet().length > 1) _desync('state differs at tick $t');
    if (m.length >= match.playerCount - _gone.length) _checksums.remove(t);
  }

  @override
  void onData(int seat, Map<String, Object?> body) {
    switch (body['k']) {
      case 'in':
        final t = (body['t'] as num).toInt();
        if (t < _tick) return; // stale duplicate
        final claimed = (body['s'] as num?)?.toInt();
        if (claimed != seat) return; // seats may only drive themselves
        (_inputs[t] ??= {})[seat] = body['i'];
      case 'ck':
        _recordChecksum((body['t'] as num).toInt(), seat, (body['h'] as num).toInt());
    }
  }

  @override
  void onSeatLeft(int seat) => _gone.add(seat);
}
