import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/gridlock/gridlock.dart';
import 'package:yantrasobi/cartridges/gridlock/gridlock_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// 6x6 lot:
///   0: car at (0,0)-(1,0) facing right, blocked by 1 at (3,0).
///   1: vertical car at (3,0)-(3,1) facing down; road below is clear.
///   2: truck at (5,3)-(5,5) facing up; road above is clear.
///   3: car at (0,5)-(1,5) facing left; at the edge already.
GridlockWorld sample() => GridlockWorld.custom(6, 6, [
  Vehicle(0, 0, 0, 2, Heading.right),
  Vehicle(1, 3, 0, 2, Heading.down),
  Vehicle(2, 5, 3, 3, Heading.up),
  Vehicle(3, 0, 5, 2, Heading.left),
]);

String positions(GridlockWorld w) => w.vehicles.map((v) => '${v.id}:${v.col},${v.row},${v.exited}').join(' ');

CartridgeContext makeContext(CartridgeSave save, {void Function()? onSave}) => CartridgeContext(
  manifest: GridlockCartridge.kManifest,
  save: save,
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    expect(GridlockCartridge.kManifest.validate(), isEmpty);
    expect(GridlockCartridge.kManifest.id, 'gridlock');
    expect(GridlockCartridge.kManifest.version, '1.0.0');
  });

  test('generated lots have no overlapping vehicles and stay in bounds', () {
    for (var level = 1; level <= 14; level++) {
      for (var seed = 0; seed < 6; seed++) {
        final w = GridlockWorld(seed: seed, level: level);
        expect(w.vehicles, isNotEmpty);
        final seen = <(int, int)>{};
        for (final v in w.vehicles) {
          expect(v.length, inInclusiveRange(2, 3));
          for (final cell in v.cells) {
            expect(w.inBounds(cell.$1, cell.$2), isTrue, reason: 'L$level s$seed $v');
            expect(seen.add(cell), isTrue, reason: 'overlap at $cell L$level s$seed');
            expect(w.vehicleAt(cell.$1, cell.$2), same(v));
          }
        }
        expect(w.solution.toSet(), {for (final v in w.vehicles) v.id});
      }
    }
  });

  test('canExit is true only for a clear road to the edge', () {
    final w = sample();
    expect(w.canExit(0), isFalse, reason: 'vehicle 1 sits in its lane');
    expect(w.canExit(1), isTrue);
    expect(w.canExit(2), isTrue);
    expect(w.canExit(3), isTrue);
    expect(w.canExit(99), isFalse);
    expect(w.probe(w.vehicles[0]), (1, 1));
    expect(w.vehicleAt(3, 1)!.id, 1);
    expect(w.vehicleAt(2, 0), isNull);
    expect(w.vehicleAt(-1, 0), isNull);
    // Once the blocker leaves, the road opens.
    w.tap(1);
    expect(w.canExit(0), isTrue);
    expect(w.vehicleAt(3, 1), isNull);
  });

  test('tapping an exitable vehicle removes it and scores', () {
    final w = sample();
    final r = w.tap(2);
    expect(r.outcome, GridlockOutcome.exited);
    expect(r.vehicle!.id, 2);
    expect(r.travel, 3);
    expect(w.vehicles[2].exited, isTrue);
    expect(w.vehicleAt(5, 4), isNull);
    expect(w.score, GridlockWorld.pointsPerCar);
    expect(w.carsLeft, 3);
    expect(w.entityCount, 3);
    expect(w.tap(2).outcome, GridlockOutcome.invalid, reason: 'already gone');
    expect(w.tap(-4).outcome, GridlockOutcome.invalid);
  });

  test('a blocked tap adds a strike and changes no positions', () {
    final w = sample();
    final before = positions(w);
    final grid = w.debugAscii();
    final r = w.tap(0);
    expect(r.outcome, GridlockOutcome.blocked);
    expect(r.blockerId, 1);
    expect(r.travel, 1);
    expect(w.strikes, 1);
    expect(w.strikesLeft, 2);
    expect(w.score, 0);
    expect(positions(w), before);
    expect(w.debugAscii(), grid);
    expect(w.isOver, isFalse);
  });

  test('three strikes lose and freeze the lot', () {
    final w = sample();
    expect(w.tap(0).outcome, GridlockOutcome.blocked);
    expect(w.tap(0).outcome, GridlockOutcome.blocked);
    expect(w.isOver, isFalse);
    expect(w.tap(0).outcome, GridlockOutcome.blocked);
    expect(w.phase, GridlockPhase.lost);
    expect(w.isOver, isTrue);
    expect(w.tap(1).outcome, GridlockOutcome.invalid);
    expect(w.hint(), isNull);
    w.update(5);
    expect(w.time, 0);
  });

  test('clearing the lot wins with no-bump and time bonuses', () {
    final w = sample();
    w.update(4);
    for (final id in [1, 0, 2, 3]) {
      expect(w.tap(id).outcome, GridlockOutcome.exited);
    }
    expect(w.won, isTrue);
    expect(w.perfectBonus, 4 * GridlockWorld.perfectBonusPerCar);
    // par = 4 cars * 2.5 + 10 = 20s, played 4s -> 16 * 2.
    expect(w.timeBonus, 16 * GridlockWorld.timeBonusPerSecond);
    expect(w.score, 4 * GridlockWorld.pointsPerCar + w.perfectBonus + w.timeBonus);

    final bumped = sample();
    bumped.tap(0);
    for (final id in [1, 0, 2, 3]) {
      bumped.tap(id);
    }
    expect(bumped.won, isTrue);
    expect(bumped.perfectBonus, 0);
  });

  test('following the solution order wins every level 1..12 without a strike', () {
    for (var level = 1; level <= 12; level++) {
      for (var seed = 0; seed < 8; seed++) {
        final w = GridlockWorld(seed: seed, level: level);
        for (final id in w.solution) {
          expect(w.tap(id).outcome, GridlockOutcome.exited, reason: 'L$level s$seed id $id');
        }
        expect(w.won, isTrue);
        expect(w.strikes, 0);
      }
    }
  });

  test('a greedy player tapping any exitable vehicle always wins', () {
    for (var level = 1; level <= 12; level++) {
      for (var seed = 0; seed < 8; seed++) {
        final w = GridlockWorld(seed: seed, level: level);
        while (!w.isOver) {
          final free = w.exitable();
          expect(free, isNotEmpty, reason: 'stuck on L$level s$seed\n${w.debugAscii()}');
          // Take the last one to deliberately diverge from the solution order.
          w.tap(free.last.id);
        }
        expect(w.won, isTrue);
      }
    }
  });

  test('hint returns an exitable vehicle and is limited to two per run', () {
    final w = GridlockWorld(seed: 9, level: 5);
    expect(w.peekHint(), isNotNull);
    final h1 = w.hint()!;
    expect(w.canExit(h1.id), isTrue);
    expect(w.hintsLeft, 1);
    w.tap(h1.id);
    final h2 = w.hint()!;
    expect(w.canExit(h2.id), isTrue);
    expect(w.hintsLeft, 0);
    expect(w.hint(), isNull);
    // Hint-guided play (via peekHint) clears every lot.
    for (var level = 1; level <= 10; level++) {
      final g = GridlockWorld(seed: 40 + level, level: level);
      while (!g.isOver) {
        g.tap(g.peekHint()!.id);
      }
      expect(g.won, isTrue);
    }
    // Custom lots without a solution still get a hint.
    expect(sample().hint()!.id, isNot(0));
  });

  test('same seed + level gives the same lot; different seeds differ', () {
    final a = GridlockWorld(seed: 77, level: 6);
    final b = GridlockWorld(seed: 77, level: 6);
    expect(a.debugSignature(), b.debugSignature());
    expect(a.solution, b.solution);
    expect(a.debugSignature(), isNot(GridlockWorld(seed: 78, level: 6).debugSignature()));
    expect(a.debugSignature(), isNot(GridlockWorld(seed: 77, level: 7).debugSignature()));
  });

  test('difficulty scales with level: bigger, denser lots with more trucks', () {
    var prevCells = 0, prevTarget = 0;
    for (var level = 1; level <= 20; level++) {
      final cells = GridlockWorld.colsForLevel(level) * GridlockWorld.rowsForLevel(level);
      final target = GridlockWorld.targetCarsFor(level);
      expect(cells, greaterThanOrEqualTo(prevCells));
      expect(target, greaterThanOrEqualTo(prevTarget));
      prevCells = cells;
      prevTarget = target;
    }
    expect(GridlockWorld.colsForLevel(1), 6);
    expect(GridlockWorld.rowsForLevel(1), 8);
    expect(GridlockWorld.colsForLevel(30), 9);
    expect(GridlockWorld.rowsForLevel(30), 12);

    (double, double, double) avg(int level) {
      var cars = 0, trucks = 0, fill = 0.0;
      const n = 10;
      for (var s = 0; s < n; s++) {
        final w = GridlockWorld(seed: s, level: level);
        cars += w.vehicles.length;
        trucks += w.vehicles.where((v) => v.length == 3).length;
        fill += w.vehicles.fold<int>(0, (t, v) => t + v.length) / (w.cols * w.rows);
      }
      return (cars / n, trucks / n, fill / n);
    }

    final easy = avg(1);
    final hard = avg(10);
    expect(hard.$1, greaterThan(easy.$1 * 2));
    expect(hard.$2, greaterThan(easy.$2));
    expect(hard.$3, greaterThan(easy.$3));
    // Not everything can leave at the start.
    final w = GridlockWorld(seed: 3, level: 8);
    expect(w.exitable().length, lessThan(w.vehicles.length));
  });

  test('game reads the saved level, finishes once and unlocks the next level on a win', () {
    final save = CartridgeSave()..data['level'] = 3;
    var commits = 0;
    late GridlockGame game;
    final session = FlameCartridgeSession<GridlockGame>(
      makeContext(save, onSave: () => commits++),
      (s) => game = GridlockGame(s, seed: 5),
    );
    session.start();
    expect(game.level, 3);
    expect(game.lot.level, 3);
    for (final id in game.lot.solution) {
      game.lot.tap(id);
    }
    expect(game.lot.won, isTrue);
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, game.lot.score);
    expect(save.data['level'], 4);
    expect(commits, 1);
  });

  test('renderer smoke: on-screen taps drive vehicles, hint button works, losing ends the run', () {
    final save = CartridgeSave();
    late GridlockGame game;
    final session = FlameCartridgeSession<GridlockGame>(
      makeContext(save),
      (s) => game = GridlockGame(s, seed: 8),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    final lot = game.lot;
    final total = lot.vehicles.length;
    final hb = game.hintButtonRect;
    expect(hb.bottom, lessThanOrEqualTo(800));
    game.onPointerDown(Vector2(hb.center.dx, hb.center.dy));
    expect(lot.hintsLeft, GridlockWorld.startHints - 1);
    // Scan the screen until a tap drives a vehicle off the lot.
    outer:
    for (var y = 120.0; y < 720; y += 10) {
      for (var x = 10.0; x < 390; x += 10) {
        final hinted = lot.peekHint()!;
        // Only tap the cell under an exitable vehicle so the scan never strikes.
        final v = game.vehicleAtPoint(Offset(x, y));
        if (v == null || v.id != hinted.id) continue;
        game.onPointerDown(Vector2(x, y));
        if (lot.exitedCount > 0) break outer;
      }
    }
    expect(lot.exitedCount, 1);
    expect(lot.carsLeft, total - 1);
    for (var i = 0; i < 20; i++) {
      game.update(1 / 60);
      paint();
    }
    // Now bump blocked vehicles on screen until the run is lost.
    final audio = game.audio as SilentAudio;
    while (!lot.isOver) {
      final blocked = lot.parked.firstWhere((v) => !lot.canExit(v.id));
      final c = game.vehicleRect(blocked).center;
      expect(game.vehicleAtPoint(c), same(blocked));
      final before = lot.strikes;
      game.onPointerDown(Vector2(c.dx, c.dy));
      expect(lot.strikes, before + 1);
      for (var i = 0; i < 6; i++) {
        game.update(1 / 60);
        paint();
      }
    }
    expect(audio.played, contains(Sfx.thud));
    expect(audio.played, contains(Sfx.lose));
    expect(lot.lost, isTrue);
    for (var i = 0; i < 90; i++) {
      game.update(1 / 60);
    }
    paint();
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isFalse);
    expect(save.data['level'], isNull);
  });
}
