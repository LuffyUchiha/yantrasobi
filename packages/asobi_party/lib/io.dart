/// dart:io pieces of the party layer: the WebSocket relay server and a
/// [RoomLink] that talks to it. Kept out of `asobi_party.dart` so the core
/// stays usable on Flutter web (which would use a web_socket_channel adapter).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/room.dart';

export 'src/room.dart';

/// Wire version of the relay protocol, sent as the `v` query parameter.
const int kRelayProtocol = 1;

/// Stateless-per-message WebSocket relay. One process can host thousands of
/// small rooms; it never inspects message bodies.
///
/// Client → server (JSON text frames):
///   `{"op":"create"}` · `{"op":"join","room":"K7QF3M"}` · `{"op":"send","body":{...},"to":"p3"?}`
/// Server → client:
///   `{"ev":"joined","room","self","peers"}` · `{"ev":"peer_joined","id"}` ·
///   `{"ev":"peer_left","id"}` · `{"ev":"msg","from","body"}` · `{"ev":"error","code","message"}`
class RelayServer {
  RelayServer._(this._http, this.registry, this.maxFrameBytes, this.maxMessagesPerSecond);

  final HttpServer _http;
  final RoomRegistry registry;
  final int maxFrameBytes;
  final int maxMessagesPerSecond;
  final Set<_RelayConn> _conns = {};

  int get port => _http.port;
  int get connectionCount => _conns.length;

  static Future<RelayServer> start({
    Object address = '0.0.0.0',
    int port = 8787,
    int maxPerRoom = 8,
    int maxFrameBytes = 16 * 1024,
    int maxMessagesPerSecond = 120,
  }) async {
    final http = await HttpServer.bind(address, port);
    final server = RelayServer._(
      http,
      RoomRegistry(maxPerRoom: maxPerRoom),
      maxFrameBytes,
      maxMessagesPerSecond,
    );
    http.listen(server._onRequest);
    return server;
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.uri.path == '/healthz') {
      req.response
        ..statusCode = HttpStatus.ok
        ..write('ok rooms=${registry.roomCount} conns=${_conns.length}');
      await req.response.close();
      return;
    }
    if (req.uri.path != '/v1/party' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 15);
    final conn = _RelayConn(this, ws);
    _conns.add(conn);
    ws.listen(conn.onFrame, onDone: conn.onClosed, onError: (_) => conn.onClosed(), cancelOnError: true);
  }

  Future<void> close() async {
    for (final c in _conns.toList()) {
      await c.ws.close(WebSocketStatus.goingAway);
    }
    await _http.close(force: true);
  }
}

class _RelayConn implements RoomMemberSink {
  _RelayConn(this.server, this.ws) {
    _hello = Timer(const Duration(seconds: 10), () {
      if (_room == null) ws.close(WebSocketStatus.policyViolation, 'no create/join');
    });
  }

  final RelayServer server;
  final WebSocket ws;
  late final Timer _hello;
  String? _room;
  String? _id;
  int _windowStart = 0;
  int _windowCount = 0;

  @override
  void deliver(RoomEvent event) {
    final json = switch (event) {
      RoomJoined(:final code, :final selfId, :final peers) => {
        'ev': 'joined',
        'room': code,
        'self': selfId,
        'peers': peers,
      },
      PeerJoined(:final peerId) => {'ev': 'peer_joined', 'id': peerId},
      PeerLeft(:final peerId) => {'ev': 'peer_left', 'id': peerId},
      RoomMessage(:final from, :final body) => {'ev': 'msg', 'from': from, 'body': body},
      RoomClosed(:final reason) => {'ev': 'error', 'code': 'closed', 'message': reason},
    };
    ws.add(jsonEncode(json));
  }

  void _error(String code, String message) =>
      ws.add(jsonEncode({'ev': 'error', 'code': code, 'message': message}));

