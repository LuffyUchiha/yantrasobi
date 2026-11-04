import 'dart:async';
import 'dart:convert';

import 'package:asobi_party/asobi_party.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// [RoomLink] to the party relay (`packages/asobi_party/bin/relay.dart`) over
/// `web_socket_channel`, so it works on Android, iOS and web alike. Speaks the
/// same JSON as the reference client in `package:asobi_party/io.dart`.
class WsRoomLink implements RoomLink {
  WsRoomLink._(this._channel) {
    _channel.stream.listen(
      _onFrame,
      onDone: () => _finish(_channel.closeReason ?? 'disconnected'),
      onError: (Object e) => _finish('connection failed'),
      cancelOnError: true,
    );
  }

  final WebSocketChannel _channel;
  final StreamController<RoomEvent> _events = StreamController<RoomEvent>();
  bool _done = false;

  /// Turns what the player typed into the relay's party endpoint.
  /// Accepts `host:port`, `ws://…`, `wss://…`, `http(s)://…`.
  static Uri endpoint(String relay) {
    var text = relay.trim();
    if (!text.contains('://')) text = 'ws://$text';
    final base = Uri.parse(text);
    final scheme = switch (base.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };
    return base.replace(scheme: scheme, path: '/v1/party', queryParameters: {'v': '1'});
  }

  static Future<WsRoomLink> connect(String relay, {String? joinCode}) async {
    final channel = WebSocketChannel.connect(endpoint(relay));
    await channel.ready.timeout(const Duration(seconds: 10));
    final link = WsRoomLink._(channel);
    channel.sink.add(
      jsonEncode(joinCode == null ? {'op': 'create'} : {'op': 'join', 'room': normaliseRoomCode(joinCode)}),
    );
    return link;
  }

  @override
  Stream<RoomEvent> get events => _events.stream;

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
    final Map<String, Object?> m;
    try {
      m = (jsonDecode(frame) as Map).cast<String, Object?>();
    } on Object {
      return;
    }
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
        if (m['code'] == RoomError.notFound || m['code'] == RoomError.full) {
          _finish(m['code'] as String);
          unawaited(_channel.sink.close());
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
    if (!_done) _channel.sink.add(jsonEncode({'op': 'send', 'body': body}));
  }

  @override
  void sendTo(String peerId, Map<String, Object?> body) {
    if (!_done) _channel.sink.add(jsonEncode({'op': 'send', 'body': body, 'to': peerId}));
  }

  @override
  Future<void> close() async {
    _done = true;
    await _channel.sink.close();
    if (!_events.isClosed) await _events.close();
  }
}
