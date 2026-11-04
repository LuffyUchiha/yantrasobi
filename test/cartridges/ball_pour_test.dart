import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/ball_pour/ball_pour.dart';
import 'package:yantrasobi/cartridges/ball_pour/circle_physics.dart';
import 'package:yantrasobi/cartridges/ball_pour/pour_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// Advances [w] by [seconds] in 60 Hz frames (a single `update` call is
/// clamped to 0.1 s to avoid a spiral of death).
void advance(PourWorld w, double seconds) {
  for (var t = 0.0; t < seconds - 1e-9; t += 1 / 60) {
    w.update(1 / 60);
  }
}

CirclePhysics box() => CirclePhysics(minX: -1, minY: -2, maxX: 11, maxY: 18);

/// A scripted player: sets every plank to its authored hint, then holds the
/// gate (only while the cup is near the authored x on swaying levels).
PourWorld play(int level, {int seed = 1, bool useHints = true, double maxTime = 90}) {
  final w = PourWorld(level: level, seed: seed);
  if (useHints) {
    for (var i = 0; i < w.planks.length; i++) {
      w.setPlankT(i, w.planks[i].def.hint);
    }
  }
  advance(w, 0.1);
  final px = w.def.pourAtCupX;
  var t = 0.0;
  while (!w.isOver && t < maxTime) {
    w.setGateOpen(w.hopper > 0 && (!useHints || px == null || (w.cupX - px).abs() < 0.5));
    w.update(1 / 60);
    t += 1 / 60;
  }
  return w;
}

/// A tiny level with the hopper right above a wide cup.
const PourLevelDef easyDef = PourLevelDef(
  name: 'Test Easy',
  balls: 12,
  target: 6,
  hopperX: 5,
  cup: CupDef(x: 5, bottom: 14.6, width: 3.4, height: 2.0),
);

/// A level whose stream misses the cup entirely.
const PourLevelDef missDef = PourLevelDef(
  name: 'Test Miss',
  balls: 12,
  target: 6,
  hopperX: 1.5,
  cup: CupDef(x: 7.5, bottom: 14.6, width: 2.4, height: 2.0),
);

/// A level whose stream lands in a closed tray that never reaches the cup.
const PourLevelDef trayDef = PourLevelDef(
  name: 'Test Tray',
  balls: 6,
  target: 6,
  hopperX: 5,
  cup: CupDef(x: 5, bottom: 14.6, width: 2.4, height: 2.0),
  walls: [WallDef(3.5, 6, 6.5, 6), WallDef(3.5, 5, 3.5, 6), WallDef(6.5, 5, 6.5, 6)],
);

