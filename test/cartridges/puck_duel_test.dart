import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter/material.dart' show MaterialApp, Builder;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/puck_duel/puck_duel.dart';
import 'package:yantrasobi/cartridges/puck_duel/puck_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double W = PuckWorld.width;
const double H = PuckWorld.height;

/// A world with the puck in play (no serve pause) and both mallets parked
/// out of the way at their goals' corners.
PuckWorld open({int seed = 1}) {
  final w = PuckWorld(seed: seed);
  w.debugPlaceMallet(0, 1, H - 1);
  w.debugPlaceMallet(1, W - 1, 1);
  w.debugPlacePuck(W / 2, H / 2);
  return w;
}

/// Plays a full CPU-vs-CPU match; returns the winner (or -1 on timeout).
int cpuMatch(CpuLevel p0, CpuLevel p1, int seed) {
  final w = PuckWorld(seed: seed);
  final ais = [
    AiController(player: 0, level: p0, seed: seed),
    AiController(player: 1, level: p1, seed: seed),
  ];
  for (var t = 0; t < 120 * 60 * 6 && !w.isOver; t++) {
    w.update(PuckWorld.stepDt, ais);
  }
  return w.winner ?? -1;
}

({FlameCartridgeSession<PuckDuelGame> session, PuckDuelGame game, SilentAudio audio}) mount({int seed = 4}) {
  final audio = SilentAudio();
  final context = CartridgeContext(
    manifest: PuckDuelCartridge.kManifest,
    save: CartridgeSave(),
    audio: audio,
    settings: AsobiSettings(MemoryKeyValueStore()),
  );
  late PuckDuelGame game;
  final session = FlameCartridgeSession<PuckDuelGame>(context, (s) => game = PuckDuelGame(s, seed: seed));
  session.start();
  return (session: session, game: game, audio: audio);
}