  void onFrame(dynamic frame) {
    if (frame is! String || frame.length > server.maxFrameBytes) {
      ws.close(WebSocketStatus.messageTooBig, 'frame too large');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now != _windowStart) {
      _windowStart = now;
      _windowCount = 0;
    }
    if (++_windowCount > server.maxMessagesPerSecond) {
      ws.close(WebSocketStatus.policyViolation, 'rate limit');
      return;
    }
    Map<String, Object?> msg;
    try {
      msg = (jsonDecode(frame) as Map).cast<String, Object?>();
    } catch (_) {
      _error('bad_json', 'Frames must be JSON objects');
      return;
    }
    switch (msg['op']) {
      case 'create' when _room == null:
        final (code, id) = server.registry.create(this);
        _room = code;
        _id = id;
      case 'join' when _room == null:
        try {
          final code = normaliseRoomCode('${msg['room']}');
          _id = server.registry.join(code, this);
          _room = code;
        } on RoomError catch (e) {
          _error(e.code, e.message);
        }
      case 'send' when _room != null:
        final body = msg['body'];
        if (body is! Map) return;
        final to = msg['to'];
        server.registry.forward(_room!, _id!, body.cast<String, Object?>(), to: to is String ? to : null);
      default:
        _error('bad_op', 'Unexpected op ${msg['op']}');
    }
  }

  void onClosed() {
    _hello.cancel();
    server._conns.remove(this);
    if (_room != null) server.registry.leave(_room!, _id!);
    _room = null;
  }
}

/// [RoomLink] over the relay's WebSocket protocol.
class WebSocketRoomLink implements RoomLink {
  WebSocketRoomLink._(this._ws) {
    _ws.listen(
      _onFrame,
      onDone: () => _finish(_ws.closeReason ?? 'disconnected'),
      onError: (Object e) => _finish('$e'),
      cancelOnError: true,
    );
  }

  final WebSocket _ws;
  final StreamController<RoomEvent> _events = StreamController<RoomEvent>();
  bool _done = false;

  /// Opens a new party. [relay] is e.g. `wss://party.example.com`.
  static Future<WebSocketRoomLink> create(Uri relay) => _open(relay, {'op': 'create'});

  /// Joins the party with [code]. A refused join surfaces as [RoomClosed].
  static Future<WebSocketRoomLink> join(Uri relay, String code) =>
      _open(relay, {'op': 'join', 'room': normaliseRoomCode(code)});

  static Future<WebSocketRoomLink> _open(Uri relay, Map<String, Object?> first) async {
    final uri = relay.replace(path: '/v1/party', queryParameters: {'v': '$kRelayProtocol'});
    final ws = await WebSocket.connect(uri.toString()).timeout(const Duration(seconds: 10));
    ws.pingInterval = const Duration(seconds: 15);
    final link = WebSocketRoomLink._(ws);
    ws.add(jsonEncode(first));
    return link;
  }

  @override
  Stream<RoomEvent> get events => _events.stream;

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
    final m = (jsonDecode(frame) as Map).cast<String, Object?>();
    switch (m['ev']) {
      case 'joined':
        _events.add(
          RoomJoined(m['room'] as String, m['self'] as String, (m['peers'] as List).cast<String>()),
        );
      case 'peer_joined':
        _events.add(PeerJoined(m['id'] as String));
      case 'peer_left':
        _events.add(PeerLeft(m['id'] as String));
      case 'msg':
        _events.add(RoomMessage(m['from'] as String, (m['body'] as Map).cast<String, Object?>()));
      case 'error':
        final code = m['code'];
        if (code == RoomError.notFound || code == RoomError.full) {
          _finish('$code');
          _ws.close();
        }
    }
  }

  void _finish(String reason) {
    if (_done) return;
    _done = true;
    _events
      ..add(RoomClosed(reason))
      ..close();
  }

  @override
  void broadcast(Map<String, Object?> body) {
    if (!_done) _ws.add(jsonEncode({'op': 'send', 'body': body}));
  }

  @override
  void sendTo(String peerId, Map<String, Object?> body) {
    if (!_done) _ws.add(jsonEncode({'op': 'send', 'body': body, 'to': peerId}));
  }

  @override
  Future<void> close() async {
    _done = true;
    await _ws.close();
    if (!_events.isClosed) await _events.close();
  }
}
