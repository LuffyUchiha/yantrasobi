import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/blade_toss/blade_toss.dart';
import 'package:yantrasobi/cartridges/blade_toss/toss_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double step = TossWorld.step;
const double eps = 1e-9;

StagePlan still({List<double> obstacles = const [], List<double> gems = const [], int blades = 5}) =>
    StagePlan(stage: 1, blades: blades, script: MotionScript.constant(0), obstacles: obstacles, gems: gems);

/// Waits for the predicted landing spot to be clear, then throws.
/// Returns true once [stages] stages are cleared.
bool safeBot(TossWorld w, {int stages = 10, double maxSeconds = 600}) {
  final maxTicks = (maxSeconds / step).round();
  for (var i = 0; i < maxTicks; i++) {
    if (w.stagesCleared >= stages) return true;
    if (w.isOver) return false;
    if (w.canThrow && w.isSafeRel(w.predictImpactRel(), margin: 0.02)) w.throwBlade();
    w.update(step);
  }
  return w.stagesCleared >= stages;
}

/// Lands one blade immediately (zero-speed targets).
void throwAndLand(TossWorld w) {
  expect(w.throwBlade(), isTrue);
  w.debugAdvanceTicks(TossWorld.flightTicks);
}

String planSnapshot(StagePlan p) => [
  p.blades,
  p.script.name,
  p.script.netAngle.toStringAsFixed(6),
  ...p.obstacles.map((a) => a.toStringAsFixed(6)),
  '|',
  ...p.gems.map((a) => a.toStringAsFixed(6)),
].join(',');

