import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/swing_hook/swing_hook.dart';
import 'package:yantrasobi/cartridges/swing_hook/swing_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// Scripted player: hold when an anchor is ahead and high enough above,
/// release at the forward apex of the swing (or once it swings past 43 deg).
void bot(SwingWorld w) {
  if (!w.alive) {
    if (w.holding) w.release();
    return;
  }
  if (w.attached) {
    final a = w.anchors[w.ropeIndex];
    final dx = w.px - a.x, dy = w.py - a.y;
    final forward = math.atan2(dx, dy);
    if ((forward > 0.75 && w.vy < 0) || (dx > 0 && w.vy >= 0)) w.release();
  } else {
    final t = w.findTarget();
    if (t >= 0) {
      final a = w.anchors[t];
      final elevation = math.atan2(w.py - a.y, a.x - w.px);
      if (elevation > 0.6 && !w.holding) w.press();
    }
  }
}

/// Runs the bot until the level ends (or [maxSeconds] pass).
SwingWorld playBot(SwingWorld w, {double maxSeconds = 120}) {
  var steps = 0;
  while (!w.isOver && steps < maxSeconds / kSwingStep) {
    bot(w);
    w.step();
    steps++;
  }
  return w;
}

/// An open sandbox: one far anchor, a deep pit, a distant finish.
SwingLevel sandbox({
  List<SwingAnchor> anchors = const [SwingAnchor(500, -500)],
  List<SwingPad> pads = const [],
  List<SwingSpike> spikes = const [],
  List<SwingCheckpoint> checkpoints = const [],
  double killY = 1000,
  double finishX = 1000,
}) => SwingLevel(
  name: 'Sandbox',
  startX: -50,
  startY: -50,
  anchors: anchors,
  pads: pads,
  spikes: spikes,
  checkpoints: checkpoints,
  killY: killY,
  finishX: finishX,
);

void steps(SwingWorld w, int n) {
  for (var i = 0; i < n; i++) {
    w.step();
  }
}

