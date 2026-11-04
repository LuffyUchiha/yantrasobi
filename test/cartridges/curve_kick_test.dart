import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/curve_kick/curve_kick.dart';
import 'package:yantrasobi/cartridges/curve_kick/kick_levels.dart';
import 'package:yantrasobi/cartridges/curve_kick/kick_world.dart';

const Pt leftCorner = Pt(kPitchWidth / 2 - kGoalWidth / 2 + 0.6, -1);
const Pt rightCorner = Pt(kPitchWidth / 2 + kGoalWidth / 2 - 0.6, -1);

/// Replays [plan] (a list of paths) on a fresh world.
KickWorld replay(int level, List<List<Pt>> plan) {
  final w = KickWorld(levelNumber: level);
  for (final p in plan) {
    w.debugDrawPath(p);
    w.runUntilSettled();
    if (w.isOver) break;
  }
  return w;
}

/// Brute-force planner: one-waypoint paths to goal corners or to team-mates.
List<List<Pt>>? solve(int level, {int depth = 3}) {
  final base = KickWorld(levelNumber: level);
  List<List<Pt>>? search(List<List<Pt>> prefix, int d) {
    final probe = replay(level, prefix);
    if (probe.phase == KickPhase.won) return prefix;
    if (d == 0 || probe.isOver || probe.attemptsLeft < base.def.attempts) return null;
    final targets = <(Pt, bool)>[(leftCorner, true), (rightCorner, true)];
    final mates = probe.mates;
    for (var i = 0; i < mates.length; i++) {
      if (i != probe.holderIndex) targets.add((mates[i], false));
    }
    for (final (target, isShot) in targets) {
      for (var wx = 2.0; wx <= kPitchWidth - 2; wx += 3) {
        for (var wy = 2.0; wy <= 46; wy += 3) {
          final plan = [
            ...prefix,
            [Pt(wx, wy), target],
          ];
          final w = replay(level, plan);
          if (w.phase == KickPhase.won) return plan;
          if (!isShot && w.passes > probe.passes && w.attemptsLeft == base.def.attempts) {
            final deeper = search(plan, d - 1);
            if (deeper != null) return deeper;
          }
        }
      }
    }
    return null;
  }

  return search([], depth);
}

void main() {
  test('manifest is valid', () => expect(CurveKickCartridge.kManifest.validate(), isEmpty));

  test('paths start only near the ball holder and respect the length budget', () {
    final w = KickWorld(levelNumber: 1);
    expect(w.beginPath(1, 1), isFalse);
    expect(w.beginPath(w.holder.x, w.holder.y), isTrue);
    for (var y = w.holder.y; y > -60; y -= 0.6) {
      w.extendPath(w.holder.x, y);
    }
    expect(w.pathLength, lessThanOrEqualTo(KickWorld.maxPathLength + 1e-9));
  });

  test('a tiny scribble is cancelled, not kicked', () {
    final w = KickWorld(levelNumber: 1);
    w.beginPath(w.holder.x, w.holder.y);
    w.extendPath(w.holder.x + 0.6, w.holder.y);
    w.releasePath();
    expect(w.phase, KickPhase.aiming);
    expect(w.path, isEmpty);
  });

  test('a shot into the far corner beats a slow keeper', () {
    final w = replay(1, [
      [leftCorner],
    ]);
    expect(w.phase, KickPhase.won);
    expect(w.score, greaterThan(1000));
  });

  test('a shot straight at the keeper is saved and costs an attempt', () {
    final w = replay(1, [
      [const Pt(kPitchWidth / 2, -1)],
    ]);
    expect(w.phase, KickPhase.aiming);
    expect(w.attemptsLeft, 2);
  });

  test('shots wide of the posts miss', () {
    final w = replay(1, [
      [const Pt(2, -1)],
    ]);
    expect(w.attemptsLeft, 2);
  });

  test('defenders intercept balls passing close to them', () {
    final w = KickWorld(levelNumber: 2);
    final d = w.defenderAt(0);
    w.debugDrawPath([Pt(d.x, d.y + 0.2), leftCorner]);
    w.runUntilSettled();
    expect(w.attemptsLeft, w.def.attempts - 1);
  });

  test('ending a path on a team-mate passes the ball', () {
    final w = KickWorld(levelNumber: 3);
    final mate = w.mates.first;
    w.debugDrawPath([Pt(mate.x, mate.y + 8), mate]);
    w.runUntilSettled();
    expect(w.passes, 1);
    expect(w.holderIndex, 0);
    expect(w.phase, KickPhase.aiming);
  });

  test('running out of attempts loses', () {
    final w = KickWorld(levelNumber: 1);
    for (var i = 0; i < 3; i++) {
      w.debugDrawPath([const Pt(1, 40)]);
      w.runUntilSettled();
    }
    expect(w.phase, KickPhase.lost);
  });

  test('every authored moment has a solution found by the planner', () {
    for (var level = 1; level <= kKickLevels.length; level++) {
      expect(solve(level), isNotNull, reason: 'level $level has no solution');
    }
  });

  test('levels loop with faster keepers', () {
    final first = KickWorld(levelNumber: 1), looped = KickWorld(levelNumber: kKickLevels.length + 1);
    expect(looped.def.name, first.def.name);
    expect(looped.keeperSpeed, greaterThan(first.keeperSpeed));
  });

  test('simulation is deterministic', () {
    final plan = [
      [const Pt(30, 10), rightCorner],
    ];
    final a = replay(5, plan), b = replay(5, plan);
    expect(a.attemptsLeft, b.attemptsLeft);
    expect(a.keeperX, b.keeperX);
  });
}
