import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:yantrasobi/cartridges/edge_dash/dash_world.dart';
import 'package:yantrasobi/cartridges/edge_dash/edge_dash.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

DashWorld arena({int seed = 7, bool hold = true}) {
  final w = DashWorld(width: 400, height: 680, seed: seed);
  w.debugClearSpawnQueue();
  w.debugHoldWave = hold;
  return w;
}

void run(DashWorld w, double seconds, [void Function(DashWorld)? brain]) {
  final steps = (seconds / DashWorld.step).round();
  for (var i = 0; i < steps && !w.isOver; i++) {
    brain?.call(w);
    w.update(DashWorld.step);
  }
}

// ------------------------------------------------------------------ bot

/// Whether standing at (x,y) gets hit within [horizon] seconds.
bool threatened(DashWorld w, double x, double y, double horizon, {List<Foe> ignore = const []}) {
  for (final b in w.bolts) {
    final rx = x - b.pos.x;
    final ry = y - b.pos.y;
    final v2 = b.vel.length2;
    var t = v2 > 0 ? (rx * b.vel.x + ry * b.vel.y) / v2 : 0.0;
    t = t.clamp(0.0, horizon);
    final cx = b.pos.x + b.vel.x * t - x;
    final cy = b.pos.y + b.vel.y * t - y;
    final r = b.radius + DashWorld.heroRadius + 8;
    if (cx * cx + cy * cy < r * r) return true;
  }
  for (final f in w.foes) {
    if (ignore.contains(f)) continue;
    final margin = f.kind == FoeKind.boss ? 34 : 14 + f.speed * horizon;
    final r = f.radius + DashWorld.heroRadius + margin;
    if (f.pos.distanceToSquared(vm.Vector2(x, y)) < r * r) return true;
  }
  return false;
}

bool safePlan(DashWorld w, DashPlan p) {
  if (!p.valid || p.crossesBlast) return false;
  final boss = p.blockedBy?.kind == FoeKind.boss ? p.blockedBy : null;
  if (boss != null && boss.pos.distanceTo(p.to) < boss.radius + DashWorld.heroRadius + 2) return false;
  return !threatened(w, p.to.x, p.to.y, 0.5, ignore: [...p.sliced, ?boss]);
}

/// A bot that only reacts every [think] seconds, like a human thumb.
void Function(DashWorld) makeBot({double think = 0.3}) {
  var wait = 0.0;
  return (w) {
    wait -= DashWorld.step;
    if (wait > 0 || w.cooldown > 0) return;
    final before = w.dashes;
    bot(w);
    if (w.dashes != before) wait = think;
  };
}

