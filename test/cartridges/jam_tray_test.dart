import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/jam_tray/jam_tray.dart';
import 'package:yantrasobi/cartridges/jam_tray/jam_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

/// Builds a flat (single-layer, non-overlapping) board from a list of kinds.
JamWorld flat(List<int> kinds) => JamWorld.custom([
  for (var i = 0; i < kinds.length; i++) JamTile(i, (i % 7) * 2, (i ~/ 7) * 2, 0, kinds[i]),
]);

/// Greedy player: a free tile whose kind already has 2 in the tray, else 1,
/// else the first free tile.
bool greedy(JamWorld w) {
  while (!w.isOver) {
    final free = w.freeTiles();
    JamTile? pick;
    for (final need in [2, 1]) {
      for (final t in free) {
        if (w.trayCountOf(t.kind) == need) {
          pick = t;
          break;
        }
      }
      if (pick != null) break;
    }
    pick ??= free.first;
    w.tap(pick.id);
  }
  return w.won;
}

String snapshot(JamWorld w) => w.tiles.map((t) => '${t.gx},${t.gy},${t.layer},${t.kind}').join(';');

void main() {
  test('manifest is valid', () {
    expect(JamTrayCartridge.kManifest.validate(), isEmpty);
    expect(JamTrayCartridge.kManifest.id, 'jam-tray');
  });

  test('every kind count on a generated board is a multiple of 3', () {
    for (var level = 1; level <= 14; level++) {
      for (var seed = 0; seed < 6; seed++) {
        final w = JamWorld(seed: seed, level: level);
        expect(w.tiles.length, JamWorld.tilesForLevel(level));
        final counts = w.boardKindCounts();
        expect(counts.keys.every((k) => k >= 0 && k < w.kindCount), isTrue);
        for (final c in counts.values) {
          expect(c % 3, 0, reason: 'level $level seed $seed');
        }
      }
    }
  });

  test('board geometry: no overlap within a layer, upper tiles rest on the layer below', () {
    final w = JamWorld(seed: 5, level: 6);
    for (final a in w.tiles) {
      expect(a.x + 1 <= JamWorld.boardWidth && a.y + 1 <= JamWorld.boardHeight, isTrue);
      for (final b in w.tiles) {
        if (a.id != b.id && a.layer == b.layer) expect(a.overlaps(b), isFalse);
      }
      if (a.layer > 0) {
        expect(w.tiles.any((b) => b.layer == a.layer - 1 && b.overlaps(a)), isTrue);
      }
    }
  });

  test('a tile covered by a higher layer is blocked and cannot be tapped', () {
    final w = JamWorld.custom([
      JamTile(0, 0, 0, 0, 0), // bottom
      JamTile(1, 1, 1, 1, 1), // overlaps the bottom tile's lower-right quarter
      JamTile(2, 6, 0, 0, 0),
      JamTile(3, 8, 0, 0, 0),
      JamTile(4, 6, 6, 0, 1),
      JamTile(5, 8, 6, 0, 1),
    ]);
    expect(w.isFree(w.tileById(0)), isFalse);
    expect(w.isFree(w.tileById(1)), isTrue);
    final r = w.tap(0);
    expect(r.outcome, JamOutcome.blocked);
    expect(w.tileById(0).onBoard, isTrue);
    expect(w.tray, isEmpty);
    // tapAt picks the topmost tile under the point (the overlap area).
    expect(w.tileAt(1.25, 1.25)!.id, 1);
    expect(w.tileAt(0.25, 0.25)!.id, 0);
    expect(w.tapAt(1.25, 1.25).outcome, JamOutcome.moved);
    expect(w.isFree(w.tileById(0)), isTrue);
    expect(w.tapAt(0.25, 0.25).outcome, JamOutcome.moved);
    expect(w.tapAt(6.9, 7.9).outcome, JamOutcome.ignored);
  });

  test('tray stays grouped by kind; three alike clear for 30 points', () {
    final w = flat([0, 1, 0, 0, 1, 1, 2, 2, 2]);
    w.tap(0);
    w.tap(1);
    w.tap(2);
    expect(w.tray.map((t) => t.kind).toList(), [0, 0, 1]);
    final r = w.tap(3);
    expect(r.outcome, JamOutcome.triple);
    expect(r.clearedKind, 0);
    expect(r.clearedSlot, 0);
    expect(w.tray.map((t) => t.kind).toList(), [1]);
    expect(w.score, JamWorld.pointsPerTriple);
    expect(w.triples, 1);
    expect(w.isOver, isFalse);
  });

  test('filling the tray to 7 without a triple loses', () {
    final w = flat([
      for (var k = 0; k < 7; k++) ...[k, k, k],
    ]);
    for (var k = 0; k < 6; k++) {
      expect(w.tap(k * 3).outcome, JamOutcome.moved);
    }
    expect(w.isOver, isFalse);
    expect(w.tap(18).outcome, JamOutcome.lost);
    expect(w.phase, JamPhase.lost);
    expect(w.isOver, isTrue);
    expect(w.tray, hasLength(JamWorld.trayCapacity));
    expect(w.tap(1).outcome, JamOutcome.ignored);
    expect(w.canUndo, isFalse);
  });

  test('clearing the whole board wins with a time bonus', () {
    final w = flat([4, 4, 4, 2, 2, 2]);
    w.update(3);
    w.tap(0);
    w.tap(3);
    w.tap(1);
    w.tap(4);
    expect(w.tap(2).outcome, JamOutcome.triple);
    expect(w.tap(5).outcome, JamOutcome.won);
    expect(w.won, isTrue);
    expect(w.boardCount, 0);
    expect(w.tray, isEmpty);
    // par = 6 tiles * 2s = 12s, played 3s -> 9 * 5 bonus.
    expect(w.timeBonus, 45);
    expect(w.score, 2 * JamWorld.pointsPerTriple + 45);
    w.update(10);
    expect(w.time, 3); // clock stops once the run is over
  });

  test('undo returns the last tile to its board spot, limited uses', () {
    final w = JamWorld(seed: 11, level: 3);
    final t = w.freeTiles().first;
    final freeBefore = w.freeTiles().length;
    expect(w.canUndo, isFalse);
    w.tap(t.id);
    expect(t.onBoard, isFalse);
    expect(w.undo(), same(t));
    expect(t.onBoard, isTrue);
    expect(w.tray, isEmpty);
    expect(w.freeTiles().length, freeBefore);
    expect(w.undosLeft, JamWorld.startUndos - 1);
    expect(w.undo(), isNull, reason: 'nothing left to undo');

    // A tile that already popped in a triple cannot be undone.
    final f = flat([0, 0, 0, 1, 1, 1]);
    f.tap(0);
    f.tap(1);
    f.tap(2);
    expect(f.canUndo, isFalse);
    f.tap(3);
    f.tap(4);
    expect(f.undo()!.id, 4);
    expect(f.undo()!.id, 3);
    expect(f.tray, isEmpty);
    f.tap(3);
    expect(f.undo()!.id, 3);
    expect(f.undosLeft, 0);
    f.tap(3);
    expect(f.undo(), isNull, reason: 'out of undos');
  });

  test('shuffle reassigns kinds but preserves counts, limited uses', () {
    final w = JamWorld(seed: 4, level: 5);
    w.tap(w.freeTiles().first.id);
    final before = w.boardKindCounts();
    final kindsBefore = w.tiles.where((t) => t.onBoard).map((t) => t.kind).toList();
    expect(w.shuffle(), isTrue);
    expect(w.boardKindCounts(), before);
    final kindsAfter = w.tiles.where((t) => t.onBoard).map((t) => t.kind).toList();
    expect(kindsAfter, isNot(kindsBefore));
    // board + tray per kind is still a multiple of 3.
    final all = <int, int>{...w.boardKindCounts()};
    for (final t in w.tray) {
      all[t.kind] = (all[t.kind] ?? 0) + 1;
    }
    expect(all.values.every((c) => c % 3 == 0), isTrue);
    expect(w.shuffle(), isTrue);
    expect(w.shufflesLeft, 0);
    expect(w.shuffle(), isFalse);
  });

  test('same seed + level gives the same board; different seeds differ', () {
    expect(snapshot(JamWorld(seed: 77, level: 4)), snapshot(JamWorld(seed: 77, level: 4)));
    expect(snapshot(JamWorld(seed: 77, level: 4)), isNot(snapshot(JamWorld(seed: 78, level: 4))));
    expect(JamWorld(seed: 77, level: 4).solution, JamWorld(seed: 77, level: 4).solution);
  });

  test('levels scale up tiles, kinds and layers', () {
    var prevTiles = 0, prevKinds = 0, prevLayers = 0;
    for (var level = 1; level <= 20; level++) {
      final tiles = JamWorld.tilesForLevel(level);
      final kinds = JamWorld.kindsForLevel(level);
      final layers = JamWorld.layersForLevel(level);
      expect(tiles % 3, 0);
      expect(tiles, greaterThanOrEqualTo(prevTiles));
      expect(kinds, greaterThanOrEqualTo(prevKinds));
      expect(layers, greaterThanOrEqualTo(prevLayers));
      expect(layers, inInclusiveRange(2, 3));
      prevTiles = tiles;
      prevKinds = kinds;
      prevLayers = layers;
      final w = JamWorld(seed: level, level: level);
      expect(w.tiles.map((t) => t.layer).reduce((a, b) => a > b ? a : b), layers - 1);
    }
    expect(JamWorld.tilesForLevel(8), greaterThan(JamWorld.tilesForLevel(1)));
    expect(JamWorld.kindsForLevel(8), greaterThan(JamWorld.kindsForLevel(1)));
    expect(JamWorld.layersForLevel(8), greaterThan(JamWorld.layersForLevel(1)));
  });

  test('every generated board is solvable by following its reverse-play order', () {
    for (var level = 1; level <= 12; level++) {
      for (var seed = 0; seed < 5; seed++) {
        final w = JamWorld(seed: seed, level: level);
        var maxTray = 0;
        for (final id in w.solution) {
          w.tap(id);
          if (w.tray.length > maxTray) maxTray = w.tray.length;
        }
        expect(w.won, isTrue, reason: 'level $level seed $seed');
        expect(maxTray, lessThanOrEqualTo(4));
      }
    }
  });

  test('a greedy player wins level 1 for many seeds', () {
    for (var seed = 0; seed < 25; seed++) {
      expect(greedy(JamWorld(seed: seed, level: 1)), isTrue, reason: 'seed $seed');
    }
    // Later levels are genuinely harder for the naive greedy player.
    var wins = 0;
    for (var seed = 0; seed < 25; seed++) {
      if (greedy(JamWorld(seed: seed, level: 10))) wins++;
    }
    expect(wins, lessThan(25));
  });

  test('game reads the saved level, finishes once and unlocks the next level on a win', () {
    final save = CartridgeSave()..data['level'] = 2;
    var commits = 0;
    final context = CartridgeContext(
      manifest: JamTrayCartridge.kManifest,
      save: save,
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
      onSaveChanged: () => commits++,
    );
    late JamTrayGame game;
    final session = FlameCartridgeSession<JamTrayGame>(context, (s) => game = JamTrayGame(s, seed: 3));
    session.start();
    expect(game.level, 2);
    expect(game.jam.level, 2);
    for (final id in game.jam.solution) {
      game.jam.tap(id);
    }
    expect(game.jam.won, isTrue);
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, game.jam.score);
    expect(save.data['level'], 3);
    expect(commits, 1);
  });

  test('renderer smoke: taps on screen move a free tile into the tray and render without errors', () {
    final context = CartridgeContext(
      manifest: JamTrayCartridge.kManifest,
      save: CartridgeSave(),
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    late JamTrayGame game;
    final session = FlameCartridgeSession<JamTrayGame>(context, (s) => game = JamTrayGame(s, seed: 8));
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    // Scan the screen until a tap lands on a free tile.
    outer:
    for (var y = 120.0; y < 640; y += 8) {
      for (var x = 10.0; x < 390; x += 8) {
        game.onPointerDown(Vector2(x, y));
        if (game.jam.tray.isNotEmpty || game.jam.triples > 0) break outer;
      }
    }
    expect(game.jam.moves, greaterThan(0));
    for (var i = 0; i < 30; i++) {
      game.update(1 / 60);
    }
    paint();
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
  });
}
