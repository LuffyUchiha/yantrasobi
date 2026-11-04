@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:asobi_party/asobi_party.dart';
import 'package:asobi_party/io.dart' show RelayServer;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/yantrasobi/party/ws_room_link.dart';

const games = [GameEntry('cloud-tower', '1.0.0', MultiplayerSpec(sync: SyncModel.parallel, maxPlayers: 8))];

Future<void> until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('the app transport talks to the real relay: party, start, results', () async {
    final server = await RelayServer.start(address: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(server.close);
    final relay = '127.0.0.1:${server.port}'; // what a player would type in Settings

    final host = PartyController.online(await WsRoomLink.connect(relay), name: 'Asha', catalog: games);
    await until(() => host.code != null);
    final guest = PartyController.online(
      await WsRoomLink.connect(relay, joinCode: host.code!.toLowerCase()),
      name: 'Ravi',
      catalog: games,
    );
    await until(() => host.eligible.isNotEmpty && guest.members.every((m) => m.name != '…'));

    host
      ..select('cloud-tower')
      ..setReady(true);
    await until(() => guest.selectedGameId == 'cloud-tower');
    guest.setReady(true);
    await until(() => host.canStart);
    final pending = guest.matches.first;
    final m1 = host.start();
    final m2 = await pending.timeout(const Duration(seconds: 5));
    expect(m2.seed, m1.seed);

    m1.finish(score: 5);
    m2.finish(score: 9);
    await until(() => host.phase == PartyPhase.lobby && guest.phase == PartyPhase.lobby);
    expect(host.lastStandings!.first.seat, 1);

    await guest.leave();
    await host.leave();
    await until(() => server.registry.roomCount == 0);
  });

  test('a wrong code closes the link with not_found', () async {
    final server = await RelayServer.start(address: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(server.close);
    final link = await WsRoomLink.connect('ws://127.0.0.1:${server.port}', joinCode: 'ZZZZZZ');
    final closed = await link.events.firstWhere((e) => e is RoomClosed) as RoomClosed;
    expect(closed.reason, RoomError.notFound);
  });
}