CartridgeContext makeContext(CartridgeSave save, {void Function()? onSave}) => CartridgeContext(
  manifest: BallPourCartridge.kManifest,
  save: save,
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    expect(BallPourCartridge.kManifest.validate(), isEmpty);
    expect(BallPourCartridge.kManifest.id, 'ball-pour');
    expect(BallPourCartridge.kManifest.version, '1.0.0');
  });

  test('gravity accelerates a free ball', () {
    final p = box();
    final b = p.spawn(5, 0)!;
    var lastVy = b.vy;
    for (var i = 0; i < 60; i++) {
      p.step();
      expect(b.vy, greaterThan(lastVy));
      lastVy = b.vy;
    }
    // ~0.5 s of free fall: v ≈ g t, y ≈ g t² / 2, minus a few % of air damping.
    expect(b.vy, closeTo(p.gravity * 0.5, 0.5));
    expect(b.vy, lessThan(p.gravity * 0.5));
    expect(b.y, closeTo(p.gravity * 0.125, 0.2));
    expect(b.vx, 0);
  });

  test('a ball bounces on a floor segment and comes to rest, losing energy', () {
    final p = box();
    final floor = p.addSeg(PSeg(0, 8, 10, 8));
    final b = p.spawn(5, 2)!;
    var bounced = false;
    var touchedOnce = false;
    var peakEnergyAfterContact = 0.0;
    var firstEnergy = 0.0;
    for (var i = 0; i < 120 * 4; i++) {
      p.step();
      if (b.touching && !touchedOnce) {
        touchedOnce = true;
        firstEnergy = 0.5 * b.speed * b.speed + p.gravity * (8 - b.y);
      }
      if (touchedOnce && b.vy < -1) bounced = true;
      if (touchedOnce && i % 10 == 0) {
        final e = 0.5 * b.speed * b.speed + p.gravity * (8 - b.y);
        if (e > peakEnergyAfterContact) peakEnergyAfterContact = e;
      }
      expect(b.y, lessThan(8), reason: 'never passes through the floor');
    }
    expect(bounced, isTrue);
    expect(peakEnergyAfterContact, lessThan(firstEnergy));
    expect(b.speed, lessThan(CirclePhysics.restSpeed));
    expect(b.restTime, greaterThan(0.5));
    expect(b.y, closeTo(8 - b.radius - floor.thickness, 0.02));
  });

  test('settled balls do not overlap and nothing tunnels through thin segments', () {
    final p = box();
    p.addSeg(PSeg(2, 10, 8, 10));
    p.addSeg(PSeg(2, 4, 2, 10));
    p.addSeg(PSeg(8, 4, 8, 10));
    for (var i = 0; i < 60; i++) {
      p.spawn(2.4 + (i % 10) * 0.5, 4.5 - (i ~/ 10) * 0.5);
    }
    for (var i = 0; i < 120 * 5; i++) {
      p.step();
    }
    expect(p.minPairGap(), greaterThan(-0.03), reason: 'pairs overlap by at most a sliver');
    for (final b in p.balls) {
      expect(b.y, lessThan(10), reason: 'ball ${b.id} fell through the floor');
      expect(b.x, inInclusiveRange(2, 8));
    }

    // Fire balls at a very thin segment at absurd speeds from many angles.
    final q = box();
    q.addSeg(PSeg(1, 8, 9, 8, thickness: 0.01));
    for (var k = 0; k < 9; k++) {
      final a = math.pi / 2 + (k - 4) * 0.3;
      q.spawn(5 - math.cos(a) * 3, 8 - math.sin(a) * 3, vx: math.cos(a) * 200, vy: math.sin(a) * 200);
    }
    for (var i = 0; i < 240; i++) {
      q.step();
      for (final b in q.balls) {
        expect(b.y, lessThan(8), reason: 'ball ${b.id} tunnelled');
      }
    }
  });

  test('gate closed releases nothing; open lets balls flow at the flow rate', () {
    final w = PourWorld(def: easyDef, seed: 3);
    advance(w, 2);
    expect(w.liveBalls, 0);
    expect(w.hopper, easyDef.balls);
    w.setGateOpen(true);
    advance(w, 0.5);
    expect(w.released, greaterThan(3));
    expect(w.released, lessThanOrEqualTo((easyDef.flowRate * 0.5).ceil() + 1));
    expect(w.hopper, easyDef.balls - w.released);
    w.setGateOpen(false);
    final r = w.released;
    advance(w, 1);
    expect(w.released, r, reason: 'closing the gate stops the flow');
  });

  test('balls resting inside the cup are counted, balls outside are not', () {
    final w = PourWorld(def: easyDef);
    final c = easyDef.cup;
    for (var i = 0; i < 5; i++) {
      w.debugSpawn(c.x - 1 + i * 0.4, c.bottom - 0.5);
    }
    w.debugSpawn(0.5, 3); // far away, will fall off the bottom
    advance(w, 0.5);
    expect(w.cupCount, 5);
    for (final b in w.balls) {
      expect(w.inCup(b), b.x > 2);
    }
    advance(w, 2);
    expect(w.lost, 1);
    expect(w.cupCount, 5);
  });

  test('wins once the target is reached and everything settles', () {
    final w = PourWorld(def: easyDef, seed: 2);
    w.setGateOpen(true);
    var t = 0.0;
    while (!w.isOver && t < 30) {
      w.update(1 / 60);
      t += 1 / 60;
    }
    expect(w.isOver, isTrue);
    expect(w.won, isTrue);
    expect(w.cupCount, greaterThanOrEqualTo(easyDef.target));
    expect(w.score, w.cupCount * PourWorld.pointsPerBall + w.levelBonus);
    expect(w.gateOpen, isFalse);
    // Score is frozen after the run ends.
    final s = w.score;
    advance(w, 2);
    expect(w.score, s);
  });

  test('loses as soon as the target becomes unreachable', () {
    final w = PourWorld(def: missDef, seed: 2);
    w.setGateOpen(true);
    var t = 0.0;
    while (!w.isOver && t < 30) {
      w.update(1 / 60);
      t += 1 / 60;
    }
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    expect(w.cupCount, lessThan(missDef.target));
    // The loss is called the moment fewer than `target` balls remain.
    expect(w.lost, missDef.balls - missDef.target + 1);
    expect(w.potentialBalls, lessThan(missDef.target));
    expect(w.score, w.cupCount * PourWorld.pointsPerBall);

    // A stalemate (everything settled on a ledge, short of the target) loses too.
    final st = PourWorld(def: trayDef);
    st.setGateOpen(true);
    t = 0;
    while (!st.isOver && t < 30) {
      st.update(1 / 60);
      t += 1 / 60;
    }
    expect(st.isOver, isTrue);
    expect(st.won, isFalse);
    expect(st.lost, 0);
    expect(st.hopper, 0);
    expect(st.cupCount, 0);
    expect(st.liveBalls, trayDef.balls);
  });

  test('planks stay on their rails, move at limited speed, pivots clamp their angle', () {
    final w = PourWorld(level: 3); // one slide plank
    final p = w.planks.single;
    expect(p.t, p.def.start);
    w.movePlank(0, -50, 200); // far outside the rail
    expect(p.targetT, 0);
    w.stepSubsteps(1);
    final maxStep = PourWorld.plankSpeed * CirclePhysics.dt / p.railSpan;
    expect((p.def.start - p.t).abs(), closeTo(maxStep, 1e-9));
    advance(w, 3);
    expect(p.t, 0);
    expect(p.centerX, closeTo(p.def.ax, 1e-9));
    expect(p.centerY, closeTo(p.def.ay, 1e-9));
    // The segment keeps its length and angle.
    final s = p.seg;
    expect(math.sqrt(math.pow(s.bx - s.ax, 2) + math.pow(s.by - s.ay, 2)), closeTo(p.def.length, 1e-9));
    expect(math.atan2(s.by - s.ay, s.bx - s.ax), closeTo(p.def.angle * math.pi / 180, 1e-9));
    // Projection onto the rail.
    w.movePlank(0, (p.def.ax + p.def.bx) / 2, -100);
    expect(p.targetT, closeTo(0.5, 1e-9));
    advance(w, 2);
    expect(p.centerY, closeTo(p.def.ay, 1e-9), reason: 'slides only along the rail');

    final v = PourWorld(level: 5); // one pivot plank
    final q = v.planks.single;
    expect(q.isPivot, isTrue);
    v.movePlank(0, q.def.ax + 1, q.def.ay + 50); // ~ 89° down, beyond max
    advance(v, 2);
    expect(q.t, 1);
    expect(q.angle, closeTo(q.def.maxAngle * math.pi / 180, 1e-9));
    v.movePlank(0, q.def.ax + 1, q.def.ay - 50); // ~ -89°, beyond min
    advance(v, 2);
    expect(q.t, 0);
    expect(q.centerX, q.def.ax, reason: 'the pivot never moves');
  });

  test('every authored level validates; loops get harder but stay valid', () {
    expect(kPourLevels.length, greaterThanOrEqualTo(8));
    final names = <String>{};
    for (final d in kPourLevels) {
      expect(d.validate(), isEmpty, reason: d.name);
      expect(names.add(d.name), isTrue, reason: 'duplicate name ${d.name}');
      expect(d.target, lessThanOrEqualTo(d.balls));
    }
    for (var level = 1; level <= 40; level++) {
      expect(pourLevel(level).validate(), isEmpty, reason: 'level $level');
    }
    final n = kPourLevels.length;
    expect(pourLevel(n + 1).target, greaterThan(pourLevel(1).target));
    expect(pourLevel(n + 1).cup.width, lessThan(pourLevel(1).cup.width));
    expect(pourLevel(2 * n + 1).cup.sway, greaterThan(pourLevel(n + 1).cup.sway));
    // Difficulty trends upward through the authored list.
    expect(kPourLevels.last.target, greaterThan(kPourLevels.first.target));
    expect(kPourLevels.where((d) => d.planks.isNotEmpty).length, greaterThanOrEqualTo(4));
    expect(kPourLevels.where((d) => d.cup.sway > 0).length, greaterThanOrEqualTo(2));
    expect(kPourLevels.where((d) => d.rings.isNotEmpty).length, greaterThanOrEqualTo(2));
  });

  test('level 1 is won by a player who simply holds the gate', () {
    for (var seed = 0; seed < 3; seed++) {
      final w = play(1, seed: seed, useHints: false);
      expect(w.won, isTrue, reason: 'seed $seed');
    }
  });

  test('every authored level is winnable with its plank hints, and plank levels need them', () {
    for (var level = 1; level <= kPourLevels.length; level++) {
      final w = play(level, seed: 7);
      expect(w.won, isTrue, reason: 'level $level (${w.def.name}) cup ${w.cupCount}/${w.target}');
      if (w.def.planks.isNotEmpty) {
        final lazy = play(level, seed: 7, useHints: false);
        expect(lazy.won, isFalse, reason: 'level $level should need the planks');
      }
    }
  });

  test('multiplier rings split each passing ball once', () {
    final w = PourWorld(level: 6);
    final ring = w.def.rings.single;
    final b = w.debugSpawn(ring.x, ring.y - ring.r - 0.3, vy: 3)!;
    advance(w, 0.2);
    expect(w.splits, 1);
    expect(w.liveBalls, 2);
    expect(w.balls.every((x) => x.ringMask == 1), isTrue);
    expect(b.ringMask, 1);
    advance(w, 0.5);
    expect(w.splits, 1, reason: 'a ball never splits twice on the same ring');
  });

  test('simulation is deterministic for the same seed and inputs', () {
    String run(int seed) {
      final w = PourWorld(level: 8, seed: seed);
      w.setPlankT(0, 0.2);
      w.setPlankT(1, 0.7);
      w.setGateOpen(true);
      for (var i = 0; i < 300; i++) {
        if (i == 150) w.movePlank(1, 6, 10);
        w.update(1 / 60);
      }
      return w.debugSnapshot();
    }

    expect(run(5), run(5));
    expect(run(5), isNot(run(6)));
  });

  test('game reads the saved level, finishes once and unlocks the next level on a win', () {
    final save = CartridgeSave()..data['level'] = 1;
    var commits = 0;
    late BallPourGame game;
    final session = FlameCartridgeSession<BallPourGame>(
      makeContext(save, onSave: () => commits++),
      (s) => game = BallPourGame(s, seed: 4),
    );
    session.start();
    expect(game.level, 1);
    expect(game.pour.level, 1);
    game.pour.setGateOpen(true);
    for (var i = 0; i < 60 * 30 && session.state == SessionState.running; i++) {
      game.update(1 / 60);
    }
    expect(game.pour.won, isTrue);
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, game.pour.score);
    expect(save.data['level'], 2);
    expect(commits, 1);
  });

  test('renderer smoke: hold pours, dragging grabs the plank, renders without errors', () {
    final save = CartridgeSave()..data['level'] = 3;
    late BallPourGame game;
    final session = FlameCartridgeSession<BallPourGame>(
      makeContext(save),
      (s) => game = BallPourGame(s, seed: 8),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    // Hold on an empty spot near the top-left corner: the gate opens.
    game.onPointerDown(Vector2(30, 260));
    expect(game.pour.gateOpen, isTrue);
    for (var i = 0; i < 40; i++) {
      game.update(1 / 60);
    }
    expect(game.pour.released, greaterThan(0));
    game.onPointerUp(Vector2(30, 260));
    expect(game.pour.gateOpen, isFalse);
    paint();

    // Scan for the plank on screen and drag it to the left.
    final plank = game.pour.planks.single;
    final startT = plank.t;
    var grabbed = false;
    outer:
    for (var y = 100.0; y < 780 && !grabbed; y += 6) {
      for (var x = 10.0; x < 390; x += 6) {
        game.onPointerDown(Vector2(x, y));
        if (game.pour.gateOpen) {
          game.onPointerUp(Vector2(x, y));
          continue;
        }
        game.onPointerMove(Vector2(x - 150, y), Vector2(-150, 0));
        grabbed = true;
        for (var i = 0; i < 60; i++) {
          game.update(1 / 60);
        }
        game.onPointerUp(Vector2(x - 150, y));
        break outer;
      }
    }
    expect(grabbed, isTrue);
    expect(plank.t, lessThan(startT));
    paint();
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
  });
}
