import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/serpent_loop/serpent_loop.dart';
import 'package:yantrasobi/cartridges/serpent_loop/serpent_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double dt = 1 / 60;

int cell(int x, int y) => SerpentWorld.cellOf(x, y);

/// A vertical snake with its head at (x, y), body trailing downward.
List<int> column(int x, int y, int length) => [for (var i = 0; i < length; i++) cell(x, y + i)];

/// Flood-fills free cells from [start], treating the snake (minus its tail)
/// and obstacles as walls.
int area(SerpentWorld w, int start) {
  final blocked = List<bool>.filled(SerpentWorld.cols * SerpentWorld.rows, false);
  for (var i = 0; i < w.body.length - 1; i++) {
    blocked[w.body[i]] = true;
  }
  for (final c in w.obstacleCells) {
    blocked[c] = true;
  }
  if (blocked[start]) return 0;
  final seen = List<bool>.filled(blocked.length, false)..[start] = true;
  final stack = [start];
  var n = 0;
  while (stack.isNotEmpty) {
    final c = stack.removeLast();
    n++;
    for (final d in SerpentDir.values) {
      final m = w.neighbor(c, d);
      if (m < 0 || blocked[m] || seen[m]) continue;
      seen[m] = true;
      stack.add(m);
    }
  }
  return n;
}

/// BFS bot: the first step of a shortest time-aware path to the nearest
/// apple / golden / phase pickup, falling back to the roomiest safe move.
SerpentDir botDir(SerpentWorld w) {
  const total = SerpentWorld.cols * SerpentWorld.rows;
  final n = w.body.length;
  // A body cell at index i is vacated after (n - i + growth) ticks.
  final freeAt = List<int>.filled(total, 0);
  for (var i = 0; i < n; i++) {
    freeAt[w.body[i]] = n - i + w.pendingGrowth;
  }
  bool safeAt(int c, int t) => c >= 0 && !w.isObstacle(c) && (w.phasing || freeAt[c] <= t);

  final dist = List<int>.filled(total, -1);
  final first = List<SerpentDir?>.filled(total, null);
  final queue = <int>[w.head];
  dist[w.head] = 0;
  SerpentDir? toFood;
  for (var qi = 0; qi < queue.length && toFood == null; qi++) {
    final c = queue[qi];
    for (final d in SerpentDir.values) {
      if (c == w.head && d == w.dir.opposite) continue;
      final m = w.neighbor(c, d);
      if (m < 0 || dist[m] >= 0 || !safeAt(m, dist[c] + 1)) continue;
      dist[m] = dist[c] + 1;
      first[m] = c == w.head ? d : first[c];
      final f = w.foodAt(m);
      if (f != null && f.kind != FoodKind.berry) {
        toFood = first[m];
        break;
      }
      queue.add(m);
    }
  }
  if (toFood != null && area(w, w.neighbor(w.head, toFood)) >= n + 2) return toFood;
  // Fallback: the safe move with the most room.
  var best = w.dir;
  var bestArea = -1;
  for (final d in SerpentDir.values) {
    if (d == w.dir.opposite) continue;
    final m = w.neighbor(w.head, d);
    if (!safeAt(m, 1)) continue;
    final a = area(w, m);
    if (a > bestArea) {
      bestArea = a;
      best = d;
    }
  }
  return best;
}

/// Runs [w] for up to [seconds], letting the bot steer once per tick.
/// [each] is called after every frame.
void runBot(SerpentWorld w, double seconds, {void Function(SerpentWorld w)? each}) {
  var lastTick = -1;
  for (var t = 0.0; t < seconds && !w.isOver; t += dt) {
    if (w.ticks != lastTick) {
      lastTick = w.ticks;
      final d = botDir(w);
      if (d != w.dir) w.turn(d);
    }
    w.update(dt);
    each?.call(w);
  }
}

CartridgeContext makeContext({CartridgeSave? save, void Function()? onSave}) => CartridgeContext(
  manifest: SerpentLoopCartridge.kManifest,
  save: save ?? CartridgeSave(),
  audio: SilentAudio(),
  settings: AsobiSettings(MemoryKeyValueStore()),
  onSaveChanged: onSave,
);