void main() {
  test('manifest is valid', () {
    expect(SwingHookCartridge.kManifest.validate(), isEmpty);
    expect(SwingHookCartridge.kManifest.id, 'swing-hook');
  });

  test('free fall integrates gravity and keeps horizontal speed', () {
    final w = SwingWorld.custom(sandbox())..debugPlace(0, 0, vx: 3);
    steps(w, 120); // one second
    expect(w.py, closeTo(0.5 * kSwingGravity, 0.2));
    expect(w.vy, closeTo(kSwingGravity, 1e-9));
    expect(w.vx, 3);
    expect(w.px, closeTo(3, 1e-9));
    expect(w.attached, isFalse);
  });

  test('rope constraint keeps its length while swinging', () {
    final w = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(0, 0)]))..debugPlace(-3, 3);
    w.debugAttach(0);
    final len = w.ropeLength;
    expect(len, closeTo(math.sqrt(18), 1e-9));
    for (var i = 0; i < 600; i++) {
      w.step();
      final d = math.sqrt(w.px * w.px + w.py * w.py);
      // A rope only pulls: it never stretches, and below the anchor's level
      // (where tension is always positive) it stays taut.
      expect(d, lessThanOrEqualTo(len + 1e-9));
      if (w.py > 0.5) expect(d, closeTo(len, 1e-3), reason: 'step $i');
    }
    expect(w.attached, isTrue);
  });

  test('a swing converts height into forward horizontal speed', () {
    final w = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(0, 0)]))..debugPlace(-4, 0);
    w.debugAttach(0);
    while (w.px < 0) {
      w.step();
    }
    final ideal = math.sqrt(2 * kSwingGravity * 4);
    expect(w.vx, greaterThan(ideal * 0.9));
    expect(w.vx, lessThan(ideal * 1.15));
    expect(w.vy.abs(), lessThan(2));
    expect(w.py, closeTo(4, 0.1));
  });

  test('releasing keeps the velocity and returns to free flight', () {
    final w = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(0, 0)]))..debugPlace(-4, 0);
    w.debugAttach(0);
    steps(w, 50);
    final vx = w.vx, vy = w.vy;
    w.release();
    expect(w.attached, isFalse);
    expect(w.phase, SwingPhase.flying);
    expect(w.vx, vx);
    expect(w.vy, vy);
    w.step();
    expect(w.vx, closeTo(vx, 1e-9));
    expect(w.vy, closeTo(vy + kSwingGravity * kSwingStep, 1e-9));
  });

  test('the target is the nearest anchor ahead, above and within range', () {
    final w = SwingWorld.custom(
      sandbox(
        anchors: const [
          SwingAnchor(-3, -3), // behind
          SwingAnchor(6, -4), // ahead, further
          SwingAnchor(4, -3), // ahead, nearest
          SwingAnchor(30, -3), // out of range
          SwingAnchor(2, 3), // below
        ],
      ),
    )..debugPlace(0, 0);
    expect(w.findTarget(), 2);
    w.debugPlace(4.9, 0);
    expect(w.findTarget(), 1, reason: 'the nearest one is now behind');
    w.debugPlace(12, 0);
    expect(w.findTarget(), -1, reason: 'nothing ahead within range');
    // Pressing grabs the target with a rope as long as the current distance.
    w.debugPlace(0, 0);
    w.press();
    expect(w.ropeIndex, 2);
    expect(w.ropeLength, closeTo(5, 1e-9));
    expect(w.phase, SwingPhase.swinging);
    // Holding with nothing in range grabs as soon as an anchor comes in range.
    final v = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(12, -2)]))..debugPlace(0, 0, vx: 10);
    v.press();
    expect(v.attached, isFalse);
    var n = 0;
    while (!v.attached && n++ < 240) {
      v.step();
    }
    expect(v.attached, isTrue);
    expect(v.ropeLength, lessThanOrEqualTo(v.level.range + 1e-9));
  });

  test('spring pads bounce the acrobat up and forward', () {
    final w = SwingWorld.custom(sandbox(pads: const [SwingPad(-2, 5, 4, power: 16, kick: 6)]))
      ..debugPlace(0, 3, vx: 1, vy: 5);
    var n = 0;
    while (w.bounces == 0 && n++ < 120) {
      w.step();
    }
    expect(w.bounces, 1);
    expect(w.vy, -16);
    expect(w.vx, 6);
    expect(w.py, lessThan(5));
    steps(w, 40);
    expect(w.py, lessThan(5 - kSwingPlayerRadius));
    expect(w.padFlash[0], 0);
  });

  test('spikes kill and the acrobat respawns at the last checkpoint', () {
    final w = SwingWorld.custom(
      sandbox(
        spikes: const [SwingSpike(20, -20, 2, 60)],
        checkpoints: const [SwingCheckpoint(10, -3)],
        killY: 40,
      ),
    )..debugPlace(5, 1, vx: 10);
    var n = 0;
    while (w.checkpoint < 0 && n++ < 120) {
      w.step();
    }
    expect(w.checkpoint, 0);
    expect(w.alive, isTrue);
    while (w.alive && n++ < 240) {
      w.step();
    }
    expect(w.phase, SwingPhase.dying);
    expect(w.fails, 1);
    expect(w.px, closeTo(20, 0.6));
    steps(w, (kSwingDeathDelay / kSwingStep).ceil() + 1);
    expect(w.alive, isTrue);
    expect(w.retriesLeft, kSwingRetries - 1);
    expect(w.px, closeTo(10 + w.level.launchVx * kSwingStep, 0.2));
    expect(w.py, closeTo(-3, 0.2));
  });

  test('falling into the pit costs a try; an idle player loses after 3 retries', () {
    final w = SwingWorld(levelNumber: 1);
    var n = 0;
    while (!w.isOver && n++ < 120 * 60) {
      w.step();
    }
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    expect(w.phase, SwingPhase.lost);
    expect(w.fails, kSwingRetries + 1);
    expect(w.retriesLeft, 0);
    expect(w.score, 0);
    // Further updates do nothing once the run is over.
    final fp = w.fingerprint();
    w.update(1);
    expect(w.fingerprint(), fp);
  });

  test('crossing the finish line wins and scores the clear bonus minus time', () {
    final w = SwingWorld(levelNumber: 1)..debugPlace(44, 5, vx: 10);
    while (!w.isOver) {
      w.step();
    }
    expect(w.won, isTrue);
    expect(w.score, w.clearBonus - w.timePenalty);
    expect(w.score, greaterThan(1000));
    expect(w.progress, 1);
  });

  test('full rotations while airborne count as flips and add style points', () {
    final w = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(0, 0)]))..debugPlace(0, 100);
    w.debugSetSpin(math.pi * 2); // one turn per second
    steps(w, 120 * 2 + 6);
    expect(w.flips, 2);
    w.debugSetSpin(-math.pi * 2); // either direction counts
    steps(w, 121);
    expect(w.flips, 3);
    // Spinning on the rope is not airborne and does not count.
    final r = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(0, 0)]))..debugPlace(-4, 0);
    r.debugAttach(0);
    steps(r, 120 * 8);
    expect(r.flips, 0);
    // Flips add points even without a clear; the clear adds the bonus on top.
    final f = SwingWorld(levelNumber: 1)..flips = 3;
    expect(f.score, 3 * kSwingFlipPoints);
  });

  test('moving anchors follow their paths and drag the rope with them', () {
    final w = SwingWorld.custom(sandbox(anchors: const [SwingAnchor(0, 0, dx: 2, period: 2)]))
      ..debugPlace(0, 3);
    w.debugAttach(0);
    steps(w, 60); // a quarter period
    expect(w.anchors[0].x, closeTo(2, 1e-6));
    final d = math.sqrt(math.pow(w.px - w.anchors[0].x, 2) + math.pow(w.py - w.anchors[0].y, 2));
    expect(d, lessThanOrEqualTo(w.ropeLength + 1e-9));
    expect(w.px, greaterThan(0));
  });

  test('every authored level and its looped variant validates', () {
    expect(kSwingLevels.length, greaterThanOrEqualTo(12));
    for (var n = 1; n <= kSwingLevels.length * 3; n++) {
      final l = swingLevel(n);
      expect(l.validate(), isEmpty, reason: 'level $n ${l.name}');
    }
    expect(kSwingLevels.any((l) => l.anchors.any((a) => a.moving)), isTrue);
    expect(kSwingLevels.any((l) => l.pads.isNotEmpty), isTrue);
    expect(kSwingLevels.any((l) => l.spikes.isNotEmpty), isTrue);
    // The looped variant is harder: shorter reach and every anchor moves.
    final base = swingLevel(1), loop = swingLevel(13);
    expect(loop.range, lessThan(base.range));
    expect(loop.anchors.every((a) => a.moving), isTrue);
    expect(loop.name, contains('+1'));
    // A broken level is reported.
    expect(const SwingLevel(name: 'x', anchors: [], finishX: 5).validate(), isNotEmpty);
  });

  test('the scripted player finishes levels 1-3', () {
    for (var n = 1; n <= 3; n++) {
      final w = playBot(SwingWorld(levelNumber: n));
      expect(w.won, isTrue, reason: 'level $n');
      expect(w.attaches, greaterThanOrEqualTo(3));
      expect(w.score, greaterThan(0));
    }
  });

  test('simulation is deterministic for the same inputs', () {
    String run(int level) {
      final w = playBot(SwingWorld(levelNumber: level, seed: 1));
      return '${w.fingerprint()}|${w.elapsed}|${w.attaches}|${w.score}';
    }

    expect(run(8), run(8));
    expect(run(12), run(12));
    // Variable frame times produce the same fixed-step result.
    final a = SwingWorld(levelNumber: 2), b = SwingWorld(levelNumber: 2);
    for (var i = 0; i < 300; i++) {
      a.update(1 / 60);
      b.update(i.isEven ? 1 / 40 : 1 / 120);
    }
    a.update(0.5 * kSwingStep);
    expect(a.elapsed, closeTo(b.elapsed, kSwingStep + 1e-9));
  });

  test('game reads the saved level, finishes once and unlocks the next level on a win', () {
    final save = CartridgeSave()..data['level'] = 2;
    var commits = 0;
    final context = CartridgeContext(
      manifest: SwingHookCartridge.kManifest,
      save: save,
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
      onSaveChanged: () => commits++,
    );
    late SwingHookGame game;
    final session = FlameCartridgeSession<SwingHookGame>(context, (s) => game = SwingHookGame(s, seed: 3));
    session.start();
    game.onGameResize(Vector2(400, 800));
    expect(game.levelNumber, 2);
    expect(game.swing.levelNumber, 2);
    game.swing.debugPlace(game.swing.level.finishX - 1, 5, vx: 10);
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, game.swing.score);
    expect(save.data['level'], 3);
    expect(commits, 1);
  });

  test('renderer smoke: hold and release drive the rope and every frame renders', () {
    final audio = SilentAudio();
    final context = CartridgeContext(
      manifest: SwingHookCartridge.kManifest,
      save: CartridgeSave(),
      audio: audio,
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    late SwingHookGame game;
    final session = FlameCartridgeSession<SwingHookGame>(context, (s) => game = SwingHookGame(s, seed: 8));
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    var attached = false;
    for (var i = 0; i < 600 && session.state == SessionState.running; i++) {
      final before = game.swing.holding;
      bot(game.swing);
      // Mirror the bot's decision through the real pointer path.
      if (game.swing.holding != before) {
        if (game.swing.holding) {
          game.swing.release();
          game.onPointerDown(Vector2(200, 400));
        } else {
          game.swing.press();
          game.onPointerUp(Vector2(200, 400));
        }
      }
      attached |= game.swing.attached;
      game.update(1 / 60);
      if (i % 10 == 0) paint();
    }
    paint();
    expect(attached, isTrue);
    expect(audio.played, contains(Sfx.whoosh));
    expect(game.entityCount, greaterThan(0));
    expect(game.swing.bestX, greaterThan(20));
  });
}