/// Greedy dash bot: slice through the best cluster in reach, flank shields,
/// strike the boss weak spot, and dash clear of projectiles and contact.
void bot(DashWorld w) {
  if (w.isOver || w.cooldown > 0) return;
  final hx = w.hero.x;
  final hy = w.hero.y;
  DashPlan? best;
  var bestScore = 0.0;
  for (final f in w.foes) {
    final dx = f.pos.x - hx;
    final dy = f.pos.y - hy;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < 1 || dist - f.radius > w.maxDash) continue;
    final ux = dx / dist;
    final uy = dy / dist;
    for (final off in const [0.0, -0.6, 0.6]) {
      // Aim through the centre or along either flank of the foe.
      final ox = -uy * f.radius * off;
      final oy = ux * f.radius * off;
      final len = math.min(dist + f.radius + 34, w.maxDash);
      final ax = dx + ox;
      final ay = dy + oy;
      final al = math.sqrt(ax * ax + ay * ay);
      final p = w.planDash(ax / al * len, ay / al * len);
      if (!safePlan(w, p)) continue;
      var s = p.sliced.length * 10.0;
      if (p.bossWeakHit) s += 25;
      if (p.blockedBy != null && !p.bossWeakHit) s -= 5;
      s -= p.length * 0.01;
      if (s > bestScore) {
        bestScore = s;
        best = p;
      }
    }
  }
  if (best != null && (best.sliced.isNotEmpty || best.bossWeakHit)) {
    w.dash(best.dx, best.dy);
    return;
  }
  final danger = threatened(w, hx, hy, 0.45);
  // Flank the nearest shieldbearer or circle the boss toward its weak spot.
  Foe? target;
  var nearest = double.infinity;
  for (final f in w.foes) {
    final d = f.pos.distanceTo(w.hero);
    if (d < nearest) {
      nearest = d;
      target = f;
    }
  }
  if (target != null && !danger) {
    vm.Vector2? goal;
    if (target.kind == FoeKind.shieldbearer && nearest < 200) {
      // Aim for a spot well behind the shield's edge.
      final side = vm.Vector2(-target.facing.y, target.facing.x);
      final back = target.facing * 45;
      final a = target.pos + side * 70 - back;
      final b = target.pos - side * 70 - back;
      goal = a.distanceTo(w.hero) < b.distanceTo(w.hero) ? a : b;
    } else if (target.kind == FoeKind.boss) {
      final r = target.radius + 70;
      goal = vm.Vector2(
        target.pos.x + math.cos(target.weakAngle) * r,
        target.pos.y + math.sin(target.weakAngle) * r,
      );
    } else if (nearest > w.maxDash + 20) {
      final u = (target.pos - w.hero)..normalize();
      goal = target.pos - u * 110;
    }
    if (goal != null) {
      final p = w.planDash(goal.x - hx, goal.y - hy);
      if (p.length > 15 && safePlan(w, p) && p.blockedBy == null) {
        w.dash(goal.x - hx, goal.y - hy);
      }
    }
    return;
  }
  if (!danger) return;
  // Escape: the safe landing spot farthest from every foe.
  DashPlan? escape;
  var escapeScore = -double.infinity;
  for (var i = 0; i < 16; i++) {
    final a = i * math.pi / 8;
    for (final len in [70.0, 120.0, w.maxDash]) {
      final p = w.planDash(math.cos(a) * len, math.sin(a) * len);
      if (!safePlan(w, p) || p.blockedBy != null) continue;
      var clear = double.infinity;
      for (final f in w.foes) {
        clear = math.min(clear, f.pos.distanceTo(p.to) - f.radius);
      }
      final centre = (p.to.x - w.width / 2).abs() + (p.to.y - w.height / 2).abs();
      final s = math.min(clear, 200) - centre * 0.1;
      if (s > escapeScore) {
        escapeScore = s;
        escape = p;
      }
    }
  }
  if (escape != null) w.dash(escape.dx, escape.dy);
}

String snapshot(DashWorld w) =>
    '${w.score}|${w.wave}|${w.hearts}|${w.kills}|${w.hero.x.toStringAsFixed(3)},${w.hero.y.toStringAsFixed(3)}|'
    '${w.foes.map((f) => '${f.kind.index}:${f.pos.x.toStringAsFixed(2)},${f.pos.y.toStringAsFixed(2)}').join(';')}';

