import 'dart:async';

import 'package:asobi_party/asobi_party.dart';
import 'package:flutter/foundation.dart';

import '../cartridge/registry.dart';
import '../services/settings.dart';
import 'ws_room_link.dart';

/// Opens a room on the relay: a new one when [joinCode] is null.
typedef RoomConnector = Future<RoomLink> Function({String? joinCode});

/// The console's "play together" state: at most one party at a time.
///
/// The library listens to this to shrink itself to [eligibleIds] and to
/// launch matches from [matches].
class AsobiParty extends ChangeNotifier {
  AsobiParty({required this.registry, required this.settings, this.connector});

  final CartridgeRegistry registry;
  final AsobiSettings settings;

  /// Overrides the WebSocket relay (tests use an in-memory relay).
  final RoomConnector? connector;

  PartyController? _controller;
  StreamSubscription<void>? _changes;
  StreamSubscription<PartyMatch>? _matchSub;
  final StreamController<PartyMatch> _matches = StreamController<PartyMatch>.broadcast();
  String? _error;
  bool _busy = false;

  PartyController? get controller => _controller;

  /// A party is open (lobby or match).
  bool get active => _controller != null && _controller!.phase != PartyPhase.closed;

  /// Waiting for the relay.
  bool get busy => _busy || _controller?.phase == PartyPhase.connecting;

  /// Last connection problem, shown in the party sheet.
  String? get error => _error;

  /// Every phone hears about each match start here, host included.
  Stream<PartyMatch> get matches => _matches.stream;

  /// Ids of the cartridges this party can play together.
  Set<String> get eligibleIds => {for (final g in _controller?.eligible ?? const <GameEntry>[]) g.id};

  bool get relayConfigured => connector != null || settings.relayUrl.isNotEmpty;

  String get displayName => settings.playerName.isEmpty ? 'Player' : settings.playerName;

  List<GameEntry> get _catalog => [
    for (final c in registry.all) GameEntry(c.manifest.id, c.manifest.version, c.manifest.partySpec),
  ];

  Future<RoomLink> _connect({String? joinCode}) {
    final custom = connector;
    if (custom != null) return custom(joinCode: joinCode);
    if (settings.relayUrl.isEmpty) {
      throw StateError('No party relay is set. Add one in Settings → Play together.');
    }
    return WsRoomLink.connect(settings.relayUrl, joinCode: joinCode);
  }

  /// Starts a new online party; friends join with its code.
  Future<void> host() => _online(null);

  /// Joins a friend's online party by code.
  Future<void> join(String code) => _online(normaliseRoomCode(code));

  Future<void> _online(String? code) async {
    await leave();
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final link = await _connect(joinCode: code);
      _attach(PartyController.online(link, name: displayName, catalog: _catalog));
    } on RoomError catch (e) {
      _error = '${e.message}.';
    } on Object catch (e) {
      _error = e is StateError ? e.message : 'Could not reach the party relay.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Several people sharing this phone.
  Future<void> sameDevice(List<String> names) async {
    await leave();
    _error = null;
    _attach(PartyController.sameDevice(players: names, catalog: _catalog));
    notifyListeners();
  }

  void _attach(PartyController c) {
    _controller = c;
    _changes = c.changes.listen((_) {
      if (c.phase == PartyPhase.closed && identical(_controller, c)) {
        _error = switch (c.closeReason) {
          RoomError.notFound => 'No party with that code.',
          RoomError.full => 'That party is full.',
          'left' || null => null,
          final other => 'Party ended: $other',
        };
        _detach();
      }
      notifyListeners();
    });
    _matchSub = c.matches.listen(_matches.add);
  }

  void _detach() {
    unawaited(_changes?.cancel());
    unawaited(_matchSub?.cancel());
    _changes = null;
    _matchSub = null;
    _controller = null;
  }

  Future<void> leave() async {
    final c = _controller;
    if (c == null) return;
    _detach();
    notifyListeners(); // the library returns to solo mode right away
    await c.leave();
  }

  @override
  void dispose() {
    unawaited(leave());
    _matches.close();
    super.dispose();
  }
}
