import 'package:asobi_party/asobi_party.dart';
import 'package:test/test.dart';

import 'spec_test.dart' show catalog;

Future<void> settle() => pumpEventQueue(times: 50);

PartyController joinAs(LoopbackRelay relay, String code, String name, [List<GameEntry>? games]) =>
    PartyController.online(relay.join(code), name: name, catalog: games ?? catalog);

void main() {
  late LoopbackRelay relay;
  setUp(() => relay = LoopbackRelay());

  test('create, join by code, everyone sees the same roster and host', () async {
    final host = PartyController.online(relay.create(), name: 'Asha', catalog: catalog);
    await settle();
    expect(host.phase, PartyPhase.lobby);
    expect(host.code, hasLength(kRoomCodeLength));
    expect(host.isHost, isTrue);

    final guest = joinAs(relay, host.code!.toLowerCase(), 'Ravi');
    await settle();
    for (final p in [host, guest]) {
      expect([for (final m in p.members) m.name], ['Asha', 'Ravi']);
      expect(p.hostId, host.selfId);
    }
    expect(guest.isHost, isFalse);
  });

  test('a solo party shows no games; a friend joining unlocks the multiplayer list', () async {
    final host = PartyController.online(relay.create(), name: 'A', catalog: catalog);
    await settle();
    expect(host.eligible, isEmpty);
    joinAs(relay, host.code!, 'B');
    await settle();
    expect([for (final g in host.eligible) g.id], ['cloud-tower', 'cue-clash']);
    joinAs(relay, host.code!, 'C');
    await settle();
    expect([for (final g in host.eligible) g.id], ['cloud-tower'], reason: 'cue-clash is 2-player only');
  });

  test('a friend on an older cartridge version filters that game out on both phones', () async {
    final host = PartyController.online(relay.create(), name: 'A', catalog: catalog);
    await settle();
    final older = [for (final g in catalog) g.id == 'cloud-tower' ? GameEntry(g.id, '0.9.0', g.spec) : g];
    final guest = joinAs(relay, host.code!, 'B', older);
    await settle();
    expect([for (final g in host.eligible) g.id], ['cue-clash']);
    expect([for (final g in guest.eligible) g.id], ['cue-clash']);
  });

  test('host picks, everyone readies, start shares one seed and seat order', () async {
    final host = PartyController.online(relay.create(), name: 'A', catalog: catalog);
    await settle();
    final guest = joinAs(relay, host.code!, 'B');
    await settle();

    expect(() => guest.select('cloud-tower'), throwsStateError);
    expect(() => host.select('jam-tray'), throwsArgumentError);
    host.select('cloud-tower');
    await settle();
    expect(guest.selectedGameId, 'cloud-tower');
    expect(host.canStart, isFalse);

    host.setReady(true);
    guest.setReady(true);
    await settle();
    expect(host.canStart, isTrue);

    final guestMatch = guest.matches.first;
    final m1 = host.start();
    final m2 = await guestMatch;
    expect(m2.seed, m1.seed);
    expect(m2.gameId, 'cloud-tower');
    expect(m1.localSeat, 0);
    expect(m2.localSeat, 1);
    expect([for (final s in m2.seats) s.name], ['A', 'B']);
    expect(host.phase, PartyPhase.inMatch);
    expect(guest.phase, PartyPhase.inMatch);
  });

  test('results come back to the lobby on every phone, best first', () async {
    final host = PartyController.online(relay.create(), name: 'A', catalog: catalog);
    await settle();
    final guest = joinAs(relay, host.code!, 'B');
    await settle();
    host
      ..select('cloud-tower')
      ..setReady(true);
    guest.setReady(true);
    await settle();
    final gm = guest.matches.first;
    final m1 = host.start();
    final m2 = await gm;
    m1.finish(score: 40);
    m2.finish(score: 75);
    await settle();
    for (final p in [host, guest]) {
      expect(p.phase, PartyPhase.lobby);
      expect([for (final r in p.lastStandings!) r.seat], [1, 0]);
      expect(p.allReady, isFalse, reason: 'ready-up again for a rematch');
    }
  });

  test('host leaving hands the party to the next member', () async {
    final host = PartyController.online(relay.create(), name: 'A', catalog: catalog);
    await settle();
    final b = joinAs(relay, host.code!, 'B');
    final c = joinAs(relay, host.code!, 'C');
    await settle();
    await host.leave();
    await settle();
    expect(b.isHost, isTrue);
    expect(c.hostId, b.selfId);
    expect([for (final m in c.members) m.name], ['B', 'C']);
  });

  test('a player leaving mid-match forfeits and the match still ends', () async {
    final host = PartyController.online(relay.create(), name: 'A', catalog: catalog);
    await settle();
    final guest = joinAs(relay, host.code!, 'B');
    await settle();
    host
      ..select('cue-clash')
      ..setReady(true);
    guest.setReady(true);
    await settle();
    final m1 = host.start();
    await settle();
    m1.finish(score: 3, won: true);
    await guest.leave();
    await settle();
    expect(host.phase, PartyPhase.lobby);
    expect(host.lastStandings!.last.forfeit, isTrue);
    expect(host.selectedGameId, isNull, reason: 'a 2-player game no longer fits a party of one');
  });

  test('unknown or full rooms are refused', () async {
    expect(() => relay.join('ZZZZZZ'), throwsA(isA<RoomError>()));
    final small = LoopbackRelay(maxPerRoom: 2);
    final a = small.create();
    final code = await a.events.whereType<RoomJoined>().first.then((e) => e.code);
    small.join(code);
    expect(() => small.join(code), throwsA(isA<RoomError>().having((e) => e.code, 'code', RoomError.full)));
  });

  test('same-device party: no network, all seats local', () async {
    final party = PartyController.sameDevice(players: ['Mom', 'Kid'], catalog: catalog);
    expect(party.isHost, isTrue);
    expect([for (final g in party.eligible) g.id], ['cue-clash', 'puck-rush']);
    party.select('puck-rush');
    expect(party.canStart, isTrue);
    final m = party.start();
    expect(m.seats.every((s) => s.isLocal), isTrue);
    m
      ..finish(score: 7, won: true, seat: 1)
      ..finish(score: 5, won: false, seat: 0);
    expect(party.phase, PartyPhase.lobby);
    expect(party.lastStandings!.first.seat, 1);
  });

  test('ranking: winners, then score-attack, then losers and forfeits', () {
    final ranked = rankResults(const [
      SeatResult(seat: 0, score: 999, forfeit: true, won: false),
      SeatResult(seat: 1, score: 10, won: false),
      SeatResult(seat: 2, score: 50),
      SeatResult(seat: 3, score: 1, won: true),
      SeatResult(seat: 4, score: 80),
    ]);
    expect([for (final r in ranked) r.seat], [3, 4, 2, 1, 0]);
  });
}

extension<T> on Stream<T> {
  Stream<S> whereType<S>() => where((e) => e is S).cast<S>();
}