void main() {
  test('manifest is valid', () {
    const m = SerpentLoopCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'serpent-loop');
    expect(m.version, '1.0.0');
  });

  test('the snake advances exactly one cell per tick interval', () {
    final w = SerpentWorld(spawnFood: false);
    expect(w.length, SerpentWorld.startLength);
    final start = w.head;
    final interval = w.tickInterval;
    for (var t = 0.0; t < interval * 0.6; t += dt) {
      w.update(dt);
    }
    expect(w.head, start);
    for (var t = 0.0; t < interval * 0.6; t += dt) {
      w.update(dt);
    }
    expect(w.ticks, 1);
    expect(w.head, w.neighbor(start, SerpentDir.up));
    expect(w.length, SerpentWorld.startLength);
    expect(w.prevTail, cell(10, SerpentWorld.startRow + 2));
    expect(w.alpha, inInclusiveRange(0.0, 1.0));
  });

  test('turn queue holds two turns, rejects reversals and repeats, applies one per tick', () {
    final w = SerpentWorld(spawnFood: false);
    expect(w.turn(SerpentDir.down), isFalse, reason: 'reversal');
    expect(w.turn(SerpentDir.up), isFalse, reason: 'already heading up');
    expect(w.turn(SerpentDir.left), isTrue);
    expect(w.turn(SerpentDir.right), isFalse, reason: 'reverses the queued left');
    expect(w.turn(SerpentDir.down), isTrue, reason: 'left then down is a quick U-turn');
    expect(w.turn(SerpentDir.right), isFalse, reason: 'queue is full');
    expect(w.queuedTurns, [SerpentDir.left, SerpentDir.down]);
    final h = w.head;
    w.tick();
    expect(w.dir, SerpentDir.left);
    expect(w.head, cell(SerpentWorld.cellX(h) - 1, SerpentWorld.cellY(h)));
    w.tick();
    expect(w.dir, SerpentDir.down);
    expect(w.head, cell(SerpentWorld.cellX(h) - 1, SerpentWorld.cellY(h) + 1));
    expect(w.isOver, isFalse);
    expect(w.queuedTurns, isEmpty);
  });

  test('each food changes length and score as specified', () {
    final w = SerpentWorld(spawnFood: false, mode: SerpentMode.wrap);
    w.debugSetSnake(column(10, 20, 6), SerpentDir.up);
    w.debugPlaceFood(FoodKind.apple, 10, 19);
    w.tick();
    expect(w.score, SerpentWorld.applePoints);
    expect(w.apples, 1);
    w.tick();
    expect(w.length, 7);

    w.debugPlaceFood(FoodKind.golden, 10, 17);
    w.tick();
    expect(w.score, SerpentWorld.applePoints + SerpentWorld.goldenPoints);
    for (var i = 0; i < 4; i++) {
      w.tick();
    }
    expect(w.length, 10);

    w.debugPlaceFood(FoodKind.berry, 10, 12);
    w.tick();
    expect(w.length, 8);
    expect(w.score, 10 + 50 + 5);

    w.debugPlaceFood(FoodKind.phase, 10, 11);
    w.tick();
    expect(w.phasing, isTrue);
    expect(w.phaseTimer, SerpentWorld.phaseDuration);
    expect(w.score, 10 + 50 + 5 + 15);

    // A berry never shrinks below the minimum length.
    final s = SerpentWorld(spawnFood: false);
    s.debugPlaceFood(FoodKind.berry, 10, SerpentWorld.startRow - 1);
    s.tick();
    expect(s.length, SerpentWorld.minLength);
  });

  test('golden fruit despawns after 6 seconds', () {
    final w = SerpentWorld(spawnFood: false, mode: SerpentMode.wrap);
    w.debugPlaceFood(FoodKind.golden, 2, 2);
    var expired = false;
    for (var t = 0.0; t < SerpentWorld.goldenLife - 0.1; t += dt) {
      w.update(dt);
    }
    expect(w.foodOf(FoodKind.golden), isNotNull);
    for (var i = 0; i < 12; i++) {
      w.update(dt);
      expired |= w.events.any((e) => e.kind == SerpentEventKind.expired && e.food == FoodKind.golden);
    }
    expect(w.foodOf(FoodKind.golden), isNull);
    expect(expired, isTrue);
    expect(w.isOver, isFalse);
  });

  test('phase lets the snake pass through itself for 5 seconds', () {
    // A long snake making a tight loop would bite itself.
    List<int> loopSnake() => [
      cell(10, 10), cell(11, 10), cell(12, 10), // head heading left
      cell(12, 11), cell(12, 12), cell(11, 12), cell(10, 12), cell(9, 12), cell(8, 12),
    ];
    void uTurnDown(SerpentWorld w) {
      w.turn(SerpentDir.down);
      w.tick();
      w.tick(); // (10,10)->(10,11)->(10,12) which is body
    }

    final normal = SerpentWorld(spawnFood: false, mode: SerpentMode.wrap)
      ..debugSetSnake(loopSnake(), SerpentDir.left);
    uTurnDown(normal);
    expect(normal.dead, isTrue);
    expect(normal.cause, DeathCause.self);

    final ghost = SerpentWorld(spawnFood: false, mode: SerpentMode.wrap)
      ..debugSetSnake(loopSnake(), SerpentDir.left);
    ghost.debugPlaceFood(FoodKind.phase, 9, 10);
    ghost.tick(); // eats the orb at (9,10)
    expect(ghost.phasing, isTrue);
    ghost.debugSetSnake(loopSnake(), SerpentDir.left);
    ghost.phaseTimer = SerpentWorld.phaseDuration;
    uTurnDown(ghost);
    expect(ghost.dead, isFalse);
    expect(ghost.occupancy(cell(10, 12)), 2);
    // Phase wears off after its duration.
    var ended = false;
    for (var t = 0.0; t < SerpentWorld.phaseDuration + 0.1; t += dt) {
      ghost.update(dt);
      ended |= ghost.events.any((e) => e.kind == SerpentEventKind.phaseEnded);
    }
    expect(ended, isTrue);
    expect(ghost.phasing, isFalse);
    expect(ghost.dead, isFalse);
  });

  test('Classic walls kill; Wrap edges wrap around', () {
    final classic = SerpentWorld(spawnFood: false);
    classic.debugSetSnake(column(5, 0, 3), SerpentDir.up);
    classic.tick();
    expect(classic.dead, isTrue);
    expect(classic.cause, DeathCause.wall);
    expect(classic.won, isFalse);

    final wrap = SerpentWorld(spawnFood: false, mode: SerpentMode.wrap);
    wrap.debugSetSnake(column(5, 0, 3), SerpentDir.up);
    wrap.tick();
    expect(wrap.isOver, isFalse);
    expect(wrap.head, cell(5, SerpentWorld.rows - 1));
    wrap.debugSetSnake([cell(0, 4), cell(1, 4), cell(2, 4)], SerpentDir.left);
    wrap.tick();
    expect(wrap.head, cell(SerpentWorld.cols - 1, 4));
    expect(wrap.won, isNull);

    // Idle classic player runs into the top wall.
    final idle = SerpentWorld(seed: 3);
    idle.debugClearFood();
    for (var i = 0; i < 60 * 10 && !idle.isOver; i++) {
      idle.update(dt);
    }
    expect(idle.dead, isTrue);
    expect(idle.cause, DeathCause.wall);
  });

  test('self and obstacle collisions kill, but chasing your own tail is allowed', () {
    // A 2x2 square: the head may step into the cell the tail is leaving.
    final w = SerpentWorld(spawnFood: false);
    w.debugSetSnake([cell(5, 5), cell(6, 5), cell(6, 6), cell(5, 6)], SerpentDir.left);
    w.turn(SerpentDir.down);
    w.tick();
    expect(w.isOver, isFalse);
    expect(w.head, cell(5, 6));

    // Same move while growing bites the tail.
    final g = SerpentWorld(spawnFood: false);
    g.debugSetSnake([cell(5, 5), cell(6, 5), cell(6, 6), cell(5, 6)], SerpentDir.left);
    g.pendingGrowth = 1;
    g.turn(SerpentDir.down);
    g.tick();
    expect(g.dead, isTrue);
    expect(g.cause, DeathCause.self);

    final o = SerpentWorld(spawnFood: false);
    o.debugAddObstacle(10, SerpentWorld.startRow - 1);
    o.tick();
    expect(o.dead, isTrue);
    expect(o.cause, DeathCause.obstacle);
  });

  test('reaching the goal length clears a Classic level with a bonus', () {
    final w = SerpentWorld(spawnFood: false, level: 2);
    final goal = SerpentWorld.goalForLevel(2);
    w.debugSetSnake(column(10, 5, goal - 1), SerpentDir.up);
    w.debugPlaceFood(FoodKind.apple, 10, 4);
    w.tick();
    expect(w.isOver, isFalse);
    w.tick();
    expect(w.length, goal);
    expect(w.cleared, isTrue);
    expect(w.won, isTrue);
    expect(w.score, SerpentWorld.applePoints + SerpentWorld.clearBonusFor(2));
    expect(w.events.any((e) => e.kind == SerpentEventKind.cleared), isTrue);
    // Wrap has no goal.
    final wrap = SerpentWorld(mode: SerpentMode.wrap);
    expect(wrap.goal, 0);
  });

  test('tick rate speeds up with length and is capped', () {
    final w = SerpentWorld(spawnFood: false, mode: SerpentMode.wrap);
    final base = w.tickInterval;
    expect(base, SerpentWorld.baseIntervalFor(SerpentMode.wrap, 1));
    w.debugSetSnake(column(3, 2, 10), SerpentDir.up);
    expect(w.tickInterval, lessThan(base));
    w.debugSetSnake(column(3, 0, 30), SerpentDir.up);
    final longer = w.tickInterval;
    w.debugSetSnake([
      for (var y = 0; y < 32; y++) cell(3, y),
      for (var y = 31; y >= 0; y--) cell(4, y),
    ], SerpentDir.up);
    expect(w.tickInterval, SerpentWorld.minInterval);
    expect(longer, greaterThanOrEqualTo(SerpentWorld.minInterval));
    expect(
      SerpentWorld.baseIntervalFor(SerpentMode.classic, 5),
      lessThan(SerpentWorld.baseIntervalFor(SerpentMode.classic, 1)),
    );
  });

  test('food spawns are deterministic per seed and never land on the snake or rocks', () {
    String play(int seed, SerpentMode mode, int level) {
      final w = SerpentWorld(seed: seed, mode: mode, level: level);
      runBot(
        w,
        40,
        each: (w) {
          for (final f in w.foods) {
            expect(w.body.contains(f.cell), isFalse, reason: 'food on snake');
            expect(w.isObstacle(f.cell), isFalse, reason: 'food on rock');
          }
        },
      );
      return '${w.spawnLog.join(',')}|${w.score}|${w.ticks}|${w.length}';
    }

    expect(play(7, SerpentMode.classic, 4), play(7, SerpentMode.classic, 4));
    expect(play(7, SerpentMode.wrap, 1), play(7, SerpentMode.wrap, 1));
    expect(play(7, SerpentMode.wrap, 1), isNot(play(8, SerpentMode.wrap, 1)));
    // Specials do turn up over a longer run.
    final w = SerpentWorld(seed: 2, mode: SerpentMode.wrap);
    runBot(w, 120);
    expect(w.spawnLog.where((s) => !s.startsWith('apple')), isNotEmpty);
  });

  test('obstacle layouts: none early, fixed per level, connected and clear of the start lane', () {
    expect(SerpentWorld.obstacleLayout(1), isEmpty);
    expect(SerpentWorld.obstacleLayout(2), isEmpty);
    for (var level = 3; level <= 12; level++) {
      final a = SerpentWorld.obstacleLayout(level);
      expect(a, isNotEmpty);
      expect(SerpentWorld.obstacleLayout(level), a);
      final w = SerpentWorld(level: level, spawnFood: false);
      for (final c in w.body) {
        expect(w.isObstacle(c), isFalse);
      }
      for (var y = SerpentWorld.startRow - 8; y < SerpentWorld.startRow; y++) {
        expect(w.isObstacle(cell(10, y)), isFalse, reason: 'level $level lane row $y');
      }
      final free = SerpentWorld.cols * SerpentWorld.rows - a.length;
      // area() excludes the snake except its tail.
      expect(area(w, w.neighbor(w.head, SerpentDir.up)), free - (w.length - 1));
    }
    // Wrap mode never has rocks.
    expect(SerpentWorld(mode: SerpentMode.wrap, level: 8).obstacleCells, isEmpty);
  });

  test('BFS bot clears Classic level 1 and a rocky level; survives in Wrap', () {
    var cleared = 0;
    for (var seed = 1; seed <= 8; seed++) {
      final w = SerpentWorld(seed: seed);
      runBot(w, 120);
      if (w.won == true) cleared++;
    }
    expect(cleared, greaterThanOrEqualTo(7));

    var rocky = 0;
    for (var seed = 1; seed <= 4; seed++) {
      final w = SerpentWorld(seed: seed, level: 4);
      runBot(w, 180);
      if (w.won == true) rocky++;
    }
    expect(rocky, greaterThanOrEqualTo(3));

    final wrap = SerpentWorld(seed: 11, mode: SerpentMode.wrap);
    runBot(wrap, 60);
    expect(wrap.isOver, isFalse);
    expect(wrap.length, greaterThan(15));
  });

  test('game: start card toggles mode, swipe starts, win saves the next level once', () {
    final save = CartridgeSave()..data['level'] = 2;
    var commits = 0;
    late SerpentLoopGame game;
    final session = FlameCartridgeSession<SerpentLoopGame>(
      makeContext(save: save, onSave: () => commits++),
      (s) => game = SerpentLoopGame(s, seed: 5),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    expect(game.level, 2);
    expect(game.mode, SerpentMode.classic);
    expect(game.started, isFalse);

    // Tap WRAP then CLASSIC on the start card.
    final wrapBtn = game.modeButtonRect(1).center;
    game.onPointerDown(Vector2(wrapBtn.dx, wrapBtn.dy));
    game.onPointerUp(Vector2(wrapBtn.dx, wrapBtn.dy));
    expect(game.mode, SerpentMode.wrap);
    expect(game.serpent.mode, SerpentMode.wrap);
    expect(save.data['mode'], 'wrap');
    final classicBtn = game.modeButtonRect(0).center;
    game.onPointerDown(Vector2(classicBtn.dx, classicBtn.dy));
    game.onPointerUp(Vector2(classicBtn.dx, classicBtn.dy));
    expect(game.mode, SerpentMode.classic);

    // Nothing moves before the start.
    final head = game.serpent.head;
    for (var i = 0; i < 60; i++) {
      game.update(dt);
    }
    expect(game.serpent.head, head);

    // A swipe left starts the run and queues the turn.
    game.onPointerDown(Vector2(200, 500));
    game.onPointerMove(Vector2(170, 502), Vector2(-30, 2));
    game.onPointerUp(Vector2(165, 502));
    expect(game.started, isTrue);
    expect(game.serpent.queuedTurns, [SerpentDir.left]);

    final w = game.serpent;
    w.debugClearFood();
    w.debugSetSnake(column(10, 10, w.goal - 1), SerpentDir.up);
    w.debugPlaceFood(FoodKind.apple, 10, 9);
    for (var i = 0; i < 180 && session.state == SessionState.running; i++) {
      game.update(dt);
    }
    expect(w.cleared, isTrue);
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isTrue);
    expect(session.result!.score, w.score);
    expect(save.data['level'], 3);
    expect(save.data['best_classic'], w.score);
    expect(commits, 1);
    for (var i = 0; i < 30; i++) {
      game.update(dt);
    }
    expect(commits, 1);
  });

  test('renderer smoke: draws every food, phase and wrap edges; Wrap run ends with won == null', () {
    final save = CartridgeSave()..data['mode'] = 'wrap';
    late SerpentLoopGame game;
    final session = FlameCartridgeSession<SerpentLoopGame>(
      makeContext(save: save),
      (s) => game = SerpentLoopGame(s, seed: 9),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    expect(game.mode, SerpentMode.wrap);
    paint();
    final play = game.playButtonRect.center;
    game.onPointerDown(Vector2(play.dx, play.dy));
    game.onPointerUp(Vector2(play.dx, play.dy));
    expect(game.started, isTrue);

    final w = game.serpent;
    // Head near the top edge so it wraps while we render.
    w.debugSetSnake(column(4, 0, 8), SerpentDir.up);
    w.debugPlaceFood(FoodKind.golden, 12, 5);
    w.debugPlaceFood(FoodKind.berry, 14, 8);
    w.debugPlaceFood(FoodKind.phase, 16, 12);
    w.phaseTimer = 2;
    for (var i = 0; i < 40; i++) {
      game.update(dt);
      if (i % 5 == 0) paint();
    }
    expect(w.head, isNot(cell(4, 0)));
    // An L-shaped drag queues two turns.
    game.onPointerDown(Vector2(200, 500));
    game.onPointerMove(Vector2(230, 500), Vector2(30, 0));
    game.onPointerMove(Vector2(232, 470), Vector2(2, -30));
    game.onPointerUp(Vector2(232, 470));
    expect(w.queuedTurns.length, 2);
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);

    // Force a self-bite.
    w.phaseTimer = 0;
    w.debugSetSnake([
      cell(5, 5),
      cell(6, 5),
      cell(6, 6),
      cell(5, 6),
      cell(4, 6),
      cell(4, 5),
      cell(4, 4),
    ], SerpentDir.left);
    for (var i = 0; i < 120 && session.state == SessionState.running; i++) {
      game.update(dt);
      if (i % 20 == 0) paint();
    }
    expect(w.dead, isTrue);
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isNull);
    expect(session.result!.score, w.score);
    paint();

    session.restart();
    expect(identical(game.serpent, w), isFalse);
    expect(game.serpent.ticks, 0);
  });
}
