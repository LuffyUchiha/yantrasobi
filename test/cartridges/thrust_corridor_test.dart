import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart' show Vector2;
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/thrust_corridor/thrust_corridor.dart';
import 'package:yantrasobi/cartridges/thrust_corridor/thrust_world.dart';
import 'package:yantrasobi/yantrasobi/adapters/flame_adapter.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

const double dt = ThrustWorld.dt;
const double h = ThrustWorld.height;
const double r = ThrustWorld.heroRadius;

void runFor(ThrustWorld w, double seconds, {bool Function(ThrustWorld w)? hold, List<ThrustEvent>? log}) {
  final steps = (seconds / dt).round();
  for (var i = 0; i < steps && !w.isOver; i++) {
    if (hold != null) w.holding = hold(w);
    w.update(dt);
    log?.addAll(w.events);
  }
}

/// A full-height static laser wall [ahead] metres on: unavoidable.
LaserDef wall() => LaserDef.seg(0, 0, 0, h);

/// Keeps the hero hovering near [target] with a simple bang-bang controller.
bool Function(ThrustWorld) hover(double target) =>
    (w) => w.hero.y + w.hero.vy * 0.12 < target;

void main() {
  test('manifest is valid', () {
    const m = ThrustCorridorCartridge.kManifest;
    expect(m.validate(), isEmpty);
    expect(m.id, 'thrust-corridor');
    expect(m.version, '1.0.0');
    expect(m.controls, isNotEmpty);
  });

  test('thrust and gravity integrate with velocity caps, floor running and ceiling clamp', () {
    final w = ThrustWorld(generate: false);
    expect(w.hero.y, r);
    expect(w.hero.grounded, isTrue);
    // Idle on the floor stays put (running).
    runFor(w, 0.5);
    expect(w.hero.y, r);
    expect(w.hero.grounded, isTrue);
    // One held step accelerates at (thrust - gravity).
    w.holding = true;
    w.update(dt);
    expect(w.hero.vy, closeTo((ThrustWorld.thrust - ThrustWorld.gravity) * dt, 1e-9));
    expect(w.hero.grounded, isFalse);
    // Rise speed is capped, then the ceiling clamps.
    runFor(w, 0.6, hold: (_) => true);
    expect(w.hero.vy, lessThanOrEqualTo(ThrustWorld.maxRise));
    runFor(w, 1.5, hold: (_) => true);
    expect(w.hero.y, h - r);
    expect(w.hero.vy, 0);
    // Releasing falls under gravity alone, capped at maxFall, and lands running.
    w.holding = false;
    w.update(dt);
    expect(w.hero.vy, closeTo(-ThrustWorld.gravity * dt, 1e-9));
    runFor(w, 0.4);
    expect(w.hero.vy, greaterThanOrEqualTo(-ThrustWorld.maxFall));
    runFor(w, 2);
    expect(w.hero.y, r);
    expect(w.hero.grounded, isTrue);
    expect(w.isOver, isFalse);
  });

  test('static laser bars collide as segments against the hero circle', () {
    final l = Laser(10, 4, 4, math.pi / 2, 0, 0, 6); // vertical bar from y 0 to 8 at x 10
    expect(l.hits(10, 5, r), isTrue);
    expect(l.hits(10, 8 + r + ThrustWorld.laserHalfWidth + 0.01, r), isFalse); // above the top emitter
    expect(l.hits(10, 8 + r, r), isTrue); // grazing the top end
    expect(l.hits(10 - r - ThrustWorld.laserHalfWidth - 0.01, 4, r), isFalse);
    expect(l.hits(10 - r, 4, r), isTrue);
    final diag = Laser(0, 0, 5, math.pi / 4, 0, 0, 6);
    expect(diag.hits(2, 2, 0.1), isTrue);
    expect(diag.hits(2, 3, 0.1), isFalse);

    // In play: running on the floor into a floor-mounted bar crashes ...
    final w = ThrustWorld(generate: false)..injectLaser(LaserDef.seg(0, 0, 0, 8), ahead: 4);
    runFor(w, 2);
    expect(w.isOver, isTrue);
    expect(w.crashedBy, 'a laser');
    // ... while hovering over it passes.
    final w2 = ThrustWorld(generate: false)..injectLaser(LaserDef.seg(0, 0, 0, 8), ahead: 8);
    runFor(w2, 3, hold: hover(11));
    expect(w2.isOver, isFalse);
    expect(w2.distance, greaterThan(15));
  });

  test('rotating lasers sweep with the pattern clock', () {
    // Spins a quarter turn per second; clock = (heroX - entryX) / speed.
    final l = Laser(10, 8, 3, 0, math.pi / 2, 4, 6);
    expect(l.angleAt(4), 0);
    expect(l.angleAt(10), closeTo(math.pi / 2, 1e-12)); // after 1 s: vertical
    expect(l.hits(10, 10.5, r), isTrue);
    expect(l.hits(10, 12, r), isFalse);
    final flat = Laser(10, 8, 3, 0, math.pi / 2, 7, 6); // 0.5 s behind: 45 degrees at x 10
    expect(flat.angleAt(10), closeTo(math.pi / 4, 1e-12));
    expect(flat.hits(10, 10.5, r), isFalse);
    final horizontal = Laser(10, 8, 3, 0, math.pi / 2, 10, 6);
    expect(horizontal.hits(10, 10.5, r), isFalse);
    expect(horizontal.hits(10, 8.5, r), isTrue);

    // In play, a floor runner under a spinner's hub is safe; at hub height it is not.
    final safe = ThrustWorld(generate: false)..injectLaser(const LaserDef(0, 8, 3.5, 0, 120), ahead: 6);
    runFor(safe, 3);
    expect(safe.isOver, isFalse);
    final zapped = ThrustWorld(generate: false)
      ..debugSetHero(8)
      ..injectLaser(const LaserDef(0, 8, 3.5, 0, 120), ahead: 6);
    runFor(zapped, 3, hold: hover(8));
    expect(zapped.isOver, isTrue);
  });

  test('missiles warn for 1.2 s while tracking, lock, then fly fast along the locked line', () {
    final w = ThrustWorld(generate: false);
    final m = w.injectMissile(ahead: 24);
    final log = <ThrustEvent>[];
    int? warnTick, lockTick, launchTick;
    for (var i = 0; i < 600 && !w.isOver && launchTick == null; i++) {
      w.holding = hover(5)(w);
      w.update(dt);
      log.addAll(w.events);
      if (m.warned && warnTick == null) {
        warnTick = w.tick;
        expect(m.launched, isFalse);
      }
      if (m.locked && lockTick == null) lockTick = w.tick;
      if (!m.locked) expect(m.y, w.hero.y); // homing: tracks the hero until locked
      if (m.launched) launchTick = w.tick;
    }
    expect(
      log.map((e) => e.kind),
      containsAllInOrder([ThrustEventKind.missileWarn, ThrustEventKind.missileLaunch]),
    );
    expect((launchTick! - warnTick!) * dt, closeTo(ThrustWorld.warnTime, 0.05));
    expect((launchTick - lockTick!) * dt, closeTo(ThrustWorld.lockBefore, 0.05));
    final lockedY = m.y;
    // It enters from the right edge and closes faster than the scroll.
    expect(m.xAt(w.tick) - w.distance, closeTo(ThrustWorld.missileLead, 0.2));
    final x0 = m.xAt(w.tick);
    w.update(dt);
    expect(x0 - m.xAt(w.tick), closeTo(ThrustWorld.missileSpeed * dt, 1e-9));
    expect(m.y, lockedY);
    // Staying on the locked line is a hit.
    runFor(w, 1.5, hold: hover(lockedY));
    expect(w.isOver, isTrue);
    expect(w.crashedBy, 'a missile');

    // Dodging after the lock survives.
    final w2 = ThrustWorld(generate: false);
    final m2 = w2.injectMissile(ahead: 24);
    runFor(w2, 4, hold: (w) => m2.locked ? false : w.hero.y < 8);
    expect(m2.launched, isTrue);
    expect(w2.isOver, isFalse);
  });

  test('electric gates pulse on and off on their period and only hurt while live', () {
    final g = Gate(20, 0, h, 1.6, 0.8, 0, 0, 8); // clock = x / 8
    expect(g.onAt(0), isTrue);
    expect(g.onAt(8 * 0.79), isTrue);
    expect(g.onAt(8 * 0.81), isFalse);
    expect(g.onAt(8 * 1.59), isFalse);
    expect(g.onAt(8 * 1.61), isTrue);
    expect(g.untilOn(8 * 1.0), closeTo(0.6, 1e-9));
    expect(g.hits(20, 5, r), isFalse); // clock 2.5 s -> cycle 0.9: off
    expect(Gate(20, 0, h, 1.6, 0.8, 0.8, 0, 8).hits(20, 5, r), isTrue); // phase-shifted: on

    // A full-height gate reached after 1.0 s (cycle 1.0, off) is passable ...
    final pass = ThrustWorld(generate: false)..injectGate(const GateDef(0, 0, h), ahead: 6);
    runFor(pass, 2);
    expect(pass.isOver, isFalse);
    // ... the same gate shifted to be live then is not.
    final fry = ThrustWorld(generate: false)..injectGate(const GateDef(0, 0, h, phase: 0.6), ahead: 6);
    runFor(fry, 2);
    expect(fry.isOver, isTrue);
    expect(fry.crashedBy, 'an electric gate');
  });

  test('a shield absorbs exactly one hit, with a short grace period', () {
    final w = ThrustWorld(generate: false)..injectPickup(PickupKind.shield, 1, r);
    runFor(w, 0.3);
    expect(w.shield, isTrue);
    w.injectLaser(wall(), ahead: 3);
    final log = <ThrustEvent>[];
    runFor(w, 1.5, log: log);
    expect(w.isOver, isFalse);
    expect(w.shield, isFalse);
    expect(w.hitsAbsorbed, 1);
    expect(log.map((e) => e.kind), contains(ThrustEventKind.shieldBreak));
    w.injectLaser(wall(), ahead: 3);
    runFor(w, 1.5);
    expect(w.isOver, isTrue);
  });

  test('the magnet pulls nearby coins in; score is metres + 5 per coin', () {
    final plain = ThrustWorld(generate: false)..injectCoin(4, 5);
    runFor(plain, 1.5);
    expect(plain.coins, 0);
    final w = ThrustWorld(generate: false)..injectPickup(PickupKind.magnet, 0.5, r);
    runFor(w, 0.2);
    expect(w.magnetActive, isTrue);
    w.injectCoin(4, 5);
    w.injectCoin(5, 6);
    runFor(w, 1.5);
    expect(w.coins, 2);
    expect(w.score, w.metres + 2 * ThrustWorld.coinValue);
    runFor(w, ThrustWorld.magnetDuration);
    expect(w.magnetActive, isFalse);
  });

  test('the Strider walker jumps on tap, absorbs the first hit, and expires after 8 s', () {
    final w = ThrustWorld(generate: false)
      ..debugSetHero(4)
      ..injectPickup(PickupKind.strider, 0.3, 4);
    runFor(w, 0.1);
    expect(w.inStrider, isTrue);
    expect(w.radius, ThrustWorld.striderRadius);
    // No jetpack: holding in the air does not thrust; it falls to the floor and walks.
    runFor(w, 1, hold: (_) => true);
    w.holding = false;
    runFor(w, 1.2);
    expect(w.hero.grounded, isTrue);
    expect(w.hero.y, ThrustWorld.striderRadius);
    // A tap (press + release within one frame) jumps.
    w.press();
    w.release();
    w.update(dt);
    expect(w.hero.vy, closeTo(ThrustWorld.striderJump - ThrustWorld.gravity * dt, 1e-9));
    final vy = w.hero.vy;
    w.holding = true;
    w.update(dt);
    expect(w.hero.vy, lessThan(vy)); // holding mid-air adds nothing
    w.holding = false;
    runFor(w, 1);
    // First hit only wrecks the walker.
    w.injectLaser(wall(), ahead: 3);
    final log = <ThrustEvent>[];
    runFor(w, 1.2, log: log);
    expect(w.isOver, isFalse);
    expect(w.inStrider, isFalse);
    expect(log.map((e) => e.kind), contains(ThrustEventKind.striderBreak));
    expect(w.hitsAbsorbed, 1);

    // Unhurt, it times out after its duration.
    final t = ThrustWorld(generate: false)..injectPickup(PickupKind.strider, 0.3, r);
    final log2 = <ThrustEvent>[];
    runFor(t, ThrustWorld.striderDuration - 0.5, log: log2);
    expect(t.inStrider, isTrue);
    runFor(t, 1, log: log2);
    expect(t.inStrider, isFalse);
    expect(log2.map((e) => e.kind), contains(ThrustEventKind.striderEnd));
  });

  test('speed ramps up with distance, pattern by pattern, up to the cap', () {
    expect(ThrustWorld.speedFor(0), ThrustWorld.startSpeed);
    expect(ThrustWorld.speedFor(300), greaterThan(ThrustWorld.speedFor(100)));
    expect(ThrustWorld.speedFor(1e6), ThrustWorld.maxSpeed);
    final w = ThrustWorld(seed: 5);
    final pilot = ThrustAutopilot();
    runFor(w, 40, hold: pilot.decide);
    expect(w.isOver, isFalse);
    expect(w.speed, greaterThan(ThrustWorld.startSpeed + 1));
    expect(w.speed, lessThanOrEqualTo(ThrustWorld.maxSpeed));
  });

  test(
    'pattern validator: every library pattern is flyable at every ramp speed; impossible ones are rejected',
    () {
      expect(patternLibrary.length, greaterThanOrEqualTo(15));
      for (final p in patternLibrary) {
        for (final v in [ThrustWorld.startSpeed, 8.25, ThrustWorld.maxSpeed]) {
          for (final mirrored in [false, true]) {
            expect(PatternValidator.feasible(p, v, mirrored: mirrored), isTrue, reason: '${p.name} at $v');
          }
        }
      }
      // A full-height wall has no path.
      expect(PatternValidator.feasible(PatternDef('wall', lasers: [wall()]), 6), isFalse);
      // A climb-to-dive switchback 1.5 m apart exceeds the thrust/gravity limits at speed ...
      final switchback = PatternDef(
        'switchback',
        lasers: [LaserDef.seg(4, 0, 4, 12), LaserDef.seg(5.5, 4, 5.5, h)],
      );
      expect(PatternValidator.feasible(switchback, ThrustWorld.maxSpeed), isFalse);
      // ... while the same pair spread out is fine.
      final relaxed = PatternDef('relaxed', lasers: [LaserDef.seg(4, 0, 4, 12), LaserDef.seg(18, 4, 18, h)]);
      expect(PatternValidator.feasible(relaxed, ThrustWorld.maxSpeed), isTrue);
      // A gate pair that is never both off cannot be crossed.
      final strobe = PatternDef(
        'strobe',
        gates: [
          const GateDef(2, 0, 9, period: 1, onTime: 0.6),
          const GateDef(2, 7, h, period: 1, onTime: 0.6, phase: 0.5),
        ],
      );
      expect(PatternValidator.feasible(strobe, 9), isFalse);
    },
  );

  test('a planner bot survives 90 s on several seeds; the only hits it takes are walker wrecks', () {
    for (final seed in [1, 2, 3]) {
      final w = ThrustWorld(seed: seed);
      final pilot = ThrustAutopilot();
      final log = <ThrustEvent>[];
      runFor(w, 90, hold: pilot.decide, log: log);
      expect(w.isOver, isFalse, reason: 'seed $seed crashed into ${w.crashedBy} at ${w.metres} m');
      expect(log.where((e) => e.kind == ThrustEventKind.shieldBreak), isEmpty, reason: 'seed $seed');
      expect(w.metres, greaterThan(600));
      expect(w.patternsSpawned, greaterThan(25));
      expect(w.spawnedNames.toSet().length, greaterThan(8));
      expect(w.coins, greaterThan(10));
    }
  });

  test('an idle player runs into a floor laser quickly', () {
    for (final seed in [1, 2, 3]) {
      final w = ThrustWorld(seed: seed);
      runFor(w, 60);
      expect(w.isOver, isTrue);
      expect(w.won, isNull);
    }
  });

  test('runs are deterministic per seed and input', () {
    List<Object> play(int seed) {
      final w = ThrustWorld(seed: seed);
      runFor(w, 30, hold: (w) => (w.tick ~/ 25).isEven ? w.hero.y < 9 : w.hero.y < 5);
      return [w.tick, w.distance, w.hero.y, w.coins, w.isOver, w.spawnedNames.join(','), w.lasers.length];
    }

    expect(play(11), play(11));
    expect(play(11).toString() == play(12).toString(), isFalse);
  });

  test('renderer smoke: hold to fly, power-ups and hazards render, a crash ends the run once', () {
    final context = CartridgeContext(
      manifest: ThrustCorridorCartridge.kManifest,
      save: CartridgeSave(bestScore: 250),
      audio: SilentAudio(),
      settings: AsobiSettings(MemoryKeyValueStore()),
    );
    late ThrustCorridorGame game;
    final session = FlameCartridgeSession<ThrustCorridorGame>(
      context,
      (s) => game = ThrustCorridorGame(s, seed: 4),
    );
    session.start();
    game.onGameResize(Vector2(400, 800));
    void paint() {
      final rec = PictureRecorder();
      game.render(Canvas(rec));
      rec.endRecording().dispose();
    }

    paint();
    expect(game.best, 250);
    final w = game.run;
    game.onPointerDown(Vector2(200, 500));
    expect(w.holding, isTrue);
    for (var i = 0; i < 30; i++) {
      game.update(dt);
    }
    expect(w.hero.y, greaterThan(r + 1));
    game.onPointerUp(Vector2(200, 500));
    expect(w.holding, isFalse);

    w.debugClear();
    w
      ..injectCoin(3, w.hero.y)
      ..injectPickup(PickupKind.magnet, 2, w.hero.y)
      ..injectPickup(PickupKind.shield, 8, 8)
      ..injectLaser(const LaserDef(6, 13, 2, 0, 90), ahead: 4)
      ..injectGate(const GateDef(0, 12, 16), ahead: 6)
      ..injectMissile(ahead: 30);
    for (var i = 0; i < 90; i++) {
      game.update(dt);
      if (i % 10 == 0) paint();
    }
    expect(game.entityCount, greaterThan(0));
    expect(session.state, SessionState.running);
    // Walker mode renders too.
    w.injectPickup(PickupKind.strider, 0.2, w.hero.y);
    for (var i = 0; i < 20; i++) {
      game.update(dt);
    }
    expect(w.inStrider, isTrue);
    paint();

    // Strip every power-up and drive into walls until the run ends.
    w
      ..shield = false
      ..striderEndTick = 0
      ..graceEndTick = 0;
    for (var i = 0; i < 400 && session.state == SessionState.running; i++) {
      if (i % 60 == 0) w.injectLaser(wall(), ahead: 2);
      game.update(dt);
      if (i % 20 == 0) paint();
    }
    expect(w.isOver, isTrue);
    expect(session.state, SessionState.ended);
    expect(session.result!.won, isNull);
    expect(session.result!.score, w.score);
    expect(session.result!.details['Distance'], '${w.metres} m');
    paint();

    session.restart();
    expect(identical(game.run, w), isFalse);
    expect(game.run.distance, 0);
  });
}
