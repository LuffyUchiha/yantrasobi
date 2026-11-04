import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/shatter_run/shatter_run.dart';
import 'package:yantrasobi/cartridges/shatter_run/shatter_world.dart';

void main() {
  void run(ShatterWorld w, double seconds) {
    for (var t = 0.0; t < seconds && !w.isOver; t += 1 / 60) {
      w.update(1 / 60);
    }
  }

  /// Aims at the centre of [p] from the camera.
  void aimAt(ShatterWorld w, Pane p) {
    final dx = (p.x0 + p.x1) / 2 + p.offset, dy = (p.y0 + p.y1) / 2 - ShatterWorld.eyeY + 0.3, dz = p.z - w.z;
    final l = math.sqrt(dx * dx + dy * dy + dz * dz);
    w.throwBall(dx / l, dy / l, dz / l);
  }

  test('manifest is valid', () => expect(ShatterRunCartridge.kManifest.validate(), isEmpty));

  test('the camera moves forward and speeds up over distance', () {
    final w = ShatterWorld(seed: 1)..debugClear();
    final s0 = w.speed;
    run(w, 20);
    expect(w.z, greaterThan(100));
    expect(w.speed, greaterThan(s0));
  });

  test('throwing costs one ball', () {
    final w = ShatterWorld(seed: 1);
    expect(w.throwBall(0, 0, 1), isTrue);
    expect(w.ammo, ShatterWorld.startBalls - 1);
  });

  test('a ball breaks a glass pane it crosses', () {
    final w = ShatterWorld(seed: 1)..debugClear();
    final pane = Pane(z: 20, x0: -3, x1: 3, y0: 0, y1: 4.5);
    w.panes.add(pane);
    aimAt(w, pane);
    run(w, 1.0);
    expect(pane.broken, isTrue);
    expect(w.shattered, 1);
    expect(w.crashes, 0);
  });

  test('flying into unbroken glass costs 10 balls', () {
    final w = ShatterWorld(seed: 1)..debugClear();
    w.panes.add(Pane(z: 5, x0: -3, x1: 3, y0: 0, y1: 4.5));
    run(w, 2);
    expect(w.crashes, 1);
    expect(w.ammo, ShatterWorld.startBalls - ShatterWorld.crashPenalty);
  });

  test('solid frames bounce balls instead of breaking', () {
    final w = ShatterWorld(seed: 1)..debugClear();
    final frame = Pane(z: 20, x0: -3, x1: 3, y0: 0, y1: 4.5, solid: true);
    w.panes.add(frame);
    aimAt(w, frame);
    run(w, 0.8);
    expect(frame.broken, isFalse);
    expect(w.shattered, 0);
  });

  test('crystals give three balls when hit', () {
    final w = ShatterWorld(seed: 1)..debugClear();
    final c = Crystal(0, ShatterWorld.eyeY + 0.3, 15);
    w.crystals.add(c);
    final ammo = w.ammo;
    w.throwBall(0, 0.02, 1);
    run(w, 0.6);
    expect(c.taken, isTrue);
    expect(w.ammo, ammo - 1 + 3);
  });

  test('running out of balls ends the run', () {
    final w = ShatterWorld(seed: 2);
    w.ammo = 3;
    run(w, 120);
    expect(w.isOver, isTrue);
  });

  test('a bot that shoots the next blocking glass survives a long time', () {
    for (var seed = 1; seed <= 4; seed++) {
      final w = ShatterWorld(seed: seed);
      var cooldown = 0.0;
      for (var t = 0.0; t < 90 && !w.isOver; t += 1 / 60) {
        cooldown -= 1 / 60;
        final target = w.nextBlockingGlass();
        final crystal = w.nextCrystal(18);
        if (target != null && cooldown <= 0 && target.z - w.z < 22) {
          aimAt(w, target);
          cooldown = 0.35;
        } else if (crystal != null && cooldown <= 0) {
          final dx = crystal.x, dy = crystal.y - ShatterWorld.eyeY + 0.25, dz = crystal.z - w.z;
          final l = math.sqrt(dx * dx + dy * dy + dz * dz);
          w.throwBall(dx / l, dy / l, dz / l);
          cooldown = 0.35;
        }
        w.update(1 / 60);
      }
      expect(w.z, greaterThan(500), reason: 'seed $seed died at ${w.z.round()} m');
    }
  });

  test('generation is deterministic per seed', () {
    final a = ShatterWorld(seed: 9), b = ShatterWorld(seed: 9);
    expect([for (final p in a.panes) p.z], [for (final p in b.panes) p.z]);
  });
}
