import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter/material.dart' show MaterialApp, Builder;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/bonk_ball/bonk_ball.dart';
import 'package:yantrasobi/cartridges/bonk_ball/bonk_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double W = BonkWorld.width;
const double dt = BonkWorld.stepDt;

/// A world past the opening kickoff with both players parked at their goals.
BonkWorld open({int seed = 1, bool goldenGoal = false, int matchTicks = BonkWorld.defaultMatchTicks}) {
  final w = BonkWorld(seed: seed, goldenGoal: goldenGoal, matchTicks: matchTicks);
  w.debugSkipKickoff();
  w.debugPlacePlayer(0, 0.9, BonkWorld.standY);
  w.debugPlacePlayer(1, W - 0.9, BonkWorld.standY);
  w.debugPlaceBall(W / 2, 3);
  return w;
}

void steps(BonkWorld w, int n) {
  for (var i = 0; i < n; i++) {
    w.step();
  }
}

/// Goal difference for CPU [a] against CPU [b] over seeded matches on both sides.
int goalDiff(CpuLevel a, CpuLevel b, {int seeds = 5}) {
  var diff = 0;
  for (var s = 1; s <= seeds; s++) {
    for (final side in [0, 1]) {
      final w = BonkWorld(seed: s);
      final ais = [
        AiController(player: side, level: a, seed: s),
        AiController(player: 1 - side, level: b, seed: s + 99),
      ];
      while (!w.isOver) {
        w.update(1 / 60, ais);
      }
      diff += w.scores[side] - w.scores[1 - side];
    }
  }
  return diff;
}

({FlameCartridgeSession<BonkBallGame> session, BonkBallGame game, SilentAudio audio}) mount({int seed = 4}) {
  final audio = SilentAudio();
  final context = CartridgeContext(
    manifest: BonkBallCartridge.kManifest,
    save: CartridgeSave(),
    audio: audio,
    settings: AsobiSettings(MemoryKeyValueStore()),
  );
  late BonkBallGame game;
  final session = FlameCartridgeSession<BonkBallGame>(context, (s) => game = BonkBallGame(s, seed: seed));
  session.start();
  return (session: session, game: game, audio: audio);
}

