import 'package:asobi_party/asobi_party.dart';
import 'package:test/test.dart';

const duel = MultiplayerSpec(sync: SyncModel.parallel, maxPlayers: 4, summary: 'same seed');
const pool = MultiplayerSpec(sync: SyncModel.turnBased, sameDevice: true);
const hockey = MultiplayerSpec(
  sync: SyncModel.lockstep,
  sameDevice: true,
  online: false,
  tickRate: 30,
  inputDelayTicks: 3,
);

final catalog = [
  const GameEntry('jam-tray', '1.0.0', null),
  const GameEntry('cloud-tower', '1.0.0', duel),
  const GameEntry('cue-clash', '1.0.0', pool),
  const GameEntry('puck-rush', '1.0.0', hockey),
];

List<String> ids(List<GameEntry> games) => [for (final g in games) g.id];

void main() {
  test('valid specs pass, broken ones are explained', () {
    expect(duel.validate(), isEmpty);
    expect(pool.validate(), isEmpty);
    expect(hockey.validate(), isEmpty);
    expect(const MultiplayerSpec(sync: SyncModel.lockstep).validate(), hasLength(2));
    expect(const MultiplayerSpec(sync: SyncModel.parallel, minPlayers: 1).validate(), isNotEmpty);
    expect(const MultiplayerSpec(sync: SyncModel.parallel, maxPlayers: 9).validate(), isNotEmpty);
    expect(const MultiplayerSpec(sync: SyncModel.parallel, online: false).validate(), isNotEmpty);
  });

  test('single-player cartridges never appear in a party', () {
    for (final shape in [
      const PartyShape(2, Connection.online),
      const PartyShape(2, Connection.sameDevice),
    ]) {
      expect(ids(eligibleGames(catalog, shape)), isNot(contains('jam-tray')));
    }
  });

  test('the list shrinks with party size and connection', () {
    expect(ids(eligibleGames(catalog, const PartyShape(2, Connection.online))), ['cloud-tower', 'cue-clash']);
    expect(ids(eligibleGames(catalog, const PartyShape(3, Connection.online))), ['cloud-tower']);
    expect(ids(eligibleGames(catalog, const PartyShape(5, Connection.online))), isEmpty);
    expect(ids(eligibleGames(catalog, const PartyShape(2, Connection.sameDevice))), [
      'cue-clash',
      'puck-rush',
    ]);
  });

  test('online games need the same version on every phone', () {
    final shape = const PartyShape(2, Connection.online);
    final friendOld = {'cloud-tower': '0.9.0', 'cue-clash': '1.0.0'};
    expect(ids(eligibleGames(catalog, shape, members: [friendOld])), ['cue-clash']);
    final friendMissing = {'cloud-tower': '1.0.0'};
    expect(ids(eligibleGames(catalog, shape, members: [friendMissing])), ['cloud-tower']);
  });

  test('room codes normalise user typing', () {
    expect(normaliseRoomCode(' k7q-f3m '), 'K7QF3M');
  });
}
