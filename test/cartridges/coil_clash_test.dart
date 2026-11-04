import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/coil_clash/coil_clash.dart';
import 'package:yantrasobi/cartridges/coil_clash/coil_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// A world with only the given slots alive, no orbs and every bot brain off.
CoilWorld isolated(List<int> keep, {int seed = 1}) {
  final w = CoilWorld(seed: seed);
  for (var i = 0; i < w.slots; i++) {
    w.ai[i] = null;
    if (!keep.contains(i)) w.debugRemove(i);
  }
  w.naturalOrbs = 0;
  w.debugClearOrbs();
  return w;
}

void stepFor(CoilWorld w, double seconds) {
  final n = (seconds / CoilWorld.stepDt).round();
  for (var i = 0; i < n; i++) {
    w.step();
  }
}

CoilClashGame startGame({int seed = 5, CartridgeSave? save}) {
  final context = CartridgeContext(
    manifest: CoilClashCartridge.kManifest,
    save: save ?? CartridgeSave(),
    audio: SilentAudio(),
    settings: AsobiSettings(MemoryKeyValueStore()),
  );
  late CoilClashGame game;
  FlameCartridgeSession<CoilClashGame>(context, (s) => game = CoilClashGame(s, seed: seed)).start();
  game.onGameResize(Vector2(400, 800));
  return game;
}

void paint(CoilClashGame game) {
  final rec = PictureRecorder();
  game.render(Canvas(rec));
  rec.endRecording().dispose();
}

