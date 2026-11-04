import 'dart:async';
import 'dart:math' as math;

/// Something that happened in the room this link is attached to.
sealed class RoomEvent {
  const RoomEvent();
}

/// This link is now in room [code] as [selfId]. [peers] lists everyone in the
/// room **in join order** (including self); the first entry is the host.
class RoomJoined extends RoomEvent {
  const RoomJoined(this.code, this.selfId, this.peers);
  final String code;
  final String selfId;
  final List<String> peers;
}

class PeerJoined extends RoomEvent {
  const PeerJoined(this.peerId);
  final String peerId;
}

class PeerLeft extends RoomEvent {
  const PeerLeft(this.peerId);
  final String peerId;
}

/// A message from another member of the room.
class RoomMessage extends RoomEvent {
  const RoomMessage(this.from, this.body);
  final String from;
  final Map<String, Object?> body;
}

/// The link failed or was closed. No further events follow.
class RoomClosed extends RoomEvent {
  const RoomClosed(this.reason);
  final String reason;
}

/// A connection to one room of a relay. The relay is deliberately dumb: it
/// assigns ids, keeps join order and forwards messages. All lobby and match
/// logic lives in the clients, so the relay can later be swapped for any
/// realtime backend (Firebase, Supabase, Nakama, LAN) by implementing this.
abstract class RoomLink {
  Stream<RoomEvent> get events;

  /// Sends [body] to every other member.
  void broadcast(Map<String, Object?> body);

  /// Sends [body] to one member.
  void sendTo(String peerId, Map<String, Object?> body);

  Future<void> close();
}

/// Room-code alphabet without look-alikes (no 0/O, 1/I/L).
const String kRoomCodeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const int kRoomCodeLength = 6;

String normaliseRoomCode(String raw) => raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Why a create/join was refused.
class RoomError implements Exception {
  const RoomError(this.code, this.message);
  final String code;
  final String message;

  static const notFound = 'not_found';
  static const full = 'full';

  @override
  String toString() => 'RoomError($code: $message)';
}

/// Callbacks a registry uses to talk to one attached member.
abstract class RoomMemberSink {
  void deliver(RoomEvent event);
}

/// Room bookkeeping shared by the in-memory [LoopbackRelay] and the WebSocket
/// relay server, so both behave identically.
class RoomRegistry {
  RoomRegistry({this.maxPerRoom = 8, math.Random? random}) : _random = random ?? math.Random.secure();

  final int maxPerRoom;
  final math.Random _random;
  final Map<String, Map<String, RoomMemberSink>> _rooms = {};
  int _nextId = 1;

  int get roomCount => _rooms.length;
  int membersIn(String code) => _rooms[code]?.length ?? 0;

  String _newCode() {
    while (true) {
      final code = String.fromCharCodes([
        for (var i = 0; i < kRoomCodeLength; i++)
          kRoomCodeAlphabet.codeUnitAt(_random.nextInt(kRoomCodeAlphabet.length)),
      ]);
      if (!_rooms.containsKey(code)) return code;
    }
  }

  /// Creates a room and attaches [sink] as its host. Returns (code, id).
  (String, String) create(RoomMemberSink sink) {
    final code = _newCode();
    _rooms[code] = {};
    return (code, _attach(code, sink));
  }

  /// Attaches [sink] to an existing room. Returns the new member id.
  String join(String rawCode, RoomMemberSink sink) {
    final code = normaliseRoomCode(rawCode);
    final room = _rooms[code];
    if (room == null) throw const RoomError(RoomError.notFound, 'No party with that code');
    if (room.length >= maxPerRoom) throw const RoomError(RoomError.full, 'That party is full');
    return _attach(code, sink);
  }

  String _attach(String code, RoomMemberSink sink) {
    final room = _rooms[code]!;
    final id = 'p${_nextId++}';
    for (final other in room.values) {
      other.deliver(PeerJoined(id));
    }
    room[id] = sink;
    sink.deliver(RoomJoined(code, id, room.keys.toList()));
    return id;
  }

  void leave(String code, String id) {
    final room = _rooms[code];
    if (room == null || room.remove(id) == null) return;
    if (room.isEmpty) {
      _rooms.remove(code);
      return;
    }
    for (final other in room.values) {
      other.deliver(PeerLeft(id));
    }
  }

  void forward(String code, String from, Map<String, Object?> body, {String? to}) {
    final room = _rooms[code];
    if (room == null || !room.containsKey(from)) return;
    if (to != null) {
      room[to]?.deliver(RoomMessage(from, body));
      return;
    }
    room.forEach((id, sink) {
      if (id != from) sink.deliver(RoomMessage(from, body));
    });
  }
}

/// In-process relay. Used for tests, for the console's offline demo, and as
/// the reference behaviour the network relay must match.
///
/// [latency] delays every delivery, which lets tests exercise lockstep stalls
/// and out-of-order arrival between different senders.
class LoopbackRelay {
  LoopbackRelay({this.latency = Duration.zero, int maxPerRoom = 8, math.Random? random})
    : registry = RoomRegistry(maxPerRoom: maxPerRoom, random: random);

  final Duration latency;
  final RoomRegistry registry;

  RoomLink create() {
    final link = _LoopbackLink(this);
    final (code, id) = registry.create(link);
    link._code = code;
    link._id = id;
    return link;
  }

  /// Throws [RoomError] if the room is missing or full.
  RoomLink join(String code) {
    final link = _LoopbackLink(this);
    final id = registry.join(code, link);
    link._code = normaliseRoomCode(code);
    link._id = id;
    return link;
  }
}

class _LoopbackLink implements RoomLink, RoomMemberSink {
  _LoopbackLink(this._relay);

  final LoopbackRelay _relay;
  final StreamController<RoomEvent> _events = StreamController<RoomEvent>();
  late String _code;
  late String _id;
  bool _closed = false;

  @override
  Stream<RoomEvent> get events => _events.stream;

  @override
  void deliver(RoomEvent event) {
    if (_closed) return;
    if (_relay.latency == Duration.zero) {
      scheduleMicrotask(() {
        if (!_closed) _events.add(event);
      });
    } else {
      Timer(_relay.latency, () {
        if (!_closed) _events.add(event);
      });
    }
  }

  @override
  void broadcast(Map<String, Object?> body) {
    if (!_closed) _relay.registry.forward(_code, _id, body);
  }

  @override
  void sendTo(String peerId, Map<String, Object?> body) {
    if (!_closed) _relay.registry.forward(_code, _id, body, to: peerId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _relay.registry.leave(_code, _id);
    _closed = true;
    await _events.close();
  }
}