void main() {
  test('manifest is valid', () {
    expect(EdgeDashCartridge.kManifest.validate(), isEmpty);
    expect(EdgeDashCartridge.kManifest.id, 'edge-dash');
  });

  test('dash moves the hero instantly, clamped to max length and the arena', () {
    final w = arena();
    expect(w.maxDash, closeTo(160, 1e-9));
    final start = w.hero.clone();
    expect(w.dash(500, 0), isTrue);
    expect(w.hero.x - start.x, closeTo(160, 1e-6));
    expect(w.hero.y, closeTo(start.y, 1e-6));
    // A short swipe is used as-is.
    w.update(0.2);
    expect(w.dash(0, -50), isTrue);
    expect(w.hero.y, closeTo(start.y - 50, 1e-6));
    // Toward the wall: stops at the edge, keeping direction.
    w.update(0.2);
    w.hero.setValues(380, 300);
    expect(w.dash(100, 100), isTrue);
    expect(w.hero.x, closeTo(400 - DashWorld.heroRadius, 1e-6));
    expect(w.hero.y, closeTo(308, 1e-6));
    // Too-short swipes are ignored.
    w.update(0.2);
    expect(w.dash(3, 4), isFalse);
  });

  test('dash cooldown is 0.15 s', () {
    final w = arena();
    expect(w.dash(60, 0), isTrue);
    expect(w.dash(-60, 0), isFalse);
    w.update(0.1);
    expect(w.dash(-60, 0), isFalse);
    w.update(0.08);
    expect(w.dash(-60, 0), isTrue);
    expect(w.dashes, 2);
  });

  test('segment-vs-circle slicing kills every foe on the line, and only those', () {
    final w = arena();
    w.hero.setValues(60, 300);
    final a = w.debugSpawn(FoeKind.walker, 100, 300);
    final b = w.debugSpawn(FoeKind.walker, 160, 300 + 13 + DashWorld.bladeHalfWidth - 1); // grazed
    final c = w.debugSpawn(FoeKind.walker, 200, 300 + 13 + DashWorld.bladeHalfWidth + 2); // missed
    final d = w.debugSpawn(FoeKind.walker, 300, 300); // beyond the dash end (220)
    final plan = w.planDash(160, 0);
    expect(plan.sliced, [a, b]);
    expect(w.dash(160, 0), isTrue);
    expect(a.alive || b.alive, isFalse);
    expect(c.alive && d.alive, isTrue);
    expect(w.kills, 2);
    expect(w.bestMultiKill, 2);
    expect(w.events.any((e) => e.kind == DashEventKind.multiKill && e.count == 2), isTrue);
    expect(DashWorld.segmentPointDistance(0, 0, 10, 0, 5, 3), closeTo(3, 1e-9));
    expect(DashWorld.segmentPointDistance(0, 0, 10, 0, 13, 4), closeTo(5, 1e-9));
  });

  test('shieldbearers block head-on dashes but fall to side and rear strikes', () {
    final dir = vm.Vector2(1, 0);
    expect(DashWorld.shieldBlocks(dir, vm.Vector2(-1, 0)), isTrue); // face to face
    expect(DashWorld.shieldBlocks(dir, vm.Vector2(-math.cos(0.9), math.sin(0.9))), isTrue); // ~52 deg
    expect(DashWorld.shieldBlocks(dir, vm.Vector2(-math.cos(1.2), math.sin(1.2))), isFalse); // ~69 deg
    expect(DashWorld.shieldBlocks(dir, vm.Vector2(0, 1)), isFalse); // side
    expect(DashWorld.shieldBlocks(dir, vm.Vector2(1, 0)), isFalse); // rear

    final w = arena();
    w.hero.setValues(100, 300);
    final s = w.debugSpawn(FoeKind.shieldbearer, 200, 300); // faces the hero
    final behind = w.debugSpawn(FoeKind.walker, 240, 300);
    w.dash(160, 0);
    expect(s.alive && behind.alive, isTrue);
    expect(w.hero.x, lessThan(200 - s.radius));
    expect(w.events.any((e) => e.kind == DashEventKind.blocked), isTrue);

    // From the side the same foe is cut down.
    final w2 = arena();
    w2.hero.setValues(200, 200);
    final s2 = w2.debugSpawn(FoeKind.shieldbearer, 200, 300);
    s2.facing.setValues(1, 0); // shield turned away to the right
    w2.dash(0, 160);
    expect(s2.alive, isFalse);
    expect(w2.score, 25);
  });

  test('bomber blast hurts only when dashing through it within 0.3 s', () {
    final w = arena();
    w.hero.setValues(100, 300);
    final bomber = w.debugSpawn(FoeKind.bomber, 160, 300);
    final near = w.debugSpawn(FoeKind.walker, 160, 350); // inside the blast
    w.dash(150, 0); // ends at x=250, through the bomber
    expect(bomber.alive || near.alive, isFalse, reason: 'blast chains into neighbours');
    expect(w.hearts, 3, reason: 'the killing dash itself is safe');
    expect(w.blasts.single.active, isTrue);
    w.update(0.2);
    // Back through the blast at 0.2 s: hurts.
    expect(w.planDash(-150, 0).crossesBlast, isTrue);
    w.dash(-150, 0);
    expect(w.hearts, 2);

    final w2 = arena();
    w2.hero.setValues(100, 300);
    w2.debugSpawn(FoeKind.bomber, 160, 300);
    w2.dash(150, 0);
    w2.update(0.32);
    expect(w2.blasts.every((b) => !b.active), isTrue);
    w2.dash(-150, 0);
    expect(w2.hearts, 3);
  });

  test('archer bolts hit a still hero, but a dash dodges them', () {
    final w = arena();
    w.hero.setValues(200, 400);
    w.debugBolt(200, 250, 0, 120);
    run(w, 1.4);
    expect(w.hearts, 2);
    expect(w.bolts, isEmpty);

    final w2 = arena();
    w2.hero.setValues(200, 400);
    w2.debugBolt(200, 250, 0, 120);
    run(w2, 0.8);
    w2.dash(100, 0);
    run(w2, 2.5);
    expect(w2.hearts, 3);

    // A real archer shoots after its wind-up.
    final w3 = arena();
    w3.hero.setValues(200, 400);
    w3.debugSpawn(FoeKind.archer, 200, 220);
    run(w3, 2.6);
    expect(w3.events.any((e) => e.kind == DashEventKind.shot), isTrue);
  });

  test('hearts: contact costs one, invulnerability prevents chain hits, three losses end the run', () {
    final w = arena();
    w.hero.setValues(200, 300);
    final f = w.debugSpawn(FoeKind.walker, 200, 315);
    w.update(DashWorld.step);
    expect(w.hearts, 2);
    expect(w.invulnerable, greaterThan(0.9));
    // Knocked back; even if it touches again during invulnerability, no loss.
    f.pos.setValues(200, 310);
    w.update(0.5);
    expect(w.hearts, 2);
    w.update(0.6);
    f.pos.setValues(200, 310);
    w.update(DashWorld.step);
    expect(w.hearts, 1);
    w.update(1.1);
    f.pos.setValues(200, 310);
    w.update(DashWorld.step);
    expect(w.hearts, 0);
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
    expect(w.dash(50, 0), isFalse);
  });

  test('combo: multi-kills multiply score and chained dashes within 1 s keep it', () {
    final w = arena();
    w.hero.setValues(60, 300);
    w.debugSpawn(FoeKind.walker, 100, 300);
    w.debugSpawn(FoeKind.walker, 150, 300);
    w.debugSpawn(FoeKind.walker, 200, 300);
    w.dash(160, 0); // 3 kills, combo 1: 30 * 3 * 1
    expect(w.score, 90);
    expect(w.combo, 1);
    w.update(0.5);
    w.dash(0, 150); // misses, but keeps the window open
    expect(w.comboTimer, closeTo(DashWorld.comboWindow, 1e-9));
    w.update(0.5);
    w.debugSpawn(FoeKind.walker, 220, 380);
    w.dash(0, -150); // back up through the walker
    expect(w.combo, 2);
    expect(w.score, 90 + 10 * 1 * 2);
    // Letting the window lapse drops the combo.
    w.update(1.05);
    expect(w.combo, 0);
    w.debugSpawn(FoeKind.walker, 220, 230);
    w.dash(0, -150);
    expect(w.combo, 1);
    expect(w.score, 110 + 10);
  });

  test('waves progress with a bonus; wave 13 is the boss', () {
    expect(DashWorld.waveRoster(1), hasLength(4));
    expect(DashWorld.waveRoster(1).toSet(), {FoeKind.walker});
    expect(DashWorld.waveRoster(5).toSet(), FoeKind.values.toSet()..remove(FoeKind.boss));
    final w = arena(hold: false);
    w.debugSpawn(FoeKind.walker, 200, 250);
    w.dash(0, -160);
    run(w, 0.1);
    expect(w.phase, DashPhase.intermission);
    expect(w.score, 10 + 50);
    run(w, 1.7);
    expect(w.wave, 2);
    expect(w.phase, DashPhase.fighting);
    expect(w.remainingInWave, DashWorld.waveRoster(2).length);
    w.debugStartWave(DashWorld.bossWave);
    expect(w.isBossWave, isTrue);
    expect(w.boss, isNotNull);
    expect(w.remainingInWave, 1);
  });

  test('boss takes damage only through its rotating weak-spot arc; clearing it wins', () {
    final w = arena();
    w.debugStartWave(DashWorld.bossWave);
    final b = w.boss!;
    b.pos.setValues(200, 340);
    b.weakAngle = math.pi; // weak spot faces left
    b.weakSpin = 0;
    w.hero.setValues(200, 340 - b.radius - 60); // above: not the weak side
    w.dash(0, 120);
    expect(b.hp, 6);
    expect(w.hero.y, lessThan(340 - b.radius));
    expect(w.events.any((e) => e.kind == DashEventKind.blocked && e.foe == FoeKind.boss), isTrue);
    for (var i = 0; i < 6; i++) {
      w.update(0.6);
      b.pos.setValues(200, 340);
      b.weakAngle = math.pi;
      b.weakSpin = 0;
      w.bolts.clear();
      w.foes.removeWhere((f) => f.kind != FoeKind.boss);
      w.hero.setValues(200 - b.radius - 60, 340);
      expect(DashWorld.inWeakArc(b, 200 - b.radius, 340), isTrue);
      w.dash(120, 0);
    }
    expect(w.won, isTrue);
    expect(w.isOver, isTrue);
    expect(w.score, greaterThan(1500));
  });

  test('determinism: same seed and inputs give the same run', () {
    String play(int seed) {
      final w = DashWorld(width: 400, height: 680, seed: seed);
      run(w, 40, bot);
      return snapshot(w);
    }

    expect(play(11), play(11));
    expect(play(11), isNot(play(12)));
  });

  test('bot clears wave 5 on most seeds; an idle hero loses', () {
    var cleared = 0;
    for (var seed = 1; seed <= 10; seed++) {
      final w = DashWorld(width: 400, height: 680, seed: seed);
      // A bot that swipes at most every 0.35 s, roughly thumb speed.
      final brain = makeBot(think: 0.35);
      for (var i = 0; i < 180 * 60 && !w.isOver && w.wave <= 5; i++) {
        brain(w);
        w.update(DashWorld.step);
      }
      if (w.wave > 5 || w.won) cleared++;
      final idle = DashWorld(width: 400, height: 680, seed: seed);
      run(idle, 120);
      expect(idle.isOver, isTrue, reason: 'idle seed $seed');
      expect(idle.won, isFalse);
      expect(idle.wave, 1);
    }
    expect(cleared, greaterThanOrEqualTo(7));
  });

  test('renderer smoke: a swipe dashes, slow motion runs, and the game renders', () {
    final context = CartridgeContext(
      manifest: EdgeDashCartridge.kManifest,
      save: CartridgeSave(),
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    late EdgeDashGame game;
    final session = FlameCartridgeSession<EdgeDashGame>(context, (s) => game = EdgeDashGame(s, seed: 5));
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    final w = game.dash;
    w.debugClearSpawnQueue();
    w.debugHoldWave = true;
    final h = w.hero.clone();
    w.debugSpawn(FoeKind.walker, h.x + 40, h.y);
    w.debugSpawn(FoeKind.walker, h.x + 80, h.y);
    final down = game.toScreen(h.x, h.y);
    game.onPointerDown(down);
    game.onPointerMove(down + Vector2(30, 0), Vector2(30, 0));
    paint();
    game.onPointerUp(down + Vector2(60, 0));
    expect(w.kills, 2);
    for (var i = 0; i < 40; i++) {
      game.update(1 / 60);
      if (i % 10 == 0) paint();
    }
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
    // Losing reports exactly once and records the best wave.
    w.hearts = 1;
    w.hero.setValues(200, 300);
    w.debugSpawn(FoeKind.walker, 200, 310);
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    paint();
    expect(session.state, SessionState.ended);
    expect(context.save.intData('bestWave'), 1);
  });
}