void main() {
  test('manifest is valid and multiplayer-ready with two local players', () {
    const m = BonkBallCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'bonk-ball');
    expect(m.maxPlayers, 2);
    expect(m.localMultiplayer, isTrue);
    expect(m.tags, contains('multiplayer-ready'));
  });

  test('geometry: goal mouth is about 2.5 player heights', () {
    expect(BonkWorld.goalHeight / BonkWorld.playerHeight, closeTo(2.5, 0.01));
  });

  test('gravity pulls players down and a jump rises then lands', () {
    final w = open();
    final p = w.players[0];
    w.debugPlacePlayer(0, 4, 3);
    steps(w, 60);
    expect(p.y, BonkWorld.standY, reason: 'fell back to the ground');
    expect(p.grounded, isTrue);

    w.setInput(0, const BonkInput(jump: true));
    w.step();
    w.setInput(0, BonkInput.none);
    expect(p.vy, greaterThan(0));
    var peak = p.y;
    var ticks = 0;
    while (!p.grounded || ticks == 0) {
      w.step();
      peak = math.max(peak, p.y);
      ticks++;
      expect(ticks, lessThan(240));
    }
    const expected = BonkWorld.jumpSpeed * BonkWorld.jumpSpeed / (2 * BonkWorld.playerGravity);
    expect(peak - BonkWorld.standY, closeTo(expected, 0.15));
    expect(w.jumps, 1);
    // No jumping in mid-air.
    w.debugPlacePlayer(0, 4, 3);
    w.setInput(0, const BonkInput(jump: true));
    w.step();
    expect(p.vy, lessThan(0));
  });

  test('ball bounces with restitution and air drag slows it', () {
    final w = open();
    w.debugPlaceBall(W / 2, 4);
    var prevVy = 0.0;
    double? impact, rebound;
    for (var i = 0; i < 240 && rebound == null; i++) {
      w.step();
      if (impact == null && prevVy < 0 && w.ballVy > 0) {
        impact = prevVy;
        rebound = w.ballVy;
      }
      prevVy = w.ballVy;
    }
    expect(impact, isNotNull);
    expect(rebound! / -impact!, closeTo(BonkWorld.groundRestitution, 0.02));
    expect(w.bounces, 1);
    // A flat throw loses speed to drag.
    final d = open();
    d.debugPlaceBall(W / 2, 6, 10, 0);
    steps(d, 30);
    expect(d.ballVx, lessThan(10));
    expect(d.ballVx, greaterThan(8.5));
  });

  test('crossbar deflects the ball and a ball on top rolls back into play', () {
    final w = open();
    // Fired at the end of the crossbar: it bounces back out, no goal.
    w.debugPlaceBall(3, BonkWorld.goalHeight, -14, 0);
    steps(w, 30);
    expect(w.crossbarHits, 1);
    expect(w.ballVx, greaterThan(0));
    expect(w.goals, 0);
    // Dropped onto the sloped bar: it rolls towards the field.
    final r = open();
    r.debugPlaceBall(0.7, BonkWorld.goalHeight + 1.2);
    steps(r, 240);
    expect(r.ballX, greaterThan(BonkWorld.goalDepth));
    expect(r.goals, 0);
    // The right goal mirrors the left one.
    final m = open();
    m.debugPlaceBall(W - 3, BonkWorld.goalHeight, 14, 0);
    steps(m, 30);
    expect(m.ballVx, lessThan(0));
    expect(m.goals, 0);
  });

  test('a running head transfers its velocity to the ball', () {
    final w = open();
    final p = w.players[0];
    w.debugPlacePlayer(0, 6, BonkWorld.standY, BonkWorld.moveSpeed);
    w.setInput(0, const BonkInput(move: 1));
    w.debugPlaceBall(6 + BonkWorld.headRadius + BonkWorld.ballRadius + 0.02, BonkWorld.standY + 0.1);
    steps(w, 3);
    expect(w.ballVx, greaterThan(p.vx), reason: 'bounced off ahead of the head');
    expect(w.lastTouch, 0);
    // A ball dropping onto a still head pops back up.
    final h = open();
    h.debugPlacePlayer(1, 10, BonkWorld.standY);
    h.debugPlaceBall(10, 4, 0, -6);
    for (var i = 0; i < 60 && h.headHits == 0; i++) {
      h.step();
    }
    expect(h.headHits, 1);
    expect(h.ballVy, greaterThan(0));
  });

  test('kick impulse goes up and forward for each player', () {
    for (final player in [0, 1]) {
      final w = open();
      final p = w.players[player];
      final x = player == 0 ? 5.0 : 11.0;
      w.debugPlacePlayer(player, x, BonkWorld.standY);
      w.debugPlaceBall(p.bootX, BonkWorld.ballRadius);
      w.setInput(player, const BonkInput(kick: true));
      w.step();
      expect(w.kicks, 1);
      expect(w.kickHits, 1);
      expect(w.ballVx * p.facing, greaterThan(BonkWorld.kickVx * 0.9));
      expect(w.ballVy, greaterThan(BonkWorld.kickVy * 0.9));
      // Holding kick does not re-fire until the cooldown passes.
      steps(w, 10);
      expect(w.kicks, 1);
      steps(w, BonkWorld.kickCooldownTicks);
      expect(w.kicks, 2);
    }
  });

  test('goal detection, kickoff reset and a ball over the bar does not count', () {
    final w = open();
    w.debugPlaceBall(W - 2.5, 0.6, 9, 0);
    for (var i = 0; i < 120 && w.goals == 0; i++) {
      w.step();
    }
    expect(w.scores, [1, 0]);
    expect(w.lastScorer, 0);
    expect(w.goalPause, greaterThan(0));
    final clock = w.remainingTicks;
    steps(w, BonkWorld.goalPauseTicks);
    expect(w.remainingTicks, clock, reason: 'clock stops for the celebration');
    expect(w.kickoffTimer, BonkWorld.kickoffTicks);
    expect(w.ballX, W / 2);
    expect(w.players[0].x, w.players[0].homeX);
    expect(w.players[1].x, w.players[1].homeX);
    steps(w, BonkWorld.kickoffTicks);
    expect(w.ballVx, greaterThan(0), reason: 'kickoff drifts to the side that conceded');
    // Over the crossbar: no goal.
    final o = open();
    o.debugPlaceBall(1.0, BonkWorld.goalHeight + 1.5, -3, 0);
    steps(o, 20);
    expect(o.goals, 0);
    // Into the left goal scores for player 1.
    final l = open();
    l.debugPlacePlayer(0, 4, BonkWorld.standY);
    l.debugPlaceBall(2.5, 0.6, -9, 0);
    steps(l, 60);
    expect(l.scores, [0, 1]);
  });

  test('first to five ends the match', () {
    final w = open();
    for (var g = 0; g < 5; g++) {
      w.debugPlaceBall(W - 0.5, 0.6, 5, 0);
      w.step();
    }
    expect(w.scores[0], BonkWorld.defaultWinScore);
    expect(w.isOver, isTrue);
    expect(w.won, isTrue);
    final hash = w.stateHash();
    w.step();
    expect(w.stateHash(), hash, reason: 'frozen once over');
  });

  test('full time: leader wins, CPU tie is a draw, 2P tie goes to golden goal', () {
    final lead = open(matchTicks: 200);
    lead.debugPlaceBall(W - 0.5, 0.6, 5, 0);
    lead.step();
    lead.debugPlaceBall(W / 2, 3);
    steps(lead, 400);
    expect(lead.isOver, isTrue);
    expect(lead.winner, 0);

    final draw = open(matchTicks: 200);
    steps(draw, 260);
    expect(draw.isOver, isTrue);
    expect(draw.isDraw, isTrue);
    expect(draw.won, isFalse);

    final golden = open(matchTicks: 200, goldenGoal: true);
    steps(golden, 260);
    expect(golden.isOver, isFalse);
    expect(golden.goldenGoalActive, isTrue);
    expect(golden.remainingTicks, 0);
    golden.debugPlaceBall(0.5, 0.6, -5, 0);
    golden.step();
    expect(golden.isOver, isTrue);
    expect(golden.winner, 1);
  });

  test('CPU difficulty ordering over seeded matches: hard > normal > easy', () {
    expect(goalDiff(CpuLevel.normal, CpuLevel.easy), greaterThan(5));
    expect(goalDiff(CpuLevel.hard, CpuLevel.normal), greaterThan(5));
    expect(goalDiff(CpuLevel.hard, CpuLevel.easy), greaterThan(10));
  });

  test('an idle player loses to the CPU, which only uses setInput', () {
    for (final seed in [1, 2, 3]) {
      final w = BonkWorld(seed: seed);
      final ai = AiController(player: 1, level: CpuLevel.normal, seed: seed);
      while (!w.isOver) {
        w.update(1 / 60, [ai]);
      }
      expect(w.won, isFalse);
      expect(w.scores[1], greaterThan(w.scores[0]));
    }
  });

  test('lockstep: identical input streams keep identical stateHash every tick', () {
    final a = BonkWorld(seed: 9), b = BonkWorld(seed: 9);
    final aiA = AiController(player: 1, level: CpuLevel.hard, seed: 3);
    final aiB = AiController(player: 1, level: CpuLevel.hard, seed: 3);
    final rng = math.Random(42);
    var input = BonkInput.none;
    for (var t = 0; t < 3000; t++) {
      if (t % 20 == 0) {
        input = BonkInput(move: rng.nextInt(3) - 1.0, jump: rng.nextInt(5) == 0, kick: rng.nextInt(4) == 0);
      }
      a.setInput(0, input);
      b.setInput(0, input);
      a.setInput(1, aiA.think(a));
      b.setInput(1, aiB.think(b));
      a.step();
      b.step();
      expect(a.tick, b.tick);
      expect(a.stateHash(), b.stateHash(), reason: 'desync at tick ${a.tick}');
    }
    // A single different input shows up in the hash.
    final c = open(), d = open();
    c.setInput(0, const BonkInput(move: 1));
    d.setInput(0, const BonkInput(move: 0.5));
    steps(c, 10);
    steps(d, 10);
    expect(c.stateHash(), isNot(d.stateHash()));
    // Inputs are clamped and quantised for transport.
    c.setInput(0, const BonkInput(move: 3.14159));
    expect(c.players[0].input.move, 1);
    c.setInput(0, const BonkInput(move: 0.123456));
    expect(c.players[0].input.move, 0.12);
  });

  test('game reports a CPU win once, with headline and won flag', () {
    final h = mount();
    final game = h.game;
    game.onGameResize(Vector2(400, 800));
    game.startMatch(twoPlayer: false, level: CpuLevel.hard);
    game.bonk.debugSkipKickoff();
    for (var g = 0; g < 5; g++) {
      game.bonk.debugPlaceBall(W - 0.5, 0.6, 5, 0);
      game.update(1 / 60);
    }
    expect(game.bonk.won, isTrue);
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(h.session.state, SessionState.ended);
    expect(h.session.result!.won, isTrue);
    expect(h.session.result!.headline, contains('HARD'));
    expect(h.audio.played, contains(Sfx.win));
  });

  test('2P result has won null; CPU draw reports won false', () {
    final h = mount();
    h.game.onGameResize(Vector2(400, 800));
    h.game.startMatch(twoPlayer: true);
    expect(h.game.bonk.goldenGoal, isTrue);
    h.game.bonk.debugSkipKickoff();
    for (var g = 0; g < 5; g++) {
      h.game.bonk.debugPlaceBall(0.5, 0.6, -5, 0);
      h.game.update(1 / 60);
    }
    for (var i = 0; i < 120; i++) {
      h.game.update(1 / 60);
    }
    expect(h.session.result!.won, isNull);
    expect(h.session.result!.headline, contains('Player 2 wins'));

    final d = mount();
    d.game.onGameResize(Vector2(400, 800));
    d.game.startMatch(twoPlayer: false, level: CpuLevel.easy);
    d.game.bonk.remainingTicks = 1;
    d.game.bonk.debugSkipKickoff();
    d.game.bonk.debugPlaceBall(W / 2, 8);
    for (var i = 0; i < 120; i++) {
      d.game.update(1 / 60);
    }
    expect(d.session.state, SessionState.ended);
    expect(d.session.result!.won, isFalse);
    expect(d.session.result!.headline, contains('draw'));
  });

  test('renderer smoke: menu, on-screen buttons and rendering work', () {
    final h = mount(seed: 8);
    final game = h.game;
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    // Tap the first menu option (vs CPU, easy).
    game.onPointerDown(Vector2(200, 800 * 0.42 + 25));
    expect(game.started, isTrue);
    expect(game.twoPlayer, isFalse);
    expect(game.level, CpuLevel.easy);
    expect(game.buttons.length, 4);
    game.bonk.debugSkipKickoff();
    final right = game.buttons.firstWhere((b) => b.kind == BonkButton.right).rect.center;
    final x0 = game.bonk.players[0].x;
    game.onPointerDown(Vector2(right.dx, right.dy));
    expect(game.isHeld(0, BonkButton.right), isTrue);
    for (var i = 0; i < 30; i++) {
      game.update(1 / 60);
      paint();
    }
    expect(game.bonk.players[0].x, greaterThan(x0 + 1));
    game.onPointerUp(Vector2(right.dx, right.dy));
    expect(game.bonk.players[0].input, BonkInput.none);
    expect(game.entityCount, greaterThan(0));
    expect(h.session.state, SessionState.running);
  });

  testWidgets('2-player mode: simultaneous button presses drive both athletes', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = mount(seed: 6);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: h.session.buildView)));
    await tester.pump();
    final game = h.game;
    game.startMatch(twoPlayer: true);
    game.bonk.debugSkipKickoff();
    game.bonk.debugPlaceBall(W / 2, 8);
    await tester.pump(const Duration(milliseconds: 16));
    expect(game.buttons.length, 8);
    Offset at(int player, BonkButton kind) =>
        game.buttons.firstWhere((b) => b.player == player && b.kind == kind).rect.center;
    final p1 = game.bonk.players[0], p2 = game.bonk.players[1];
    final x1 = p1.x;
    expect(at(1, BonkButton.jump).dy, lessThan(400), reason: 'player 2 controls sit at the top');

    final g1 = await tester.startGesture(at(0, BonkButton.right), pointer: 1);
    final g2 = await tester.startGesture(at(1, BonkButton.jump), pointer: 2);
    await tester.pump(const Duration(milliseconds: 16));
    expect(game.isHeld(0, BonkButton.right), isTrue);
    expect(game.isHeld(1, BonkButton.jump), isTrue);
    var maxY2 = p2.y;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      maxY2 = math.max(maxY2, p2.y);
    }
    expect(p1.x, greaterThan(x1 + 0.8), reason: 'player 1 runs right');
    expect(maxY2, greaterThan(BonkWorld.standY + 1), reason: 'player 2 jumps at the same time');
    // A third finger: player 1 also jumps while still running.
    final g3 = await tester.startGesture(at(0, BonkButton.jump), pointer: 3);
    await tester.pump(const Duration(milliseconds: 16));
    expect(game.isHeld(0, BonkButton.jump), isTrue);
    expect(game.isHeld(0, BonkButton.right), isTrue);
    await g1.up();
    await g2.up();
    await g3.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(game.bonk.players[0].input, BonkInput.none);
    expect(game.bonk.players[1].input, BonkInput.none);
    expect(h.session.state, SessionState.running);
    h.session.dispose();
  });
}
