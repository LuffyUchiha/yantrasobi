import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/quad_pong/pong_world.dart';
import 'package:yantrasobi/cartridges/quad_pong/quad_pong.dart';

void main() {
  void stepN(PongWorld w, int n) {
    for (var i = 0; i < n && !w.isOver; i++) {
      w.step();
    }
  }

  test('manifest is valid and declares 4 local players', () {
    final m = QuadPongCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.maxPlayers, 4);
    expect(m.localMultiplayer, isTrue);
  });

  test('paddles move toward input at limited speed and stay on their edge', () {
    final w = PongWorld(seats: 4, seed: 1);
    w.setInput(0, const PongInput(1));
    w.step();
    expect(w.paddles[0].pos, closeTo(0.5 + PongWorld.paddleSpeed * PongWorld.dt, 1e-9));
    stepN(w, 500);
    expect(w.paddles[0].pos, lessThanOrEqualTo(1 - PongWorld.paddleLen / PongWorld.size / 2 + 1e-9));
  });

  test('a paddle under the ball returns it and grows the rally', () {
    final w = PongWorld(seats: 4, seed: 1);
    w.paddles[0].pos = 0.5;
    w.paddles[0].target = 0.5;
    w.debugBall(50, 90, 0, 60);
    stepN(w, 60);
    expect(w.paddles[0].lives, 5);
    expect(w.rally, greaterThanOrEqualTo(1));
    expect(w.ball.vy, lessThan(0));
  });

  test('a miss costs a life and re-serves', () {
    final w = PongWorld(seats: 4, seed: 1);
    w.paddles[0].pos = 0.15;
    w.paddles[0].target = 0.15;
    w.debugBall(85, 90, 0, 60);
    stepN(w, 60);
    expect(w.paddles[0].lives, 4);
    expect(w.lastScoredAgainst, 0);
  });

  test('inactive seats act as walls', () {
    final w = PongWorld(seats: 2, seed: 1);
    w.debugBall(5, 50, -60, 0);
    stepN(w, 30);
    expect(w.ball.vx, greaterThan(0));
    expect(w.paddles[2].lives, 5);
  });

  test('last paddle standing wins', () {
    final w = PongWorld(seats: 4, seed: 1);
    for (final p in w.paddles.skip(1)) {
      p.lives = 0;
    }
    expect(w.isOver, isTrue);
    expect(w.winner, 0);
  });

  test('CPU paddles keep rallies going', () {
    final w = PongWorld(seats: 4, seed: 3);
    final ais = [for (var s = 0; s < 4; s++) PongAi(s, skill: 0.9)];
    var maxRally = 0;
    for (var i = 0; i < 120 * 30 && !w.isOver; i++) {
      for (final ai in ais) {
        w.setInput(ai.seat, ai.think(w));
      }
      w.step();
      if (w.rally > maxRally) maxRally = w.rally;
    }
    expect(maxRally, greaterThan(5));
  });

  test('an idle player loses against CPUs', () {
    final w = PongWorld(seats: 4, seed: 5);
    // The idle human leaves the paddle parked near a corner.
    w.setInput(0, const PongInput(0.1));
    final ais = [for (var s = 1; s < 4; s++) PongAi(s, skill: 0.8)];
    for (var i = 0; i < 120 * 600 && !w.isOver; i++) {
      for (final ai in ais) {
        w.setInput(ai.seat, ai.think(w));
      }
      w.step();
    }
    expect(w.paddles[0].out, isTrue);
  });

  test('lockstep: identical input streams give identical state hashes', () {
    final a = PongWorld(seats: 4, seed: 11), b = PongWorld(seats: 4, seed: 11);
    for (var i = 0; i < 4000; i++) {
      final input = PongInput(((i * 37) % 100) / 100);
      for (final w in [a, b]) {
        w.setInput(i % 4, input);
        w.step();
      }
      expect(a.stateHash(), b.stateHash(), reason: 'desync at tick $i');
    }
  });
}
