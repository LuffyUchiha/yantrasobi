import 'dart:async';
import 'dart:math' as math;

import 'room.dart';
import 'spec.dart';

/// Bump when party messages change incompatibly. Members on another protocol
/// version are shown but cannot be part of a match.
const int kPartyProtocol = 1;

enum PartyPhase { connecting, lobby, inMatch, closed }

class PartyMember {
  PartyMember({required this.id, required this.name, required this.isSelf, this.games = const {}});

  final String id;
  String name;
  final bool isSelf;
  InstalledGames games;
  int protocol = kPartyProtocol;
  bool ready = false;

  bool get compatible => protocol == kPartyProtocol;
}

/// One player slot in a match. Seats are numbered from 0 in party join order.
class Seat {
  Seat(this.index, this.name, {required this.isLocal, this.peerId});

  final int index;
  final String name;
  final bool isLocal;

  /// Relay id of the owning member; null for same-device seats.
  final String? peerId;
  bool connected = true;
}

class SeatResult {
  const SeatResult({required this.seat, required this.score, this.won, this.forfeit = false});

  final int seat;
  final int score;
  final bool? won;

  /// The player left before finishing.
  final bool forfeit;

  Map<String, Object?> toJson() => {'seat': seat, 'score': score, 'won': won, 'forfeit': forfeit};
}

/// Everything that can arrive on a [Match] channel.
sealed class MatchEvent {
  const MatchEvent();
}

/// Game data sent by another seat with [Match.send].
class MatchData extends MatchEvent {
  const MatchData(this.seat, this.body);
  final int seat;
  final Map<String, Object?> body;
}

class SeatLeft extends MatchEvent {
  const SeatLeft(this.seat);
  final int seat;
}

class SeatFinished extends MatchEvent {
  const SeatFinished(this.result);
  final SeatResult result;
}

/// Every seat has finished or left. [standings] is best-first.
class MatchOver extends MatchEvent {
  const MatchOver(this.standings);
  final List<SeatResult> standings;
}

/// A running multiplayer game. Handed to the cartridge alongside its normal
/// single-player context; [seed] replaces the cartridge's own random seed so
/// every copy generates the same world.
class Match {
  Match._({
    required this.id,
    required this.gameId,
    required this.seed,
    required this.seats,
    required this.spec,
    required this.connection,
    required void Function(Map<String, Object?> body) send,
    required void Function(SeatResult result) finish,
  }) : _send = send,
       _finish = finish;

  final String id;
  final String gameId;
  final int seed;
  final List<Seat> seats;
  final MultiplayerSpec spec;
  final Connection connection;

  final void Function(Map<String, Object?> body) _send;
  final void Function(SeatResult result) _finish;

  // Single-subscription so nothing that arrives before the game has wired up
  // its sync helper is lost.
  final StreamController<MatchEvent> _events = StreamController<MatchEvent>();
  final Map<int, SeatResult> _results = {};
  List<SeatResult>? _standings;

  /// Events from the other seats. Listen once (normally via a sync helper).
  Stream<MatchEvent> get events => _events.stream;

  int get playerCount => seats.length;
  bool isLocal(int seat) => seats[seat].isLocal;
  Iterable<Seat> get localSeats => seats.where((s) => s.isLocal);

  /// The local seat for online play (one per phone); the first seat on a
  /// shared device.
  int get localSeat => localSeats.first.index;

  bool get isOver => _standings != null;
  List<SeatResult>? get standings => _standings;
  Map<int, SeatResult> get results => Map.unmodifiable(_results);

  /// Broadcasts JSON-compatible [body] to every other seat.
  void send(Map<String, Object?> body) {
    if (!isOver) _send(body);
  }

  /// Records the final result for a local [seat] (defaults to [localSeat]).
  void finish({required int score, bool? won, int? seat}) {
    final s = seat ?? localSeat;
    if (!isLocal(s)) throw StateError('Seat $s is not local');
    if (_results.containsKey(s) || isOver) return;
    final result = SeatResult(seat: s, score: score, won: won);
    _record(result);
    _finish(result);
  }

  void _record(SeatResult result) {
    if (_results.containsKey(result.seat) || isOver) return;
    _results[result.seat] = result;
    _emit(SeatFinished(result));
    _maybeOver();
  }

