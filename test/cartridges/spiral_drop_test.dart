import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/spiral_drop/spiral_drop.dart';
import 'package:yantrasobi/cartridges/spiral_drop/spiral_world.dart';

void main() {
  void run(SpiralWorld w, double seconds) {
    for (var t = 0.0; t < seconds && !w.isOver; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  /// Advances until the ball has crossed (or bounced on) the next ring.
  void fallTo(SpiralWorld w, SegKind kind) {
    final ring = w.nextRing!;
    final s = SpiralWorld.findSegment(ring, kind);
    expect(s, isNot(-1), reason: 'ring ${ring.index} has no $kind');
    w.debugAlignToSegment(s);
  }

  test('manifest is valid', () => expect(SpiralDropCartridge.kManifest.validate(), isEmpty));

  test('every ring has at least one gap and the start spot is solid', () {
    for (var level = 1; level <= 8; level++) {
      final w = SpiralWorld(level: level, seed: level);
      expect(w.rings.first.segments[0], SegKind.solid);
      for (final r in w.rings.where((r) => !r.finish)) {
        expect(r.segments, contains(SegKind.gap));
      }
      expect(w.rings.last.finish, isTrue);
    }
  });

  test('ball bounces on a solid segment', () {
    final w = SpiralWorld(seed: 2);
    fallTo(w, SegKind.solid);
    run(w, 1.0);
    expect(w.phase, SpiralPhase.playing);
    expect(w.ringsPassed, 0);
    expect(w.ballY, greaterThan(w.rings.first.y));
  });

  test('ball falls through a gap and scores', () {
    final w = SpiralWorld(seed: 2);
    fallTo(w, SegKind.gap);
    run(w, 0.8);
    expect(w.ringsPassed, greaterThanOrEqualTo(1));
    expect(w.score, greaterThan(0));
  });

  test('landing on a hazard loses', () {
    final w = SpiralWorld(level: 4, seed: 3);
    // Pass the first ring through its gap, then aim at a hazard on the next.
    fallTo(w, SegKind.gap);
    while (w.ringsPassed < 1) {
      w.update(1 / 60);
    }
    final ring = w.nextRing!;
    final hz = SpiralWorld.findSegment(ring, SegKind.hazard);
    expect(hz, isNot(-1));
    w.debugAlignToSegment(hz);
    run(w, 2);
    expect(w.phase, SpiralPhase.lost);
  });

  test('three straight drops make the ball blaze and smash a hazard ring', () {
    final w = SpiralWorld(level: 4, seed: 5);
    while (w.combo < SpiralWorld.blazeCombo && !w.isOver) {
      final before = w.ringsPassed;
      fallTo(w, SegKind.gap);
      while (w.ringsPassed == before && !w.isOver) {
        w.update(1 / 60);
      }
    }
    expect(w.blazing, isTrue);
    final ring = w.nextRing!;
    final target = SpiralWorld.findSegment(ring, SegKind.hazard);
    w.debugAlignToSegment(target == -1 ? SpiralWorld.findSegment(ring, SegKind.solid) : target);
    final passed = w.ringsPassed;
    while (w.ringsPassed == passed && !w.isOver) {
      w.update(1 / 60);
    }
    expect(w.phase, SpiralPhase.playing);
    expect(w.smashes, 1);
    expect(w.combo, 0);
  });

  test('perfect play reaches the finish platform and wins', () {
    final w = SpiralWorld(level: 2, seed: 7);
    var guard = 0;
    while (!w.isOver && guard++ < 20000) {
      final ring = w.nextRing!;
      if (!ring.finish) {
        w.debugAlignToSegment(SpiralWorld.findSegment(ring, SegKind.gap));
      }
      w.update(1 / 60);
    }
    expect(w.phase, SpiralPhase.won);
    expect(w.ringsPassed, w.ringCount);
  });

  test('rotation maps to segments consistently', () {
    final w = SpiralWorld(seed: 1);
    for (var s = 0; s < SpiralWorld.segmentsPerRing; s++) {
      w.debugAlignToSegment(s);
      expect(w.segmentUnderBall(), s);
    }
    w.towerAngle = 0;
    w.rotate(-SpiralWorld.segmentArc * 1.5);
    expect(w.segmentUnderBall(), 1);
  });

  test('higher levels are longer and more hazardous', () {
    int hazards(SpiralWorld w) =>
        w.rings.fold(0, (a, r) => a + r.segments.where((s) => s == SegKind.hazard).length);
    final l1 = SpiralWorld(level: 1, seed: 1), l5 = SpiralWorld(level: 5, seed: 1);
    expect(l5.ringCount, greaterThan(l1.ringCount));
    expect(hazards(l5), greaterThan(hazards(l1)));
  });
}