void main() {
  test('manifest is valid and multiplayer-ready for 8 players', () {
    const m = CoilClashCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'coil-clash');
    expect(m.maxPlayers, 8);
    expect(m.localMultiplayer, isFalse);
    expect(m.tags, contains('multiplayer-ready'));
  });

  test('inputs are quantised value objects that pack into 13 bits', () {
    final a = CoilInput.fromAngle(-math.pi / 2, boost: true);
    expect(a.dir, 3072);
    expect(CoilInput.unpack(a.packed), a);
    expect(a.packed, lessThan(1 << 13));
    expect(CoilInput.fromAngle(math.pi * 2).dir, 0);
    expect((wrapAngle(a.angle) + math.pi / 2).abs(), lessThan(1e-9));
  });

  test('steering is limited by the turn rate and longer serpents turn slower', () {
    final w = isolated([0]);
    w.debugPlace(0, 0, 0, 0);
    final s = w.serpents[0];
    w.setInput(0, CoilInput.fromAngle(math.pi * 0.9));
    w.step();
    expect(s.heading, closeTo(s.turnRate * CoilWorld.stepDt, 1e-9));
    stepFor(w, 1);
    expect(s.heading, closeTo(CoilInput.fromAngle(math.pi * 0.9).angle, 1e-9));
    final short = s.turnRate;
    w.debugSetLength(0, 300);
    expect(s.turnRate, lessThan(short));
    expect(s.radius, greaterThan(10));
  });

  test('eating an orb grows the serpent by its value', () {
    final w = isolated([0]);
    w.debugPlace(0, 0, 0, 0);
    w.debugAddOrb(40, 0, 2.5);
    w.debugAddOrb(0, 300, 1);
    final s = w.serpents[0];
    stepFor(w, 0.5);
    expect(s.length, closeTo(CoilWorld.startLength + 2.5, 1e-9));
    expect(s.maxLength, s.length);
    expect(w.orbCount, 1);
    // The body fills in as the head moves on.
    stepFor(w, 1);
    expect(s.pointCount, s.length.floor());
  });

  test('boost doubles speed, burns length and leaves orbs; not available when short', () {
    final w = isolated([0]);
    w.debugPlace(0, -600, 0, 0, length: 60);
    final s = w.serpents[0];
    w.setInput(0, const CoilInput(boost: true));
    stepFor(w, 2);
    expect(s.boosting, isTrue);
    expect(s.x, closeTo(-600 + CoilWorld.boostSpeed * 2, 1e-6));
    expect(s.length, closeTo(60 - CoilWorld.boostBurn * 2, 1e-6));
    final drops = CoilWorld.boostBurn * 2 / CoilWorld.boostDropEvery;
    expect(w.orbCount, inInclusiveRange(drops.floor() - 1, drops.ceil()));
    // Too short to boost: plain speed and no burn.
    final w2 = isolated([0]);
    w2.debugPlace(0, 0, 0, 0);
    w2.setInput(0, const CoilInput(boost: true));
    stepFor(w2, 1);
    expect(w2.serpents[0].boosting, isFalse);
    expect(w2.serpents[0].length, CoilWorld.startLength);
    expect(w2.orbCount, 0);
  });

  test('a head touching another body dies, drops orbs and credits the kill', () {
    final w = isolated([0, 1]);
    // Serpent 1 is a long vertical wall crossing x = 0, heading up.
    w.debugPlace(1, 0, -300, -math.pi / 2, length: 120);
    w.debugPlace(0, -100, 0, 0, length: 30);
    stepFor(w, 1.5);
    final me = w.serpents[0];
    expect(me.alive, isFalse);
    expect(me.lastCause, DeathCause.body);
    expect(me.lastKiller, 1);
    expect(w.serpents[1].alive, isTrue);
    expect(w.serpents[1].kills, 1);
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    // Roughly one orb per two body points, near where it died.
    expect(w.orbCount, greaterThanOrEqualTo(14));
    for (var i = 0; i < w.orbCount; i++) {
      expect(w.ox[i], lessThan(30));
    }
  });

  test('heads colliding: the shorter serpent dies, equal lengths both die', () {
    final w = isolated([0, 1]);
    w.debugPlace(0, -60, 0, 0, length: 30);
    w.debugPlace(1, 60, 0, math.pi, length: 20);
    stepFor(w, 1);
    expect(w.serpents[1].alive, isFalse);
    expect(w.serpents[1].lastCause, DeathCause.head);
    expect(w.serpents[0].alive, isTrue);
    expect(w.serpents[0].kills, 1);

    final w2 = isolated([0, 1]);
    w2.debugPlace(0, -60, 0, 0, length: 20);
    w2.debugPlace(1, 60, 0, math.pi, length: 40);
    stepFor(w2, 1);
    expect(w2.serpents[0].alive, isFalse);
    expect(w2.serpents[0].lastKiller, 1);
    expect(w2.serpents[1].alive, isTrue);

    final w3 = isolated([1, 2]);
    w3.debugPlace(1, -60, 0, 0, length: 25);
    w3.debugPlace(2, 60, 0, math.pi, length: 25);
    stepFor(w3, 1);
    expect(w3.serpents[1].alive, isFalse);
    expect(w3.serpents[2].alive, isFalse);
  });

  test('the arena rim kills and its orbs stay inside the arena', () {
    final w = isolated([0]);
    w.debugPlace(0, CoilWorld.arenaRadius - 80, 0, 0, length: 40);
    stepFor(w, 1);
    expect(w.serpents[0].alive, isFalse);
    expect(w.serpents[0].lastCause, DeathCause.edge);
    expect(w.orbCount, greaterThan(10));
    for (var i = 0; i < w.orbCount; i++) {
      expect(math.sqrt(w.ox[i] * w.ox[i] + w.oy[i] * w.oy[i]), lessThan(CoilWorld.arenaRadius));
    }
  });

  test('bots look ahead and steer around a body in their path', () {
    CoilWorld setup({required bool brain}) {
      final w = isolated([1, 2], seed: 9);
      w.debugRemove(0);
      w.debugPlace(2, 0, -400, -math.pi / 2, length: 150);
      w.debugPlace(1, -150, 0, 0, length: 20);
      if (brain) w.ai[1] = AiController(77, skill: 0.5);
      return w;
    }

    final dumb = setup(brain: false);
    stepFor(dumb, 3);
    expect(dumb.serpents[1].alive, isFalse, reason: 'without a brain the bot runs into the wall');

    for (var trial = 0; trial < 4; trial++) {
      final w = setup(brain: true);
      w.ai[1] = AiController(100 + trial, skill: 0.45 + trial * 0.15);
      stepFor(w, 3);
      expect(w.serpents[1].alive, isTrue, reason: 'trial $trial');
      expect(w.serpents[1].deaths, 0);
    }
  });

  test('dead bots respawn after 3 seconds at a fresh size', () {
    final w = CoilWorld(seed: 4);
    w.debugKill(3);
    final s = w.serpents[3];
    expect(s.alive, isFalse);
    stepFor(w, 2.9);
    expect(s.alive || s.deaths > 1, isFalse);
    stepFor(w, 0.2);
    expect(s.alive, isTrue);
    expect(s.length, inInclusiveRange(CoilWorld.startLength, CoilWorld.startLength + 8));
    expect(math.sqrt(s.x * s.x + s.y * s.y), lessThan(CoilWorld.arenaRadius * 0.75));
    // The human slot never respawns.
    w.debugKill(0);
    stepFor(w, 4);
    expect(w.serpents[0].alive, isFalse);
  });

  test('round end: the longest living serpent wins, otherwise the run is lost', () {
    CoilWorld ending(double botLength) {
      final w = isolated([0, 1, 2]);
      w.debugPlace(0, 0, 0, 0, length: 200);
      w.debugPlace(1, 0, 700, 0, length: 120);
      w.debugPlace(2, 0, -700, 0, length: botLength);
      w.debugSetTick((CoilWorld.roundLength / CoilWorld.stepDt).round() - 30);
      return w;
    }

    final win = ending(80);
    expect(win.isOver, isFalse);
    stepFor(win, 1);
    expect(win.timeUp, isTrue);
    expect(win.isOver, isTrue);
    expect(win.won, isTrue);
    expect(win.ranking(), [0, 1, 2]);
    final tick = win.tick;
    win.update(1);
    expect(win.tick, tick, reason: 'the world freezes when the round ends');

    final lose = ending(260);
    stepFor(lose, 1);
    expect(lose.isOver, isTrue);
    expect(lose.won, isFalse);
    expect(lose.rankOf(0), 2);
    expect(lose.score, 200);
  });

  test('lockstep: two worlds fed the same inputs share a stateHash every tick', () {
    final a = CoilWorld(seed: 42);
    final b = CoilWorld(seed: 42);
    final c = CoilWorld(seed: 42);
    final rng = math.Random(7);
    var input = const CoilInput();
    var diverged = false;
    for (var t = 0; t < 1500; t++) {
      if (t % 12 == 0) input = CoilInput.fromAngle(rng.nextDouble() * 6.28, boost: rng.nextInt(4) == 0);
      final packed = input.packed;
      a.setInput(0, input);
      b.setInput(0, CoilInput.unpack(packed)); // as if it arrived over the wire
      c.setInput(0, t < 30 ? input : CoilInput(dir: (input.dir + 512) % 4096));
      a.step();
      b.step();
      c.step();
      expect(a.stateHash(), b.stateHash(), reason: 'tick ${a.tick}');
      if (a.stateHash() != c.stateHash()) diverged = true;
    }
    expect(a.tick, 1500);
    expect(diverged, isTrue);
    expect(CoilWorld(seed: 43).stateHash(), isNot(CoilWorld(seed: 42).stateHash()));
  });

  test('performance: 60 s with 8 large serpents stays within budget', () {
    final w = CoilWorld(seed: 3, humans: {});
    final sw = Stopwatch()..start();
    var maxPoints = 0;
    for (var t = 0; t < 60 * 60; t++) {
      if (t % 60 == 0) {
        for (final s in w.serpents) {
          if (s.alive && s.length < 380) w.debugSetLength(s.id, 380);
        }
      }
      w.step();
      var pts = 0;
      for (final s in w.serpents) {
        pts += s.pointCount;
      }
      maxPoints = math.max(maxPoints, pts);
    }
    sw.stop();
    expect(maxPoints, greaterThan(2000));
    // Real time is 60 000 ms; a debug-mode test VM must manage it far faster.
    expect(sw.elapsedMilliseconds, lessThan(12000), reason: '${sw.elapsedMilliseconds} ms');
  });

  test('an AI-driven player can win a full round; an idle player hits the rim', () {
    final w = CoilWorld(seed: 1);
    final me = AiController(1000, skill: 0.9);
    while (!w.isOver) {
      if (w.tick % CoilWorld.aiEvery == 0) w.setInput(0, me.decide(w, 0));
      w.step();
    }
    expect(w.timeUp, isTrue);
    expect(w.won, isTrue);
    expect(w.score, greaterThan(200));

    final idle = CoilWorld(seed: 1);
    stepFor(idle, 30);
    expect(idle.isOver, isTrue);
    expect(idle.won, isFalse);
  });

  test('renderer smoke: steering, boost button and frames render without errors', () {
    final game = startGame();
    paint(game);
    final me = game.coil.local;
    // Drag right then down: the input heading follows the stick.
    game.onPointerDown(Vector2(200, 400));
    game.onPointerMove(Vector2(250, 400), Vector2(50, 0));
    game.update(1 / 60);
    expect(me.input.dir, 0);
    game.onPointerMove(Vector2(200, 450), Vector2(-50, 50));
    game.update(1 / 60);
    expect(me.input.angle, closeTo(math.pi / 2, 0.01));
    game.onPointerUp(Vector2(200, 450));
    // Hold the boost button.
    game.onPointerDown(Vector2(400 - 64, 800 - 64));
    expect(game.boostHeld, isTrue);
    game.update(1 / 60);
    expect(me.input.boost, isTrue);
    game.onPointerUp(Vector2(400 - 64, 800 - 64));
    expect(game.boostHeld, isFalse);
    for (var i = 0; i < 90; i++) {
      game.update(1 / 60);
    }
    paint(game);
    expect(game.entityCount, greaterThan(500));
    expect(game.session.state, SessionState.running);
  });

  test('dying ends the run once as a loss and keeps the best length', () {
    final save = CartridgeSave();
    final game = startGame(seed: 6, save: save);
    game.coil.debugSetLength(0, 77);
    game.coil.debugKill(0);
    for (var i = 0; i < 150; i++) {
      game.update(1 / 60);
      if (i % 30 == 0) paint(game);
    }
    expect(game.session.state, SessionState.ended);
    expect(game.session.result!.won, isFalse);
    expect(game.session.result!.score, 77);
    expect(save.data['bestLength'], 77);
  });
}
