@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:asobi_party/asobi_party.dart';
import 'package:asobi_party/io.dart';
import 'package:test/test.dart';

import 'spec_test.dart' show catalog;

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late RelayServer server;
  late Uri uri;

  setUp(() async {
    server = await RelayServer.start(address: InternetAddress.loopbackIPv4, port: 0);
    uri = Uri.parse('ws://127.0.0.1:${server.port}');
  });
  tearDown(() => server.close());

  test('health endpoint answers', () async {
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/healthz'))).close();
    expect(res.statusCode, 200);
    client.close();
  });

  test('two phones over real WebSockets: join by code, start, race to a result', () async {
    final host = PartyController.online(await WebSocketRoomLink.create(uri), name: 'Asha', catalog: catalog);
    await until(() => host.code != null);
    final guest = PartyController.online(
      await WebSocketRoomLink.join(uri, host.code!.toLowerCase()),
      name: 'Ravi',
      catalog: catalog,
    );
    await until(() => host.members.length == 2 && guest.members.every((m) => m.name != '…'));
    expect([for (final g in guest.eligible) g.id], ['cloud-tower', 'cue-clash']);

    host
      ..select('cloud-tower')
      ..setReady(true);
    await until(() => guest.selectedGameId == 'cloud-tower');
    guest.setReady(true);
    await until(() => host.canStart);

    final guestMatch = guest.matches.first;
    final m1 = host.start();
    final m2 = await guestMatch.timeout(const Duration(seconds: 5));
    expect(m2.seed, m1.seed);

    final r1 = ParallelRace(m1, minInterval: Duration.zero);
    final r2 = ParallelRace(m2, minInterval: Duration.zero);
    r2.report(score: 42, progress: 0.5);
    await until(() => r1.opponents[1]?.score == 42);
    r1.finish(score: 10);
    r2.finish(score: 42);
    await until(() => host.phase == PartyPhase.lobby && guest.phase == PartyPhase.lobby);
    expect(host.lastStandings!.first.seat, 1);

    await guest.leave();
    await until(() => host.members.length == 1);
    await host.leave();
    await until(() => server.registry.roomCount == 0);
  });

  test('joining a missing room closes the link with a reason', () async {
    final link = await WebSocketRoomLink.join(uri, 'ZZZZZZ');
    final closed = await link.events.firstWhere((e) => e is RoomClosed) as RoomClosed;
    expect(closed.reason, RoomError.notFound);
  });
}
