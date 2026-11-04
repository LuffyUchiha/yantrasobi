import 'dart:async';

import 'package:asobi_party/asobi_party.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/catalog.dart';
import 'package:yantrasobi/cartridges/puck_duel/puck_duel.dart';
import 'package:yantrasobi/cartridges/quad_pong/quad_pong.dart';
import 'package:yantrasobi/yantrasobi/adapters/scene_adapter.dart';
import 'package:yantrasobi/yantrasobi/app.dart';
import 'package:yantrasobi/yantrasobi/party/ws_room_link.dart';
import 'package:yantrasobi/yantrasobi/runtime/services.dart';

/// Ids of the cartridges declared as online party races in this build.
const raceIds = {
  'arrow-survivor',
  'blade-toss',
  'cloud-tower',
  'dodge-lane',
  'edge-dash',
  'gulp-hole',
  'coil-clash',
};

List<GameEntry> catalogEntries() => [
  for (final c in bundledCartridges()) GameEntry(c.manifest.id, c.manifest.version, c.manifest.partySpec),
];

void main() {
  setUpAll(() => SceneSupport.gpuAllowed = false);

  late LoopbackRelay relay;

  Future<AsobiServices> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    relay = LoopbackRelay();
    final services = AsobiServices.inMemory(
      buildRegistry(),
      partyConnector: ({joinCode}) async => joinCode == null ? relay.create() : relay.join(joinCode),
    );
    await services.warmUp();
    await tester.pumpWidget(YantrasobiApp(services: services));
    await tester.pump();
    return services;
  }

  Future<void> frames(WidgetTester tester, [int n = 20]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<bool> tileShown(WidgetTester tester, String id) async {
    final finder = find.byKey(Key('library.tile.$id'));
    final grid = find.byType(Scrollable).last;
    for (var i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
      await tester.drag(grid, const Offset(0, -300));
      await tester.pump();
    }
    final shown = finder.evaluate().isNotEmpty;
    await tester.drag(grid, const Offset(0, 6000)); // back to the top
    await tester.pump();
    return shown;
  }

  test('every party-race cartridge declares a valid parallel spec', () {
    final declared = {
      for (final c in bundledCartridges())
        if (c.manifest.multiplayer != null) c.manifest.id,
    };
    expect(declared, raceIds);
    for (final c in bundledCartridges()) {
      expect(c.manifest.validate(), isEmpty, reason: c.manifest.id);
    }
  });

  test('relay addresses are normalised to the party endpoint', () {
    expect(WsRoomLink.endpoint('192.168.1.20:8787').toString(), 'ws://192.168.1.20:8787/v1/party?v=1');
    expect(
      WsRoomLink.endpoint('https://party.example.com').toString(),
      'wss://party.example.com/v1/party?v=1',
    );
    expect(WsRoomLink.endpoint('wss://p.example.com/').scheme, 'wss');
  });

  testWidgets('online party: library shrinks, host picks, friend races, forfeit ends the match', (
    tester,
  ) async {
    final services = await boot(tester);
    expect(find.byKey(const Key('party.banner')), findsNothing);

    await tester.tap(find.byKey(const Key('library.party')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('party.name')), 'Asha');
    await tester.tap(find.byKey(const Key('party.host')));
    await tester.pumpAndSettle();

    final party = services.party;
    expect(party.active, isTrue);
    expect(services.settings.playerName, 'Asha');
    final code = party.controller!.code!;
    expect(find.text('Party $code'), findsOneWidget);
    expect(
      find.text('Waiting for friends to join…'),
      findsOneWidget,
      reason: 'alone: nothing to play together',
    );

    final friend = PartyController.online(relay.join(code), name: 'Ravi', catalog: catalogEntries());
    await tester.pump();
    await tester.pump();
    expect(party.eligibleIds, raceIds);
    expect(await tileShown(tester, 'cloud-tower'), isTrue);
    expect(await tileShown(tester, 'jam-tray'), isFalse, reason: 'single-player only');
    expect(await tileShown(tester, 'puck-duel'), isFalse, reason: 'same-phone only');

    // Host taps a tile to pick it for everyone.
    await tester.scrollUntilVisible(
      find.byKey(const Key('library.tile.cloud-tower')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('library.tile.cloud-tower')));
    await tester.pump();
    await tester.pump();
    expect(friend.selectedGameId, 'cloud-tower');
    expect(tester.widget<FilledButton>(find.byKey(const Key('party.start'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('party.ready')));
    friend.setReady(true);
    await tester.pump();
    await tester.pump();
    final friendMatch = friend.matches.first;
    await tester.tap(find.byKey(const Key('party.start')));
    await tester.pump();
    final theirs = await friendMatch;
    await frames(tester);

    final mine = party.controller!.match!;
    expect(theirs.seed, mine.seed, reason: 'both phones build the same tower');
    expect(find.byKey(const Key('host.raceStrip')), findsOneWidget);

    // The friend's live score shows up on the strip.
    final friendRace = ParallelRace(theirs, minInterval: Duration.zero);
    friendRace.report(score: 42);
    await frames(tester, 5);
    expect(find.text('Ravi 42'), findsOneWidget);

    // Online matches can't restart; leaving forfeits.
    await tester.tap(find.byKey(const Key('host.pause')));
    await tester.pump();
    expect(find.byKey(const Key('host.restart')), findsNothing);
    expect(find.text('Forfeit and leave'), findsOneWidget);
    await tester.tap(find.byKey(const Key('host.exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('party.banner')), findsOneWidget, reason: 'back in the party library');

    friendRace.finish(score: 99);
    await tester.pump();
    await tester.pump();
    expect(friend.lastStandings!.first.seat, 1, reason: 'Ravi wins');
    expect(friend.lastStandings!.last.won, isFalse, reason: 'Asha forfeited');
    expect(party.controller!.phase, PartyPhase.lobby);

    await tester.tap(find.byKey(const Key('party.leave')));
    await tester.pumpAndSettle();
    expect(party.active, isFalse);
    expect(find.byKey(const Key('party.banner')), findsNothing);
    expect(await tileShown(tester, 'jam-tray'), isTrue, reason: 'full library again');
    // Fake-async test zone: let the leave run via pump instead of awaiting it.
    unawaited(friend.leave());
    await tester.pump();
  });

  testWidgets('wrong party code shows an error and keeps the sheet open', (tester) async {
    final services = await boot(tester);
    await tester.tap(find.byKey(const Key('library.party')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('party.code')), 'zzzzzz');
    await tester.pump();
    await tester.tap(find.byKey(const Key('party.join')));
    await tester.pumpAndSettle();
    expect(services.party.active, isFalse);
    expect(find.text('No party with that code.'), findsOneWidget);
  });

  testWidgets('same-phone party: only local multiplayer games; Puck Duel opens in 2-player mode', (
    tester,
  ) async {
    final services = await boot(tester);
    await tester.tap(find.byKey(const Key('library.party')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('party.local')));
    await tester.pumpAndSettle();

    expect(find.text('Sharing this phone'), findsOneWidget);
    expect(services.party.eligibleIds, {'puck-duel', 'quad-pong'});
    expect(await tileShown(tester, 'cloud-tower'), isFalse, reason: 'online-only race');

    await tester.tap(find.byKey(const Key('library.tile.puck-duel')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('party.start')));
    await tester.pump();
    await frames(tester);
    final game = tester.widget<GameWidget<PuckDuelGame>>(find.byType(GameWidget<PuckDuelGame>)).game!;
    expect(game.started, isTrue);
    expect(game.twoPlayer, isTrue, reason: 'no mode menu: both players are already here');
    expect(find.byKey(const Key('host.raceStrip')), findsNothing);

    // Same phone keeps restart (nobody else to stay in step with).
    await tester.tap(find.byKey(const Key('host.pause')));
    await tester.pump();
    expect(find.byKey(const Key('host.restart')), findsOneWidget);
    await tester.tap(find.byKey(const Key('host.exit')));
    await tester.pumpAndSettle();
    expect(services.party.controller!.phase, PartyPhase.lobby);
    expect(services.party.controller!.lastStandings, hasLength(2));
  });

  testWidgets('same-phone party of 3: Quad Pong seats three humans', (tester) async {
    final services = await boot(tester);
    await services.party.sameDevice(['A', 'B', 'C']);
    await tester.pump();
    expect(services.party.eligibleIds, {'quad-pong'}, reason: 'Puck Duel is 2-player only');
    await tester.tap(find.byKey(const Key('library.tile.quad-pong')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('party.start')));
    await tester.pump();
    await frames(tester);
    final game = tester.widget<GameWidget<QuadPongGame>>(find.byType(GameWidget<QuadPongGame>)).game!;
    expect(game.humans, 3);
    await tester.tap(find.byKey(const Key('host.pause')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('host.exit')));
    await tester.pumpAndSettle();
  });
}