void main() {
  test('manifest is valid and multiplayer-ready with two players', () {
    const m = PuckDuelCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'puck-duel');
    expect(m.maxPlayers, 2);
    expect(m.localMultiplayer, isTrue);
    expect(m.tags, contains('multiplayer-ready'));
  });

  test('puck bounces off the side rails and slows only slightly from friction', () {
    final w = open();
    w.debugPlacePuck(2, H / 2 - 3, -10, 0);
    for (var i = 0; i < 40; i++) {
      w.step();
    }
    expect(w.puckVx, greaterThan(0), reason: 'reflected off the left rail');
    expect(w.puckX, greaterThanOrEqualTo(PuckWorld.puckRadius));
    expect(w.wallHits, 1);
    // Restitution trims the bounce, drag barely matters over a third of a second.
    expect(
      w.puckVx,
      closeTo(10 * PuckWorld.wallRestitution * math.exp(-PuckWorld.friction * 40 / 120), 0.05),
    );

    final f = open();
    f.debugPlacePuck(W / 2, H / 2, 0, 0.5);
    for (var i = 0; i < 120; i++) {
      f.step();
    }
    expect(f.puckVy, closeTo(0.5 * math.exp(-PuckWorld.friction), 1e-3));
    expect(f.puckVy, greaterThan(0.35), reason: 'low friction: the puck keeps gliding');

    // The end walls bounce too, outside the goal mouth.
    final e = open();
    e.debugPlacePuck(1.5, 2, 0, -12);
    for (var i = 0; i < 30; i++) {
      e.step();
    }
    expect(e.puckVy, greaterThan(0));
    expect(e.scores, [0, 0]);
  });

  test('mallets stay in their own half and never exceed the speed cap', () {
    final w = open();
    w.setInput(0, const PuckInput(W / 2, 1)); // deep in the opponent's half
    w.setInput(1, const PuckInput(-5, H)); // off the table, in player 0's half
    const maxStep = PuckWorld.malletMaxSpeed * PuckWorld.stepDt;
    final px = [w.mallets[0].x, w.mallets[1].x], py = [w.mallets[0].y, w.mallets[1].y];
    for (var i = 0; i < 240; i++) {
      w.step();
      for (var p = 0; p < 2; p++) {
        final m = w.mallets[p];
        expect(
          math.sqrt(math.pow(m.x - px[p], 2) + math.pow(m.y - py[p], 2)),
          lessThanOrEqualTo(maxStep + 1e-9),
        );
        expect(m.y, inInclusiveRange(PuckWorld.minYFor(p), PuckWorld.maxYFor(p)));
        expect(m.x, inInclusiveRange(PuckWorld.minX, PuckWorld.maxX));
        px[p] = m.x;
        py[p] = m.y;
      }
    }
    expect(w.mallets[0].y, closeTo(H / 2 + PuckWorld.malletRadius, 1e-9));
    expect(w.mallets[1].y, closeTo(H / 2 - PuckWorld.malletRadius, 1e-9));
    expect(w.mallets[1].x, closeTo(PuckWorld.minX, 1e-9));
  });

  test('a moving mallet transfers its velocity to the puck', () {
    final w = open();
    w.debugPlacePuck(W / 2, H - 5, 0, 0);
    w.debugPlaceMallet(0, W / 2, H - 2);
    w.setInput(0, const PuckInput(W / 2, H / 2 + 1)); // swing straight up through the puck
    for (var i = 0; i < 20; i++) {
      w.step();
    }
    expect(w.malletHits, 1, reason: 'the struck puck outruns the mallet');
    expect(w.puckVy, lessThan(-PuckWorld.malletMaxSpeed), reason: 'struck upward harder than the swing');
    expect(w.puckVx.abs(), lessThan(0.5));

    // A resting mallet only reflects an incoming puck (restitution, no gain).
    final r = open();
    r.debugPlaceMallet(0, W / 2, H - 3);
    r.debugPlacePuck(W / 2, H - 6, 0, 8);
    for (var i = 0; i < 60; i++) {
      r.step();
    }
    expect(r.puckVy, lessThan(0));
    expect(r.puckSpeed, lessThan(8));
  });

  test('puck speed is capped', () {
    final w = open();
    w.debugPlacePuck(W / 2, H / 2, 90, 90);
    w.step();
    expect(w.puckSpeed, closeTo(PuckWorld.puckMaxSpeed, 1e-6));
    var maxSeen = 0.0;
    final ais = [
      AiController(player: 0, level: CpuLevel.hard, seed: 2),
      AiController(player: 1, level: CpuLevel.hard, seed: 3),
    ];
    final m = PuckWorld(seed: 9);
    for (var i = 0; i < 120 * 30; i++) {
      m.update(PuckWorld.stepDt, ais);
      maxSeen = math.max(maxSeen, m.puckSpeed);
    }
    expect(maxSeen, lessThanOrEqualTo(PuckWorld.puckMaxSpeed + 1e-9));
    expect(m.malletHits, greaterThan(5));
  });

  test('goals are detected in the mouth and the puck is re-served in the conceding half', () {
    final w = open();
    w.debugPlacePuck(W / 2, 3, 0.3, -15);
    for (var i = 0; i < 60 && w.goals == 0; i++) {
      w.step();
    }
    expect(w.scores, [1, 0]);
    expect(w.lastScorer, 0);
    expect(w.puckY, H * 0.25, reason: 'player 2 conceded, so the puck goes to the top half');
    expect(w.puckSpeed, 0);
    expect(w.serveTimer, PuckWorld.serveTicks);
    // Frozen during the serve pause.
    w.step();
    expect(w.puckY, H * 0.25);

    final b = open();
    b.debugPlacePuck(W / 2 - 1, H - 3, 0, 15);
    for (var i = 0; i < 60 && b.goals == 0; i++) {
      b.step();
    }
    expect(b.scores, [0, 1]);
    expect(b.puckY, H * 0.75);

    // Hitting a goal post is not a goal.
    final p = open();
    p.debugPlacePuck(PuckWorld.goalLeft - 0.1, 3, 0, -15);
    for (var i = 0; i < 60; i++) {
      p.step();
    }
    expect(p.goals, 0);
    expect(p.puckVy, greaterThan(0));
  });

  test('shot clock hands a lingering puck to the other player', () {
    final w = open();
    w.debugPlacePuck(3, H - 4); // resting in player 1's half, nobody touches it
    for (var i = 0; i < PuckWorld.shotClockTicks; i++) {
      w.step();
    }
    expect(w.turnovers, 0);
    expect(w.shotClockLeft, closeTo(0, 1e-9));
    w.step();
    expect(w.turnovers, 1);
    expect(w.puckY, H * 0.25, reason: 'now served to player 2');
    expect(w.serveTimer, PuckWorld.serveTicks);
    expect(w.scores, [0, 0]);
  });

  test('first to seven wins and the match then freezes', () {
    final w = open();
    for (var g = 0; g < PuckWorld.defaultWinScore; g++) {
      expect(w.isOver, isFalse);
      w.debugPlacePuck(W / 2, 1, 0, -20);
      for (var i = 0; i < 30 && w.scores[0] == g; i++) {
        w.step();
      }
      if (g < 3) {
        // Player 2 nicks a few in between.
        w.debugPlacePuck(W / 2, H - 1, 0, 20);
        for (var i = 0; i < 30 && w.scores[1] == g; i++) {
          w.step();
        }
      }
    }
    expect(w.scores, [7, 3]);
    expect(w.isOver, isTrue);
    expect(w.winner, 0);
    expect(w.won, isTrue);
    final hash = w.stateHash();
    w.step();
    w.update(1.0);
    expect(w.stateHash(), hash);
  });

  test('CPU difficulty ordering: hard beats easy and normal over seeded matches', () {
    var hardWins = 0;
    for (var seed = 0; seed < 4; seed++) {
      if (cpuMatch(CpuLevel.hard, CpuLevel.easy, seed) == 0) hardWins++;
      if (cpuMatch(CpuLevel.easy, CpuLevel.hard, seed) == 1) hardWins++;
    }
    expect(hardWins, greaterThanOrEqualTo(7));
    var hardVsNormal = 0;
    for (var seed = 0; seed < 3; seed++) {
      if (cpuMatch(CpuLevel.hard, CpuLevel.normal, seed) == 0) hardVsNormal++;
    }
    expect(hardVsNormal, greaterThanOrEqualTo(2));
  });

  test('an idle player loses to the CPU; the CPU acts only through setInput', () {
    final w = PuckWorld(seed: 5);
    final ai = AiController(player: 1, level: CpuLevel.normal, seed: 5);
    for (var t = 0; t < 120 * 240 && !w.isOver; t++) {
      w.update(PuckWorld.stepDt, [ai]);
    }
    expect(w.isOver, isTrue);
    expect(w.winner, 1);
    expect(w.won, isFalse);
    expect(w.scores[1], 7);
  });

  test('lockstep: two worlds fed the same inputs hash identically every tick', () {
    final a = PuckWorld(seed: 77), b = PuckWorld(seed: 77);
    final rng = math.Random(3);
    final aiA = AiController(player: 1, level: CpuLevel.hard, seed: 8);
    final aiB = AiController(player: 1, level: CpuLevel.hard, seed: 8);
    var tx = W / 2, ty = H - 3;
    for (var t = 0; t < 120 * 40; t++) {
      if (t % 9 == 0) {
        tx = rng.nextDouble() * W;
        ty = H / 2 + rng.nextDouble() * H / 2;
      }
      final human = PuckInput(tx, ty);
      a.setInput(0, human);
      b.setInput(0, human);
      a.setInput(1, aiA.think(a));
      b.setInput(1, aiB.think(b));
      a.step();
      b.step();
      expect(a.tick, b.tick);
      expect(a.stateHash(), b.stateHash(), reason: 'desync at tick $t');
    }
    expect(a.goals + a.malletHits, greaterThan(0));
    // A different input must show up in the hash.
    final c = PuckWorld(seed: 77), d = PuckWorld(seed: 77);
    c.setInput(0, const PuckInput(2, H - 2));
    d.setInput(0, const PuckInput(2.5, H - 2));
    c.step();
    d.step();
    expect(c.stateHash(), isNot(d.stateHash()));
  });

  test('vs CPU run reports one won/lost result with a headline', () {
    final h = mount();
    final game = h.game;
    game.onGameResize(Vector2(400, 800));
    game.startMatch(twoPlayer: false, level: CpuLevel.hard);
    expect(game.ai, isNotNull);
    for (var g = 0; g < 7; g++) {
      game.duel.debugPlacePuck(W / 2, 0.3, 0, -20);
      game.update(1 / 60);
    }
    expect(game.duel.won, isTrue);
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(h.session.state, SessionState.ended);
    expect(h.session.result!.won, isTrue);
    expect(h.session.result!.headline, contains('HARD'));
    expect(h.session.result!.score, greaterThan(700));
    expect(h.audio.played, contains(Sfx.win));
  });

  test('2-player run reports won null and a "Player N wins" headline', () {
    final h = mount();
    final game = h.game;
    game.onGameResize(Vector2(400, 800));
    game.startMatch(twoPlayer: true);
    expect(game.ai, isNull);
    for (var g = 0; g < 7; g++) {
      game.duel.debugPlacePuck(W / 2, H - 0.3, 0, 20);
      game.update(1 / 60);
    }
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(h.session.state, SessionState.ended);
    expect(h.session.result!.won, isNull);
    expect(h.session.result!.headline, startsWith('Player 2 wins'));
  });

  test('renderer smoke: menu tap starts a CPU match, drags steer the mallet, frames render', () {
    final h = mount(seed: 8);
    final game = h.game;
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    // Scan for the first menu button (easy CPU).
    outer:
    for (var y = 200.0; y < 700; y += 10) {
      for (var x = 40.0; x < 360; x += 40) {
        game.onPointerDown(Vector2(x, y));
        if (game.started) break outer;
      }
    }
    expect(game.started, isTrue);
    expect(game.twoPlayer, isFalse);
    expect(game.level, CpuLevel.easy);
    final m = game.duel.mallets[0];
    final startX = m.x;
    game.onPointerDown(Vector2(80, 700));
    game.onPointerMove(Vector2(60, 690), Vector2(-20, -10));
    for (var i = 0; i < 60; i++) {
      game.update(1 / 60);
      if (i % 10 == 0) paint();
    }
    expect(m.x, lessThan(startX));
    expect(m.y, greaterThan(H / 2));
    // Trigger a goal so the flash, trail and sparks render too.
    game.duel.debugPlacePuck(W / 2, 0.3, 0, -20);
    game.update(1 / 60);
    paint();
    expect(game.duel.scores[0], 1);
    expect(game.entityCount, greaterThan(3));
    expect(h.session.state, SessionState.running);
  });

  testWidgets('2-player mode: two simultaneous fingers move both mallets', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = mount(seed: 6);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: h.session.buildView)));
    await tester.pump();
    final game = h.game;
    game.startMatch(twoPlayer: true);
    await tester.pump(const Duration(milliseconds: 16));
    final p1 = game.duel.mallets[0], p2 = game.duel.mallets[1];
    final p1Start = Offset(p1.x, p1.y), p2Start = Offset(p2.x, p2.y);

    final bottom = await tester.startGesture(const Offset(200, 640), pointer: 1);
    final top = await tester.startGesture(const Offset(200, 260), pointer: 2);
    for (var i = 0; i < 30; i++) {
      await bottom.moveBy(const Offset(-4, 0));
      await top.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(p1.x, lessThan(p1Start.dx - 2), reason: 'bottom finger drags player 1 left');
    expect(p2.x, greaterThan(p2Start.dx + 2), reason: 'top finger drags player 2 right');
    expect(p1.y, greaterThan(H / 2));
    expect(p2.y, lessThan(H / 2));
    // Each mallet sits under its own finger.
    final t1 = game.toTable(Vector2(80, 640)), t2 = game.toTable(Vector2(320, 260));
    expect(p1.x, closeTo(t1.x, 0.05));
    expect(p2.x, closeTo(t2.x, 0.05));
    await bottom.up();
    await top.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(h.session.state, SessionState.running);
    h.session.dispose();
  });
}
