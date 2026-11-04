import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/stack_runner/stack_runner.dart';
import 'package:yantrasobi/cartridges/stack_runner/stack_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

void main() {
  /// A started world on an empty course.
  StackWorld empty({int level = 1, int stack = StackWorld.startStack}) {
    final w = StackWorld(level: level, seed: 5)
      ..debugClearTrack()
      ..debugSetStack(stack)
      ..start();
    return w;
  }

  void runToEnd(StackWorld w) {
    for (var i = 0; i < 60 * 120 && !w.isOver; i++) {
      w.update(1 / 60);
    }
  }

  test('manifest is valid', () {
    expect(StackRunnerCartridge.kManifest.validate(), isEmpty);
    expect(StackRunnerCartridge.kManifest.id, 'stack-runner');
  });

  test('nothing moves until the first touch starts the run', () {
    final w = StackWorld(level: 1, seed: 5);
    w.debugRun(1);
    expect(w.distance, 0);
    w.start();
    w.debugRun(1);
    expect(w.distance, closeTo(w.speed, 0.01));
    expect(w.phase, StackPhase.running);
  });

  test('picking up a block in your lane grows the stack; other lanes are missed', () {
    final w = empty();
    w
      ..debugAdd(TrackItem.block(0, 4))
      ..debugAdd(TrackItem.block(0.4, 5))
      ..debugAdd(TrackItem.block(2, 6))
      ..debugAdd(TrackItem.gem(0, 7));
    w.debugRun(1.5);
    expect(w.stack, StackWorld.startStack + 2);
    expect(w.blocksCollected, 2);
    expect(w.items[2].taken, isFalse);
    expect(w.gems, 1);
  });

  test('a wall of height h strips h blocks and leaves them behind', () {
    final w = empty(stack: 5)..debugAdd(TrackItem.wall(5, -0.5, 1.5, 3));
    w.debugRun(1.5);
    expect(w.phase, StackPhase.running);
    expect(w.stack, 2);
    expect(w.blocksLost, 3);
    expect(w.placed.where((p) => p.layer >= 0), hasLength(3));
  });

  test('a wall taller than the stack is a crash; dodging it is free', () {
    final dodge = empty(stack: 1)..debugAdd(TrackItem.wall(5, 0.5, 2.5, 4));
    dodge.steer(-1);
    dodge.debugRun(1.5);
    expect(dodge.phase, StackPhase.running);
    expect(dodge.stack, 1);

    final crash = empty(stack: 2)..debugAdd(TrackItem.wall(5, -2.5, 2.5, 3));
    crash.debugRun(1.5);
    expect(crash.phase, StackPhase.lost);
    expect(crash.lossCause, LossCause.wall);
    expect(crash.isOver, isTrue);
  });

  test('a gap consumes one block per segment, and falling in loses', () {
    final w = empty(stack: 5);
    final gap = TrackItem.gap(5, 3);
    w.debugAdd(gap);
    w.debugRun(2);
    expect(w.phase, StackPhase.running);
    expect(gap.bridged, 3);
    expect(w.stack, 2);
    expect(w.placed.where((p) => p.layer < 0), hasLength(3));

    final short = empty(stack: 2)..debugAdd(TrackItem.gap(5, 3));
    short.debugRun(2);
    expect(short.phase, StackPhase.lost);
    expect(short.lossCause, LossCause.gap);
  });

  test('finish stairs spend blocks for the multiplier; score = gems x multiplier', () {
    expect(StackWorld.costToReachFor(1, 1), 0);
    expect(StackWorld.costToReachFor(1, 5), 1 + 2 + 3 + 4);
    expect(StackWorld.costToReachFor(1, 10), 45);
    expect(StackWorld.costToReachFor(9, 10), greaterThan(45));

    final w = empty(stack: StackWorld.costToReachFor(1, 5) + 4)..debugSetGems(10);
    runToEnd(w);
    expect(w.phase, StackPhase.won);
    expect(w.multiplier, 5);
    expect(w.stack, 4); // x6 costs 5, only 4 left
    expect(w.score, 50);

    final rich = empty(stack: 60)..debugSetGems(4);
    runToEnd(rich);
    expect(rich.multiplier, StackWorld.maxMultiplier);
    expect(rich.stack, 60 - StackWorld.costToReachFor(1, 10));
    expect(rich.score, 40);

    final broke = empty(stack: 0)..debugSetGems(3);
    runToEnd(broke);
    expect(broke.won, isTrue);
    expect(broke.multiplier, 1);
    expect(broke.score, 3);
  });

  test('steering is relative and clamped to the track', () {
    final w = empty();
    w.steer(0.75);
    expect(w.x, 0.75);
    w.steer(10);
    expect(w.x, StackWorld.maxX);
    w.steer(-100);
    expect(w.x, -StackWorld.maxX);
    w.steer(1);
    expect(w.x, -1);
  });

  test('same seed and level give identical courses and runs', () {
    StackWorld play() {
      final w = StackWorld(level: 4, seed: 77)..start();
      for (var i = 0; i < 60 * 40 && !w.isOver; i++) {
        w.steer(((i ~/ 50).isEven ? 1 : -1) * 0.03);
        w.update(1 / 60);
      }
      return w;
    }

    final a = play();
    final b = play();
    expect(a.items.length, b.items.length);
    for (var i = 0; i < a.items.length; i++) {
      expect(a.items[i].kind, b.items[i].kind);
      expect(a.items[i].z, b.items[i].z);
      expect(a.items[i].x, b.items[i].x);
    }
    expect(a.phase, b.phase);
    expect(a.stack, b.stack);
    expect(a.gems, b.gems);
    expect(a.score, b.score);
    expect(a.distance, b.distance);

    final other = StackWorld(level: 4, seed: 78);
    expect(other.items.map((i) => i.z).toList(), isNot(a.items.map((i) => i.z).toList()));
  });

  test('later levels are longer, faster and demand more blocks', () {
    int hazards(int level) {
      var n = 0;
      for (var s = 1; s <= 8; s++) {
        n += StackWorld(level: level, seed: s).hazardCost;
      }
      return n;
    }

    expect(StackWorld.courseLengthFor(8), greaterThan(StackWorld.courseLengthFor(1)));
    expect(StackWorld.speedFor(8), greaterThan(StackWorld.speedFor(1)));
    expect(hazards(8), greaterThan(hazards(1) * 1.5));
    final l1 = StackWorld(level: 1, seed: 3);
    expect(l1.items.where((i) => i.kind == ItemKind.wall).every((i) => i.height <= 2), isTrue);
    final l9 = StackWorld(level: 9, seed: 3);
    expect(l9.countOf(ItemKind.wall) + l9.countOf(ItemKind.gap), greaterThan(0));
    expect(l9.items.every((i) => i.z < l9.courseLength), isTrue);
    // Sorted by z for the cursor.
    for (var i = 1; i < l9.items.length; i++) {
      expect(l9.items[i].z, greaterThanOrEqualTo(l9.items[i - 1].z));
    }
  });

  test('every generated item sits on the track', () {
    for (var level = 1; level <= 12; level++) {
      final w = StackWorld(level: level, seed: level * 3);
      for (final it in w.items) {
        expect(it.x.abs(), lessThanOrEqualTo(StackWorld.maxX), reason: '$level ${it.kind}');
        if (it.kind == ItemKind.wall) {
          expect(it.x0, greaterThanOrEqualTo(-StackWorld.trackHalfWidth));
          expect(it.x1, lessThanOrEqualTo(StackWorld.trackHalfWidth));
          expect(it.height, inInclusiveRange(1, 4));
        }
      }
    }
  });

  group('game', () {
    late CartridgeSave save;
    late int commits;
    late FlameCartridgeSession<StackRunnerGame> session;

    StackRunnerGame launch({int level = 1}) {
      save = CartridgeSave(data: {'level': level});
      commits = 0;
      final ctx = CartridgeContext(
        manifest: StackRunnerCartridge.kManifest,
        save: save,
        audio: SilentAudio(),
        settings: AsobiSettings(MemoryKeyValueStore()),
        onSaveChanged: () => commits++,
      );
      session = const StackRunnerCartridge().createSession(ctx) as FlameCartridgeSession<StackRunnerGame>;
      session.start();
      return session.game..onGameResize(Vector2(400, 800));
    }

    void play(StackRunnerGame g, {bool render = false}) {
      g.onPointerDown(Vector2(200, 600));
      for (var i = 0; i < 60 * 80 && session.state != SessionState.ended; i++) {
        g.onPointerMove(Vector2(200, 600), Vector2(i % 120 < 60 ? 2 : -2, 0));
        g.update(1 / 60);
        if (render && i % 20 == 0) {
          final rec = PictureRecorder();
          g.render(Canvas(rec));
          rec.endRecording().dispose();
        }
      }
      // Extra frames after the end must not report again or throw.
      g.update(1 / 60);
    }

    test('renders a generated course and ends the run', () {
      final g = launch(level: 3);
      expect(g.level, 3);
      g.rules.debugSetStack(30);
      play(g, render: true);
      expect(session.state, SessionState.ended);
      expect(session.result, isNotNull);
      expect(session.result!.details['Level'], '3');
    });

    test('a win reports gems x multiplier and unlocks the next level', () {
      final g = launch(level: 2);
      g.rules
        ..debugClearTrack()
        ..debugSetStack(StackWorld.costToReachFor(2, 4))
        ..debugSetGems(7);
      play(g);
      final r = session.result!;
      expect(r.won, isTrue);
      expect(r.score, 7 * 4);
      expect(save.intData('level'), 3);
      expect(commits, 1);
    });

    test('a loss keeps the level and does not save', () {
      final g = launch(level: 2);
      g.rules
        ..debugClearTrack()
        ..debugSetStack(1)
        ..debugAdd(TrackItem.wall(6, -2.5, 2.5, 3));
      play(g);
      final r = session.result!;
      expect(r.won, isFalse);
      expect(save.intData('level'), 2);
      expect(commits, 0);
    });
  });
}
