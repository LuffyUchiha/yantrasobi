import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/brickfall/brick_world.dart';
import 'package:yantrasobi/cartridges/brickfall/brickfall.dart';
import 'package:yantrasobi/cartridges/brickfall/levels.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double dt = 1 / 120;

/// Steps until [done] or [maxSeconds] of game time pass.
void runUntil(BrickWorld w, bool Function() done, {double maxSeconds = 10}) {
  for (var t = 0.0; t < maxSeconds && !done(); t += dt) {
    w.update(dt);
  }
}

/// Bot: keeps the paddle under the predicted landing x, offsetting the
/// contact point in a cycle so the bounce angle varies; launches at once.
void botStep(BrickWorld w) {
  if (w.hasHeldBall) w.launch();
  final cycle = (w.paddleHits * 7) % 5 - 2; // -2..2
  final offset = cycle * 0.3 * w.paddleHalfWidth;
  w.setPaddleTarget(w.predictBallX() - offset);
  if (w.laserActive) w.fire();
  w.update(dt);
}

void runBot(BrickWorld w, {double maxSeconds = 600}) {
  for (var t = 0.0; t < maxSeconds && !w.isOver; t += dt) {
    botStep(w);
  }
}

/// A row of [n] blank rows followed by [row].
List<String> withRow(int n, String row) => [for (var i = 0; i < n; i++) '..........', row];

double brickBottom(int row) => BrickWorld.gridTop + (row + 1) * BrickWorld.brickH;