CartridgeContext makeContext({CartridgeSave? save, void Function()? onSave}) => CartridgeContext(
  manifest: BladeTossCartridge.kManifest,
  save: save ?? CartridgeSave(),
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    const m = BladeTossCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'blade-toss');
    expect(m.version, '1.0.0');
  });

  test('angle helpers normalise and measure the short way round', () {
    expect(normAngle(-math.pi / 2), closeTo(3 * math.pi / 2, eps));
    expect(normAngle(5 * math.pi), closeTo(math.pi, eps));
    expect(angleGap(0.1, 2 * math.pi - 0.1), closeTo(0.2, eps));
    expect(angleGap(1, 1 + math.pi), closeTo(math.pi, eps));
  });

  test('motion scripts: constant, swell, reverse, stop-and-go integrate and loop', () {
    final c = MotionScript.constant(2);
    expect(c.angleAt(1.5), closeTo(3, eps));
    expect(c.speedAt(0.7), closeTo(2, eps));

    final s = MotionScript.swell(2);
    expect(s.speedAt(0), closeTo(0.7, eps));
    expect(s.speedAt(1.3), closeTo(3.2, eps));
    expect(s.speedAt(1.95), lessThan(s.speedAt(1.3)), reason: 'decelerates after the peak');
    expect(s.angleAt(s.period), closeTo(s.netAngle, 1e-6));

    final r = MotionScript.reverse(2);
    expect(r.speedAt(0.5), greaterThan(0));
    expect(r.speedAt(2.3), lessThan(0), reason: 'spins backwards in the middle');
    // Angle goes down while reversing.
    expect(r.angleAt(2.6), lessThan(r.angleAt(2.2)));

    final g = MotionScript.stopAndGo(2);
    expect(g.speedAt(1.6), 0);
    expect(g.angleAt(1.5), closeTo(g.angleAt(1.85), 1e-9), reason: 'held still');

    for (final m in [c, s, r, g, MotionScript.lurch(2), MotionScript.grind(2)]) {
      // Continuous: no jumps between neighbouring samples.
      for (var t = 0.0; t < m.period * 2; t += 0.01) {
        expect((m.angleAt(t + 0.01) - m.angleAt(t)).abs(), lessThan(0.01 * 4.5));
      }
      // Loops with a fixed net rotation per period.
      expect(m.angleAt(0.37 + m.period), closeTo(m.angleAt(0.37) + m.netAngle, 1e-6));
      expect(m.netAngle.abs(), greaterThan(0.5), reason: '${m.name} must sweep the whole circle');
      // Flipping direction mirrors the motion.
      expect(m.scaled(-1).angleAt(1.1), closeTo(-m.angleAt(1.1), 1e-9));
    }
  });

  test('a blade sticks at the impact angle relative to the rotating target', () {
    final plan = StagePlan(stage: 1, blades: 5, script: MotionScript.constant(2.0));
    final w = TossWorld.custom(plan);
    w.debugAdvanceTicks(37);
    final predicted = w.predictImpactRel();
    final launchTicks = 37;
    expect(w.throwBlade(), isTrue);
    expect(w.throwBlade(), isFalse, reason: 'one blade in flight at a time');
    expect(w.phase, TossPhase.flying);
    w.debugAdvanceTicks(TossWorld.flightTicks);
    expect(w.phase, TossPhase.ready);
    expect(w.stuck, hasLength(1));
    final expected = normAngle(math.pi / 2 - 2.0 * (launchTicks + TossWorld.flightTicks) * step);
    expect(w.stuck.single.rel, closeTo(expected, 1e-9));
    expect(w.stuck.single.rel, closeTo(predicted, 1e-9));
    // On screen the blade is at the bottom right after landing...
    expect(normAngle(w.stuck.single.rel + w.rotation), closeTo(math.pi / 2, 1e-9));
    // ...and is carried round with the target afterwards.
    w.debugAdvanceTicks(60);
    expect(normAngle(w.stuck.single.rel + w.rotation), closeTo(normAngle(math.pi / 2 + 1.0), 1e-9));
    expect(w.bladesLeft, 4);
    expect(w.bladesStuck, 1);
  });

  test('landing within the collision width of a stuck blade fails the run', () {
    final w = TossWorld.custom(still());
    throwAndLand(w);
    expect(w.stuck.single.rel, closeTo(math.pi / 2, eps));
    throwAndLand(w);
    expect(w.isOver, isTrue);
    expect(w.phase, TossPhase.lost);
    expect(w.failRel, closeTo(math.pi / 2, eps));
    expect(w.stuck, hasLength(1), reason: 'the failed blade does not stick');
    expect(w.throwBlade(), isFalse);
    expect(w.events.any((e) => e.kind == TossEventKind.fail), isTrue);
  });

  test('pre-placed obstacle blades collide; just outside the width is safe', () {
    final near = TossWorld.custom(still(obstacles: [math.pi / 2 + TossWorld.collisionWidth * 0.9]));
    expect(near.stuck.single.obstacle, isTrue);
    expect(near.isSafeRel(near.predictImpactRel()), isFalse);
    throwAndLand(near);
    expect(near.isOver, isTrue);

    final far = TossWorld.custom(still(obstacles: [math.pi / 2 - TossWorld.collisionWidth * 1.05]));
    expect(far.isSafeRel(far.predictImpactRel()), isTrue);
    throwAndLand(far);
    expect(far.isOver, isFalse);
    expect(far.stuck, hasLength(2));
  });

  test('throwing every blade clears the stage, then the next stage loads', () {
    final w = TossWorld(seed: 3);
    expect(w.stage, 1);
    expect(w.plan.blades, TossWorld.bladesFor(1));
    var guard = 0;
    while (w.phase != TossPhase.clearing && guard++ < 100000) {
      if (w.canThrow && w.isSafeRel(w.predictImpactRel(), margin: 0.02)) w.throwBlade();
      w.update(step);
    }
    expect(w.phase, TossPhase.clearing);
    expect(w.bladesLeft, 0);
    expect(w.stagesCleared, 1);
    expect(w.throwBlade(), isFalse, reason: 'no throws during the clear pause');
    expect(w.events.any((e) => e.kind == TossEventKind.stageClear), isTrue);
    w.debugAdvanceTicks(TossWorld.clearTicks);
    expect(w.stage, 2);
    expect(w.phase, TossPhase.ready);
    expect(w.bladesLeft, TossWorld.bladesFor(2));
    expect(w.stuck.where((b) => !b.obstacle), isEmpty);
    expect(w.stuck.length, TossWorld.obstaclesFor(2));
    expect(w.score, 2 * 100 + TossWorld.bladesFor(1) + w.gemsCollected * TossWorld.gemValue);
  });

  test('hitting a gem on the rim collects it for bonus score', () {
    final w = TossWorld.custom(still(gems: [math.pi / 2 + 0.1, 0.3]));
    expect(w.score, 100);
    throwAndLand(w);
    expect(w.gemsCollected, 1);
    expect(w.gems[0].taken, isTrue);
    expect(w.gems[1].taken, isFalse);
    expect(w.events.where((e) => e.kind == TossEventKind.gem), hasLength(1));
    expect(w.score, 100 + 1 + TossWorld.gemValue);
  });

  test('every fifth stage is a boss with its own shape and motion', () {
    for (var stage = 1; stage <= 30; stage++) {
      final p = TossWorld.planFor(9, stage);
      final boss = stage % 5 == 0;
      expect(p.isBoss, boss, reason: 'stage $stage');
      expect(TossWorld.isBossStage(stage), boss);
      if (boss) {
        expect(p.shape, isNot(TargetShape.disc));
        expect(p.script.name, anyOf('lurch', 'grind'));
      } else {
        expect(p.shape, TargetShape.disc);
        expect(p.script.name, isNot(anyOf('lurch', 'grind')));
      }
    }
    expect(TossWorld.planFor(1, 5).shape, isNot(TossWorld.planFor(1, 10).shape));
    expect(TossWorld.planFor(4, 1).script.name, 'constant');
  });

  test('generation always leaves a safe window, even for the last blade', () {
    for (var seed = 0; seed < 12; seed++) {
      for (var stage = 1; stage <= 60; stage++) {
        final p = TossWorld.planFor(seed, stage);
        final items = p.obstacles.length + p.blades - 1;
        expect(items * 2 * TossWorld.collisionWidth, lessThanOrEqualTo(2 * math.pi - TossWorld.minFreeArc));
        expect(p.script.netAngle.abs(), greaterThan(0.5), reason: 'every angle comes round');
        for (var i = 0; i < p.obstacles.length; i++) {
          for (var j = i + 1; j < p.obstacles.length; j++) {
            expect(
              angleGap(p.obstacles[i], p.obstacles[j]),
              greaterThanOrEqualTo(2 * TossWorld.collisionWidth),
            );
          }
          for (final g in p.gems) {
            expect(angleGap(p.obstacles[i], g), greaterThanOrEqualTo(TossWorld.collisionWidth));
          }
        }
      }
    }
    // Later stages are harder: more blades, more obstacles, faster spin.
    expect(TossWorld.bladesFor(9), greaterThan(TossWorld.bladesFor(1)));
    expect(TossWorld.obstaclesFor(9), greaterThan(TossWorld.obstaclesFor(1)));
    expect(TossWorld.baseSpeed(12), greaterThan(TossWorld.baseSpeed(1)));
  });

  test('same seed plays out identically; different seeds differ', () {
    String run(int seed) {
      final w = TossWorld(seed: seed);
      final log = <String>[];
      for (var i = 0; i < 120 * 40 && !w.isOver; i++) {
        if (w.canThrow && w.isSafeRel(w.predictImpactRel(), margin: 0.02)) w.throwBlade();
        w.update(step);
        for (final e in w.events) {
          log.add('${e.kind.name}:${e.rel.toStringAsFixed(5)}');
        }
        w.events.clear();
      }
      return '${log.join(';')}#${w.score}#${w.stage}';
    }

    expect(run(42), run(42));
    expect(run(42), isNot(run(43)));
    expect(planSnapshot(TossWorld.planFor(7, 6)), planSnapshot(TossWorld.planFor(7, 6)));
    expect(planSnapshot(TossWorld.planFor(7, 6)), isNot(planSnapshot(TossWorld.planFor(8, 6))));
  });

  test('a bot that waits for a safe window clears 10 stages (two bosses) for many seeds', () {
    for (var seed = 0; seed < 8; seed++) {
      final w = TossWorld(seed: seed);
      var shatters = 0;
      final maxTicks = (900 / step).round();
      for (var i = 0; i < maxTicks && w.stagesCleared < 10 && !w.isOver; i++) {
        if (w.canThrow && w.isSafeRel(w.predictImpactRel(), margin: 0.02)) w.throwBlade();
        w.update(step);
        shatters += w.events.where((e) => e.kind == TossEventKind.bossShatter).length;
        w.events.clear();
      }
      expect(w.isOver, isFalse, reason: 'seed $seed');
      expect(w.stagesCleared, 10, reason: 'seed $seed');
      expect(shatters, 2);
      expect(w.bossesCleared, 2);
      expect(w.gemsCollected, greaterThanOrEqualTo(0));
    }
    expect(safeBot(TossWorld(seed: 99), stages: 3), isTrue);
  });

  test('a player who throws blindly soon clashes', () {
    var lost = 0;
    for (var seed = 0; seed < 10; seed++) {
      final w = TossWorld(seed: seed);
      for (var i = 0; i < 120 * 60 && !w.isOver; i++) {
        w.throwBlade();
        w.update(step);
      }
      if (w.isOver) lost++;
    }
    expect(lost, 10);
  });

  test('game finishes once with won null and stores the best stage', () {
    final save = CartridgeSave()..data['bestStage'] = 1;
    var commits = 0;
    late BladeTossGame game;
    final session = FlameCartridgeSession<BladeTossGame>(
      makeContext(save: save, onSave: () => commits++),
      (s) => game = BladeTossGame(s, seed: 5),
    );
    session.start();
    expect(game.bestStage, 1);
    final w = game.toss;
    safeBot(w, stages: 2);
    expect(w.stagesCleared, 2);
    w.debugAdvanceTicks(TossWorld.clearTicks);
    expect(w.stage, 3);
    // Throw straight into a stuck blade on purpose.
    while (!w.isOver) {
      if (w.canThrow && !w.isSafeRel(w.predictImpactRel())) {
        w.throwBlade();
      } else if (w.canThrow && w.stuck.isEmpty) {
        w.throwBlade();
      }
      game.update(step);
    }
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isNull);
    expect(session.result!.score, w.score);
    expect(w.score, w.stage * 100 + w.bladesStuck + w.gemsCollected * TossWorld.gemValue);
    expect(save.data['bestStage'], 3);
    expect(save.intData('gems'), w.gemsCollected);
    expect(commits, 1);
  });

  test('renderer smoke: taps throw blades and every phase renders without errors', () {
    late BladeTossGame game;
    final session = FlameCartridgeSession<BladeTossGame>(
      makeContext(),
      (s) => game = BladeTossGame(s, seed: 8),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    // Play with on-screen taps, only when the landing spot is safe, through a boss.
    for (var i = 0; i < 120 * 200 && game.toss.stagesCleared < 5; i++) {
      final w = game.toss;
      if (w.canThrow && w.isSafeRel(w.predictImpactRel(), margin: 0.02)) {
        game.onPointerDown(Vector2(200, 600));
      }
      game.update(step);
      if (i % 30 == 0) paint();
    }
    expect(game.toss.stagesCleared, 5);
    expect(game.toss.bossesCleared, 1);
    expect(game.entityCount, greaterThan(0));
    paint();
    // Now clash on purpose and render the fail state.
    while (!game.toss.isOver) {
      game.onPointerDown(Vector2(200, 600));
      game.update(step);
    }
    for (var i = 0; i < 90; i++) {
      game.update(1 / 60);
      paint();
    }
    expect(session.state, SessionState.ended);
  });
}