  void _seatLeft(int seat) {
    if (!seats[seat].connected) return;
    seats[seat].connected = false;
    _emit(SeatLeft(seat));
    if (!_results.containsKey(seat) && !isOver) {
      _results[seat] = SeatResult(seat: seat, score: 0, won: false, forfeit: true);
    }
    _maybeOver();
  }

  void _data(int seat, Map<String, Object?> body) => _emit(MatchData(seat, body));

  void _maybeOver() {
    if (isOver || _results.length < seats.length) return;
    _standings = rankResults(_results.values);
    _emit(MatchOver(_standings!));
    _events.close();
  }

  void _emit(MatchEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _abort() {
    if (isOver) return;
    _standings = rankResults(_results.values);
    _emit(MatchOver(_standings!));
    _events.close();
  }
}

/// Orders results best-first: explicit winners, then score-attack/undecided,
/// then losers and forfeits; higher score breaks ties.
List<SeatResult> rankResults(Iterable<SeatResult> results) {
  int bucket(SeatResult r) => r.forfeit ? 3 : (r.won == true ? 0 : (r.won == null ? 1 : 2));
  final list =
      results.toList()..sort((a, b) {
        final c = bucket(a).compareTo(bucket(b));
        if (c != 0) return c;
        final s = b.score.compareTo(a.score);
        return s != 0 ? s : a.seat.compareTo(b.seat);
      });
  return list;
}

/// Lobby + match orchestration for one phone.
///
/// Online: the relay only forwards messages. The first member in join order
/// is the host (if they leave, the next one takes over). The host picks the
/// game and starts the match; every member independently computes which games
/// are eligible from the hellos it received, so the filtered library agrees on
/// every phone.
///
/// Same device: no relay; all seats are local and the device is the host.
class PartyController {
  PartyController.online(
    RoomLink link, {
    required String name,
    required List<GameEntry> catalog,
    math.Random? random,
  }) : _link = link,
       _selfName = name,
       _catalog = List.unmodifiable(catalog),
       _random = random ?? math.Random(),
       connection = Connection.online,
       _phase = PartyPhase.connecting {
    _sub = link.events.listen(_onRoomEvent);
  }

  PartyController.sameDevice({
    required List<String> players,
    required List<GameEntry> catalog,
    math.Random? random,
  }) : _link = null,
       _selfName = players.isEmpty ? 'Player 1' : players.first,
       _catalog = List.unmodifiable(catalog),
       _random = random ?? math.Random(),
       connection = Connection.sameDevice,
       _phase = PartyPhase.lobby {
    if (players.length < 2) throw ArgumentError('A same-device party needs at least 2 players');
    for (var i = 0; i < players.length; i++) {
      final id = 'local$i';
      _order.add(id);
      _members[id] = PartyMember(id: id, name: players[i], isSelf: true)..ready = true;
    }
    _selfId = _order.first;
  }

  final RoomLink? _link;
  final String _selfName;
  final List<GameEntry> _catalog;
  final math.Random _random;
  final Connection connection;
  StreamSubscription<RoomEvent>? _sub;

  PartyPhase _phase;
  String? _code;
  String? _selfId;
  final List<String> _order = [];
  final Map<String, PartyMember> _members = {};
  String? _selected;
  Match? _match;
  List<SeatResult>? _lastStandings;
  String? _closeReason;
  final Map<String, List<(String, Map<String, Object?>)>> _early = {};

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<Match> _matches = StreamController<Match>.broadcast();

  /// Fires whenever anything visible in the lobby changes.
  Stream<void> get changes => _changes.stream;

  /// Fires once per match start on every member. The console reacts by
  /// launching the cartridge with this match attached.
  Stream<Match> get matches => _matches.stream;

  PartyPhase get phase => _phase;

  /// Code friends type to join (online only).
  String? get code => _code;
  String? get selfId => _selfId;
  String? get closeReason => _closeReason;

  List<PartyMember> get members => [for (final id in _order) _members[id]!];
  String? get hostId => _order.isEmpty ? null : _order.first;
  bool get isHost => connection == Connection.sameDevice || (_selfId != null && hostId == _selfId);

  PartyShape get shape => PartyShape(_order.length, connection);

  String? get selectedGameId => _selected;
  Match? get match => _match;
  List<SeatResult>? get lastStandings => _lastStandings;

  Map<String, String> get _localGames => {for (final g in _catalog) g.id: g.version};

