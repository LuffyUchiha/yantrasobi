import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/tube_sort/sort_world.dart';
import 'package:yantrasobi/cartridges/tube_sort/tube_sort.dart';

void main() {
  test('manifest is valid', () => expect(TubeSortCartridge.kManifest.validate(), isEmpty));

  test('deals have capacity-many balls of each colour plus two empty tubes', () {
    for (var level = 1; level <= 10; level++) {
      final w = SortWorld(level: level, seed: level * 3);
      final colors = SortWorld.colorsForLevel(level);
      expect(w.t.length, colors + 2);
      final all = w.t.expand((x) => x).toList();
      for (var c = 0; c < colors; c++) {
        expect(all.where((b) => b == c).length, w.capacity);
      }
      expect(w.solved, isFalse);
    }
  });

  test('every generated deal is solvable by the solver', () {
    for (var level = 1; level <= 8; level++) {
      final w = SortWorld(level: level, seed: 100 + level);
      expect(SortSolver(w.capacity).solve(w.t), isNotNull, reason: 'level $level');
    }
  });

  test('pouring moves the whole top run onto a matching colour', () {
    final w = SortWorld.custom([
      [0, 1, 1],
      [2, 1],
      [],
    ]);
    expect(w.pour(0, 1), PourOutcome.poured);
    expect(w.t[0], [0]);
    expect(w.t[1], [2, 1, 1, 1]);
  });

  test('pouring is limited by space and blocked by mismatched colours', () {
    final w = SortWorld.custom([
      [0, 1, 1, 1],
      [2, 2, 2, 1],
      [0, 2],
    ]);
    expect(w.pour(0, 1), PourOutcome.invalid); // target full
    expect(w.pour(0, 2), PourOutcome.invalid); // colour mismatch
    expect(w.moves, 0);
  });

  test('undo reverses the last pour and is limited', () {
    final w = SortWorld.custom([
      [0, 1],
      [],
      [1, 0],
    ]);
    w.pour(0, 1);
    expect(w.undo(), isTrue);
    expect(w.t[0], [0, 1]);
    expect(w.t[1], isEmpty);
    w.undosLeft = 0;
    w.pour(0, 1);
    expect(w.undo(), isFalse);
  });

  test('solving wins and scores; replaying the solver path wins a real deal', () {
    final w = SortWorld(level: 3, seed: 5);
    final plan = SortSolver(w.capacity).solve(w.t)!;
    for (final (a, b) in plan) {
      expect(w.pour(a, b), PourOutcome.poured);
    }
    expect(w.phase, SortPhase.won);
    expect(w.score, greaterThan(300));
  });

  test('stuck with no powers left loses; an extra tube rescues a stuck board', () {
    final stuck = SortWorld.custom([
      [0, 1, 0, 1],
      [1, 0, 1, 0],
    ]);
    expect(stuck.stuck, isTrue);
    expect(stuck.addTube(), isTrue);
    expect(stuck.stuck, isFalse);
    final doomed =
        SortWorld.custom([
            [0, 1],
            [1, 0],
            [0, 1],
          ], capacity: 2)
          ..undosLeft = 0
          ..extraTubesLeft = 0;
    doomed.pour(0, 0); // invalid move does not change state
    expect(doomed.hasLegalMove, isFalse);
    doomed.concede();
    expect(doomed.phase, SortPhase.lost);
  });

  test('same seed gives the same deal; levels add colours', () {
    expect(SortWorld(level: 4, seed: 9).t, SortWorld(level: 4, seed: 9).t);
    expect(SortWorld.colorsForLevel(1), lessThan(SortWorld.colorsForLevel(9)));
  });
}