void main() {
  test('manifest is valid', () {
    expect(BrickfallCartridge.kManifest.validate(), isEmpty);
    expect(BrickfallCartridge.kManifest.id, 'brickfall');
  });

  test('ball reflects off side walls, ceiling and brick faces with the right components', () {
    final w = BrickWorld.custom(['..........', '..........', '....11....']);
    // Side wall: moving left at an angle.
    var b = w.debugPlaceBall(20, 400, -300, -100);
    runUntil(w, () => b.vx > 0, maxSeconds: 1);
    expect(b.vx, greaterThan(0));
    expect(b.vy, lessThan(0), reason: 'vertical direction unchanged by a side wall');
    // Ceiling.
    b = w.debugPlaceBall(20, 30, 0.5, -1);
    runUntil(w, () => b.vy > 0, maxSeconds: 1);
    expect(b.vy, greaterThan(0));
    expect(b.y, greaterThanOrEqualTo(BrickWorld.ballRadius));
    // Brick bottom face: straight up into brick (col 4, row 2).
    final brick = w.brickAt(4, 2)!;
    b = w.debugPlaceBall(brick.cx, 300, 0, -1);
    final vx0 = b.vx;
    runUntil(w, () => b.vy > 0, maxSeconds: 2);
    expect(b.vy, greaterThan(0));
    expect(b.vx, closeTo(vx0, 1e-6));
    expect(b.y - BrickWorld.ballRadius, greaterThanOrEqualTo(brick.bottom - 1e-6));
    expect(brick.alive, isFalse);
    // Brick side face: a ball moving right into the left face of col 5 bounces left.
    final side = w.brickAt(5, 2)!;
    b = w.debugPlaceBall(side.left - 20, side.cy, 1, 0.0001);
    runUntil(w, () => b.vx < 0, maxSeconds: 1);
    expect(b.vx, lessThan(0));
    expect(side.alive, isFalse);
  });

  test('corner hit reflects diagonally (circle vs AABB normal)', () {
    final w = BrickWorld.custom(['..........', '....#.....', '..........', '.........1']);
    final k = w.brickAt(4, 1)!;
    // Aim at the bottom-right corner along the diagonal.
    final b = w.debugPlaceBall(k.right + 40, k.bottom + 40, -1, -1);
    runUntil(w, () => b.vx > 0 || b.vy > 0, maxSeconds: 1);
    expect(b.vx, greaterThan(0));
    expect(b.vy, greaterThan(0));
    expect(k.alive, isTrue, reason: 'steel never breaks');
  });

  test('paddle hit position sets the bounce angle', () {
    double bounceAt(double offset) {
      final w = BrickWorld.custom(['..........', '1.........']);
      w.debugSetPaddle(180);
      final b = w.debugPlaceBall(180 + offset, 500, 0, 1);
      runUntil(w, () => b.vy < 0, maxSeconds: 1);
      expect(w.paddleHits, 1);
      return math.atan2(b.vx, -b.vy);
    }

    final centre = bounceAt(0);
    expect(centre.abs(), lessThan(0.01));
    final right = bounceAt(30);
    final farRight = bounceAt(40);
    final left = bounceAt(-30);
    expect(right, greaterThan(0.6));
    expect(farRight, greaterThan(right));
    expect(farRight, lessThanOrEqualTo(BrickWorld.maxBounceAngle + 1e-9));
    expect(left, closeTo(-right, 1e-6));
    expect(bounceAt(10), inExclusiveRange(0.05, right));
  });

  test('tough bricks take 2-3 hits; steel never breaks', () {
    final w = BrickWorld.custom(['..........', '..........', '....3.....', '..........', '.......#..']);
    final tough = w.brickAt(4, 2)!;
    expect(w.destructibleLeft, 1);
    for (var hit = 1; hit <= 3; hit++) {
      final b = w.debugPlaceBall(tough.cx, 300, 0, -1);
      runUntil(w, () => b.vy > 0, maxSeconds: 2);
      if (hit < 3) {
        expect(tough.alive, isTrue);
        expect(tough.hp, 3 - hit);
      }
    }
    expect(tough.alive, isFalse);
    expect(w.won, isTrue);

    final w2 = BrickWorld.custom(['..........', '..1.......', '.......#..']);
    final st = w2.brickAt(7, 2)!;
    for (var i = 0; i < 5; i++) {
      final b = w2.debugPlaceBall(st.cx, 300, 0, -1);
      runUntil(w2, () => b.vy > 0, maxSeconds: 2);
    }
    expect(st.alive, isTrue);
    expect(w2.destructibleLeft, 1);
    expect(w2.score, 0);
  });

  test('explosive brick clears its neighbours and chains, but not steel', () {
    final w = BrickWorld.custom([
      '..........',
      '.1.13.....',
      '.1*#31....',
      '.11*111...',
      '..........',
      '.........1',
    ]);
    final bomb = w.brickAt(2, 2)!;
    // Drop the ball through the empty cell above the bomb.
    w.debugPlaceBall(bomb.cx, BrickWorld.gridTop + BrickWorld.brickH * 1.5, 0, 1);
    runUntil(w, () => !bomb.alive, maxSeconds: 1);
    expect(bomb.alive, isFalse);
    expect(w.brickAt(3, 2)!.alive, isTrue, reason: 'steel survives the blast');
    for (final (c, r) in const [(1, 1), (3, 1), (1, 2), (1, 3), (2, 3), (3, 3)]) {
      expect(w.brickAt(c, r)!.alive, isFalse, reason: 'neighbour ($c,$r)');
    }
    // The second explosive at (3,3) chains: its neighbours go too, even a 3-hp brick.
    expect(w.brickAt(4, 2)!.alive, isFalse);
    expect(w.brickAt(4, 3)!.alive, isFalse);
    expect(w.brickAt(4, 1)!.alive, isTrue);
    expect(w.brickAt(4, 1)!.hp, 3);
    expect(w.brickAt(5, 2)!.alive, isTrue);
    expect(w.brickAt(5, 3)!.alive, isTrue);
    expect(w.bricksBroken, 9, reason: 'both bombs and seven neighbours');
  });

  test('combo multiplier grows per brick without a paddle touch and resets on paddle', () {
    final w = BrickWorld.custom(['..........', '..........', '1.1.......', '..........', '.........1']);
    var b = w.debugPlaceBall(w.brickAt(0, 2)!.cx, 300, 0, -1);
    runUntil(w, () => w.bricksBroken == 1, maxSeconds: 2);
    expect(w.score, 10);
    b = w.debugPlaceBall(w.brickAt(2, 2)!.cx, 300, 0, -1);
    runUntil(w, () => w.bricksBroken == 2, maxSeconds: 2);
    expect(w.combo, 2);
    expect(w.score, 10 + 20);
    // Paddle touch resets the combo.
    w.debugSetPaddle(180);
    b = w.debugPlaceBall(180, 500, 0, 1);
    runUntil(w, () => b.vy < 0, maxSeconds: 1);
    expect(w.combo, 0);
    expect(w.multiplier, 1);
  });

  test('wide, slow and laser capsules apply when caught, then expire', () {
    final w = BrickWorld.custom(['..........', '..........', '1111111111', '..........', '..........']);
    w.debugSetPaddle(180);
    expect(w.paddleHalfWidth, BrickWorld.paddleHalf);
    w.debugDropCapsule(PowerKind.wide, 180, 480);
    runUntil(w, () => w.capsules.isEmpty, maxSeconds: 2);
    expect(w.powersCaught, 1);
    expect(w.paddleHalfWidth, BrickWorld.widePaddleHalf);

    final normal = w.currentSpeed;
    w.debugDropCapsule(PowerKind.slow, 180, 500);
    runUntil(w, () => w.capsules.isEmpty, maxSeconds: 2);
    expect(w.slowTime, greaterThan(0));
    expect(w.currentSpeed, closeTo(normal * BrickWorld.slowFactor, 1e-9));

    // A capsule that misses the paddle is lost.
    w.debugDropCapsule(PowerKind.laser, 20, 500);
    runUntil(w, () => w.capsules.isEmpty, maxSeconds: 2);
    expect(w.powersCaught, 2);
    expect(w.laserActive, isFalse);
    expect(w.fire(), isFalse);

    w.debugDropCapsule(PowerKind.laser, 180, 500);
    runUntil(w, () => w.capsules.isEmpty, maxSeconds: 2);
    expect(w.laserActive, isTrue);
    final before = w.destructibleLeft;
    expect(w.fire(), isTrue);
    expect(w.fire(), isFalse, reason: 'cooldown');
    expect(w.bolts, hasLength(2));
    runUntil(w, () => w.bolts.isEmpty, maxSeconds: 1);
    expect(w.destructibleLeft, before - 2, reason: 'each bolt breaks one brick');

    runUntil(w, () => false, maxSeconds: 16);
    expect(w.laserActive, isFalse);
    expect(w.fire(), isFalse);
    expect(w.slowTime, 0);
    expect(w.currentSpeed, w.baseSpeed + BrickWorld.speedPerHit * w.speedHits);
    expect(w.paddleHalfWidth, BrickWorld.paddleHalf);
  });

  test('multi-ball makes three balls; extra-life capsule adds a life; capsule bricks drop', () {
    final w = BrickWorld.custom(['..........', '..M.......', '..........', '.........1']);
    w.debugSetPaddle(w.brickAt(2, 1)!.cx);
    final b = w.debugPlaceBall(w.brickAt(2, 1)!.cx, 300, 0, -1);
    runUntil(w, () => w.capsules.isNotEmpty, maxSeconds: 2);
    expect(w.capsules.single.kind, PowerKind.multi);
    expect(w.balls.single, same(b));
    runUntil(w, () => w.capsules.isEmpty, maxSeconds: 6);
    expect(w.balls.length, 3);
    final dirs = w.balls.map((b) => math.atan2(b.vx, b.vy).toStringAsFixed(3)).toSet();
    expect(dirs.length, 3, reason: 'the extra balls fan out');

    final lives = w.lives;
    w.debugDropCapsule(PowerKind.life, w.paddleX, 500);
    runUntil(w, () => w.capsules.isEmpty, maxSeconds: 2);
    expect(w.lives, lives + 1);
  });

  test('losing every ball costs a life; at zero lives the run is lost', () {
    final w = BrickWorld(seed: 3, level: 1);
    expect(w.lives, 3);
    for (var life = 3; life >= 1; life--) {
      expect(w.hasHeldBall, isTrue);
      expect(w.launch(), isTrue);
      // Send the ball down far from the paddle.
      w.debugPlaceBall(20, 520, 0, 1);
      w.setPaddleTarget(340);
      runUntil(w, () => w.lives < life || w.isOver, maxSeconds: 5);
      expect(w.lives, life - 1);
    }
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    expect(w.phase, BrickPhase.lost);
    expect(w.launch(), isFalse);
  });

  test('idle player loses level 1', () {
    final w = BrickWorld(seed: 9, level: 1);
    // Launch every time a ball is served, never move the paddle from the left edge.
    w.setPaddleTarget(0);
    for (var t = 0.0; t < 600 && !w.isOver; t += dt) {
      if (w.hasHeldBall) w.launch();
      w.update(dt);
    }
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
  });

  test('clearing all breakable bricks wins with a life bonus; steel does not count', () {
    final w = BrickWorld.custom(['..........', '#...1.....']);
    final k = w.brickAt(4, 1)!;
    w.debugPlaceBall(k.cx, 300, 0, -1);
    runUntil(w, () => w.isOver, maxSeconds: 2);
    expect(w.won, isTrue);
    expect(w.earnedLifeBonus, 3 * BrickWorld.lifeBonus);
    expect(w.score, 10 + 3 * BrickWorld.lifeBonus);
    final snapshot = w.score;
    w.update(1);
    expect(w.score, snapshot);
  });

  test('no tunnelling through a single brick row at max speed, even with long frames', () {
    // A breakable brick sealed above the steel keeps the level in play.
    final w = BrickWorld.custom(['1.........', ...withRow(5, '##########')]);
    final floor = brickBottom(6);
    for (var i = 0; i < 40; i++) {
      w
        ..lives = 99
        ..speedHits = 100000;
      expect(w.currentSpeed, BrickWorld.maxSpeed);
      final a = -1.2 + i * 0.06;
      final b = w.debugPlaceBall(30 + i * 7.5, 400, math.sin(a), -math.cos(a));
      var bounced = false;
      for (var f = 0; f < 20; f++) {
        w.update(f.isEven ? 0.1 : 1 / 30);
        expect(b.y - BrickWorld.ballRadius, greaterThanOrEqualTo(floor - 1e-6), reason: 'angle $a frame $f');
        if (b.vy > 0) bounced = true;
      }
      expect(bounced, isTrue);
    }
    // Also with a breakable row: the first contact breaks a brick and bounces.
    final w2 = BrickWorld.custom(withRow(6, '1111111111'))..speedHits = 100000;
    final b = w2.debugPlaceBall(180, 400, 0.2, -1);
    for (var f = 0; f < 10 && w2.bricksBroken == 0; f++) {
      w2.update(0.1);
    }
    expect(w2.bricksBroken, 1);
    expect(b.vy, greaterThan(0));
    expect(b.y - BrickWorld.ballRadius, greaterThanOrEqualTo(floor - 1e-6));
  });

  test('authored and generated levels are well formed and every breakable brick is reachable', () {
    expect(kAuthoredLevels.length, greaterThanOrEqualTo(10));
    for (var level = 1; level <= 40; level++) {
      final rows = BrickWorld.layoutForLevel(level);
      expect(rows.length, inInclusiveRange(1, kBrickMaxRows));
      for (final r in rows) {
        expect(r.length, kBrickCols, reason: 'level $level row "$r"');
        expect(RegExp(r'^[.123#*WMSLH]+$').hasMatch(r), isTrue, reason: 'level $level row "$r"');
      }
      // Flood fill through non-steel cells from the open area below the grid.
      final h = rows.length;
      final seen = List.generate(h + 1, (_) => List.filled(kBrickCols, false));
      final queue = <(int, int)>[for (var c = 0; c < kBrickCols; c++) (h, c)];
      for (final (r, c) in queue) {
        seen[r][c] = true;
      }
      while (queue.isNotEmpty) {
        final (r, c) = queue.removeLast();
        for (final (dr, dc) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nr = r + dr, nc = c + dc;
          if (nr < 0 || nr > h || nc < 0 || nc >= kBrickCols || seen[nr][nc]) continue;
          if (nr < h && rows[nr][nc] == '#') continue;
          seen[nr][nc] = true;
          queue.add((nr, nc));
        }
      }
      var breakable = 0;
      for (var r = 0; r < h; r++) {
        for (var c = 0; c < kBrickCols; c++) {
          final ch = rows[r][c];
          if (ch == '.' || ch == '#') continue;
          breakable++;
          expect(seen[r][c], isTrue, reason: 'level $level brick ($c,$r) sealed in');
        }
      }
      expect(breakable, greaterThanOrEqualTo(20), reason: 'level $level');
    }
    // Generated levels are deterministic, distinct and get tougher.
    expect(BrickWorld.generateLayout(15), BrickWorld.generateLayout(15));
    expect(BrickWorld.generateLayout(15), isNot(BrickWorld.generateLayout(16)));
    int toughness(int level) =>
        BrickWorld.layoutForLevel(level)
            .join()
            .split('')
            .fold(0, (s, ch) => s + (ch == '2' ? 2 : (ch == '3' ? 3 : 0)));
    expect(toughness(30), greaterThan(toughness(1)));
    expect(BrickWorld(seed: 1, level: 25).baseSpeed, greaterThan(BrickWorld(seed: 1, level: 1).baseSpeed));
  });

  test('ball speed ramps with brick hits up to the cap', () {
    final w = BrickWorld.custom(['1']);
    final s0 = w.currentSpeed;
    w.speedHits = 10;
    expect(w.currentSpeed, closeTo(s0 + 10 * BrickWorld.speedPerHit, 1e-9));
    w.speedHits = 100000;
    expect(w.currentSpeed, BrickWorld.maxSpeed);
  });

  test('same seed and inputs give identical runs', () {
    String run(int seed) {
      final w = BrickWorld(seed: seed, level: 3);
      for (var i = 0; i < 120 * 40 && !w.isOver; i++) {
        botStep(w);
      }
      final balls = w.balls.map((b) => '${b.x.toStringAsFixed(6)},${b.y.toStringAsFixed(6)}').join(';');
      return '${w.score}|${w.lives}|${w.bricksBroken}|${w.capsules.length}|$balls|${w.paddleX}';
    }

    expect(run(42), run(42));
    expect(run(7), run(7));
  });

  test('a paddle bot that tracks the predicted ball clears level 1', () {
    for (final seed in [1, 2, 3, 4]) {
      final w = BrickWorld(seed: seed, level: 1);
      runBot(w);
      expect(w.won, isTrue, reason: 'seed $seed: ${w.destructibleLeft} left, lives ${w.lives}');
    }
  });

  test('game reads the saved level, finishes once and unlocks the next level on a win', () {
    final save = CartridgeSave()..data['level'] = 2;
    var commits = 0;
    final context = CartridgeContext(
      manifest: BrickfallCartridge.kManifest,
      save: save,
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
      onSaveChanged: () => commits++,
    );
    late BrickfallGame game;
    final session = FlameCartridgeSession<BrickfallGame>(context, (s) => game = BrickfallGame(s, seed: 3));
    session.start();
    game.onGameResize(Vector2(400, 800));
    expect(game.level, 2);
    expect(game.bricks.level, 2);
    for (var t = 0.0; t < 900 && session.state == SessionState.running; t += 1 / 60) {
      final w = game.bricks;
      if (w.hasHeldBall) w.launch();
      w.setPaddleTarget(w.predictBallX() - ((w.paddleHits * 7) % 5 - 2) * 0.3 * w.paddleHalfWidth);
      game.update(1 / 60);
    }
    expect(session.state, SessionState.ended);
    expect(session.result!.won, game.bricks.won);
    expect(session.result!.score, game.bricks.score);
    if (game.bricks.won) {
      expect(save.data['level'], 3);
      expect(commits, 1);
    } else {
      expect(save.data['level'], 2);
      expect(commits, 0);
    }
  });

  test('renderer smoke: drag moves the paddle, release launches, renders without errors', () {
    final context = CartridgeContext(
      manifest: BrickfallCartridge.kManifest,
      save: CartridgeSave(),
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    late BrickfallGame game;
    final session = FlameCartridgeSession<BrickfallGame>(context, (s) => game = BrickfallGame(s, seed: 8));
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    game.onPointerDown(Vector2(200, 700));
    game.onPointerMove(Vector2(60, 700), Vector2(-140, 0));
    for (var i = 0; i < 10; i++) {
      game.update(1 / 60);
    }
    expect(game.bricks.paddleX, lessThan(120));
    expect(game.bricks.hasHeldBall, isTrue);
    game.onPointerUp(Vector2(60, 700));
    expect(game.bricks.hasHeldBall, isFalse);
    game.bricks.applyPower(PowerKind.laser);
    game.bricks.applyPower(PowerKind.wide);
    game.bricks.debugDropCapsule(PowerKind.multi, 100, 200);
    game.onPointerDown(Vector2(80, 700));
    expect(game.bricks.bolts, isNotEmpty);
    for (var i = 0; i < 60; i++) {
      game.update(1 / 60);
    }
    paint();
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
  });
}