  /// The library while this party is active: only games every member can
  /// play together in the party's current shape.
  List<GameEntry> get eligible {
    if (_order.length < 2) return const [];
    final others =
        connection == Connection.online
            ? [
              for (final m in members)
                if (!m.isSelf) m.games,
            ]
            : const <InstalledGames>[];
    if (members.any((m) => !m.compatible)) return const [];
    return eligibleGames(_catalog, shape, members: others);
  }

  bool get allReady => _order.length >= 2 && members.every((m) => m.ready);

  bool get canStart =>
      isHost &&
      _phase == PartyPhase.lobby &&
      _selected != null &&
      allReady &&
      eligible.any((g) => g.id == _selected);

  // ---------------------------------------------------------------- actions

  /// Host only: choose the game everyone will play (null clears it).
  void select(String? gameId) {
    if (!isHost) throw StateError('Only the host picks the game');
    if (gameId != null && !eligible.any((g) => g.id == gameId)) {
      throw ArgumentError('$gameId is not playable by this party');
    }
    _selected = gameId;
    for (final m in members) {
      if (!m.isSelf) m.ready = false;
    }
    _link?.broadcast({'t': 'select', 'game': gameId});
    _changed();
  }

  void setReady(bool ready) {
    final me = _members[_selfId];
    if (me == null || connection == Connection.sameDevice) return;
    me.ready = ready;
    _link?.broadcast({'t': 'ready', 'ready': ready});
    _changed();
  }

  /// Host only: start the selected game for everyone. Returns the local match.
  Match start() {
    if (!canStart) throw StateError('Cannot start: pick an eligible game and wait for everyone');
    final matchId = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_random.nextInt(1 << 20)}';
    final seed = _random.nextInt(1 << 31);
    _link?.broadcast({'t': 'start', 'match': matchId, 'game': _selected, 'seed': seed, 'seats': _order});
    return _beginMatch(matchId, _selected!, seed, List.of(_order));
  }

  /// Host only: abandon the current match and return everyone to the lobby.
  void abortMatch() {
    if (!isHost || _match == null) return;
    _link?.broadcast({'t': 'abort', 'match': _match!.id});
    _endMatch(aborted: true);
  }

  Future<void> leave() async {
    if (_phase == PartyPhase.closed) return;
    _match?._abort();
    await _sub?.cancel();
    await _link?.close();
    _close('left');
  }

  // ----------------------------------------------------------------- match

  Match _beginMatch(String matchId, String gameId, int seed, List<String> seatIds) {
    final spec = _catalog.firstWhere((g) => g.id == gameId).spec!;
    final seats = [
      for (var i = 0; i < seatIds.length; i++)
        Seat(
          i,
          _members[seatIds[i]]?.name ?? 'Player ${i + 1}',
          isLocal: _members[seatIds[i]]?.isSelf ?? false,
          peerId: connection == Connection.online ? seatIds[i] : null,
        ),
    ];
    late final Match match;
    match = Match._(
      id: matchId,
      gameId: gameId,
      seed: seed,
      seats: seats,
      spec: spec,
      connection: connection,
      send: (body) => _link?.broadcast({'t': 'm', 'match': matchId, 'body': body}),
      finish: (r) {
        _link?.broadcast({'t': 'done', 'match': matchId, 'seat': r.seat, 'score': r.score, 'won': r.won});
        _afterMatchUpdate();
      },
    );
    _match = match;
    _phase = PartyPhase.inMatch;
    // Seats whose members vanished between select and start forfeit at once.
    for (final s in seats) {
      if (s.peerId != null && !_members.containsKey(s.peerId)) match._seatLeft(s.index);
    }
    for (final (from, msg) in _early.remove(matchId) ?? const <(String, Map<String, Object?>)>[]) {
      _onMatchMessage(from, msg);
    }
    _matches.add(match);
    _changed();
    return match;
  }

  void _afterMatchUpdate() {
    final m = _match;
    if (m != null && m.isOver) _endMatch();
  }

  void _endMatch({bool aborted = false}) {
    final m = _match;
    if (m == null) return;
    if (aborted) m._abort();
    _lastStandings = m.standings;
    _match = null;
    if (_phase == PartyPhase.inMatch) _phase = PartyPhase.lobby;
    for (final mem in members) {
      if (connection == Connection.online) mem.ready = false;
    }
    _changed();
  }

  int? _seatOf(Match m, String peerId) {
    for (final s in m.seats) {
      if (s.peerId == peerId) return s.index;
    }
    return null;
  }

  void _onMatchMessage(String from, Map<String, Object?> msg) {
    final m = _match;
    if (m == null || msg['match'] != m.id) return;
    final seat = _seatOf(m, from);
    if (seat == null) return;
    switch (msg['t']) {
      case 'm':
        final body = msg['body'];
        if (body is Map) m._data(seat, body.cast<String, Object?>());
      case 'done':
        final claimed = msg['seat'];
        if (claimed != seat) return; // members may only report their own seat
        m._record(
          SeatResult(seat: seat, score: (msg['score'] as num?)?.toInt() ?? 0, won: msg['won'] as bool?),
        );
        _afterMatchUpdate();
      case 'abort':
        if (from == hostId) _endMatch(aborted: true);
    }
  }

  // ----------------------------------------------------------------- relay

  Map<String, Object?> _hello() => {
    't': 'hello',
    'proto': kPartyProtocol,
    'name': _selfName,
    'games': _localGames,
    'ready': _members[_selfId]?.ready ?? false,
    if (isHost) 'selected': _selected,
  };

  void _onRoomEvent(RoomEvent e) {
    switch (e) {
      case RoomJoined(:final code, :final selfId, :final peers):
        _code = code;
        _selfId = selfId;
        _order
          ..clear()
          ..addAll(peers);
        for (final id in peers) {
          _members[id] =
              id == selfId
                  ? PartyMember(id: id, name: _selfName, isSelf: true, games: _localGames)
                  : PartyMember(id: id, name: '…', isSelf: false);
        }
        _phase = PartyPhase.lobby;
        _link!.broadcast(_hello());
      case PeerJoined(:final peerId):
        _order.add(peerId);
        _members[peerId] = PartyMember(id: peerId, name: '…', isSelf: false);
        _link!.sendTo(peerId, _hello());
      case PeerLeft(:final peerId):
        _order.remove(peerId);
        _members.remove(peerId);
        final m = _match;
        if (m != null) {
          final seat = _seatOf(m, peerId);
          if (seat != null) m._seatLeft(seat);
          _afterMatchUpdate();
        }
        // A game that no longer fits the smaller party is deselected.
        if (_selected != null && !eligible.any((g) => g.id == _selected)) _selected = null;
      case RoomMessage(:final from, :final body):
        _onMessage(from, body);
      case RoomClosed(:final reason):
        _match?._abort();
        _close(reason);
        return;
    }
    _changed();
  }

  void _onMessage(String from, Map<String, Object?> msg) {
    final member = _members[from];
    if (member == null) return;
    switch (msg['t']) {
      case 'hello':
        member
          ..name = (msg['name'] as String?)?.trim().isNotEmpty == true ? msg['name'] as String : 'Player'
          ..protocol = (msg['proto'] as num?)?.toInt() ?? 0
          ..ready = msg['ready'] == true
          ..games = {
            for (final e in ((msg['games'] as Map?) ?? const {}).entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
          };
        if (from == hostId && msg.containsKey('selected')) _selected = msg['selected'] as String?;
      case 'select':
        if (from != hostId) return;
        _selected = msg['game'] as String?;
        for (final m in members) {
          if (m.id != hostId) m.ready = false;
        }
      case 'ready':
        member.ready = msg['ready'] == true;
      case 'start':
        if (from != hostId || _phase != PartyPhase.lobby) return;
        final game = msg['game'] as String?;
        final seats = (msg['seats'] as List?)?.whereType<String>().toList();
        if (game == null || seats == null || !_catalog.any((g) => g.id == game && g.spec != null)) return;
        if (!seats.contains(_selfId)) return; // joined after the host pressed start
        _beginMatch(msg['match'] as String, game, (msg['seed'] as num).toInt(), seats);
      case 'm' || 'done' || 'abort':
        final id = msg['match'];
        if (_match?.id == id) {
          _onMatchMessage(from, msg);
        } else if (id is String && _phase != PartyPhase.inMatch) {
          // Arrived before the host's start reached us; replay after start.
          (_early[id] ??= []).add((from, msg));
        }
    }
  }

  void _close(String reason) {
    _phase = PartyPhase.closed;
    _closeReason = reason;
    _changed();
    _changes.close();
    _matches.close();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
