import 'dart:math' as math;

import 'package:flutter/material.dart' hide Material;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/projector.dart';
import '../../yantrasobi/adapters/scene_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import 'shatter_world.dart';

class ShatterRunCartridge extends SceneCartridge<ShatterRunGame> {
  const ShatterRunCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'shatter-run',
    title: 'Shatter Run',
    tagline: 'Every ball is a heartbeat. Spend them on glass.',
    description:
        'Glide down an endless crystal corridor. Tap to throw steel balls and shatter the glass '
        'before you fly into it. Crashing costs ten balls, so aim for doors and sliding panels, '
        'and hit the blue crystals for more. When the balls run out, so does the run.',
    genre: 'Glass breaker',
    engine: CartridgeEngine.scene3d,
    version: '1.0.0',
    accent: Color(0xFF64DFDF),
    icon: Icons.blur_on_rounded,
    tags: ['3d', 'endless', 'aim', 'arcade'],
    controls: ['Tap where you want to throw a ball'],
    mechanics: ['ball economy', 'glass breaking', 'crystal pickups', 'speed ramp'],
    goal: 'Travel as far as you can. Crashing into glass costs 10 balls; 0 balls ends the run.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  ShatterRunGame createGame(SceneCartridgeSession<ShatterRunGame> session) => ShatterRunGame(session);
}

class _Shard {
  double x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, life = 0, spin = 0;
}

class ShatterRunGame extends SceneGame {
  ShatterRunGame(super.session, {int? seed})
    : world = ShatterWorld(seed: seed ?? DateTime.now().millisecondsSinceEpoch);

  final ShatterWorld world;
  final math.Random _rng = math.Random(5);
  final List<_Shard> _shards = [for (var i = 0; i < 180; i++) _Shard()];
  bool _reported = false;
  double _flash = 0;
  double _endDelay = 1.0;

  @override
  int get entityCount => world.entityCount + _shards.where((s) => s.life > 0).length;

  @override
  SceneCameraSpec camera(Size size) => SceneCameraSpec(
    eye: vm.Vector3(0, ShatterWorld.eyeY, world.z),
    target: vm.Vector3(0, ShatterWorld.eyeY - 0.15, world.z + 10),
    fovY: 1.05,
  );

  @override
  void pointerDown(Offset p, Size size) {
    final dir = camera(size).projector(size).rayDirection(p);
    if (world.throwBall(dir.x, dir.y, dir.z)) audio.play(Sfx.whoosh);
  }

  void _burst(double x, double y, double z, int n) {
    var spawned = 0;
    for (final s in _shards) {
      if (s.life > 0) continue;
      s
        ..x = x + (_rng.nextDouble() - 0.5) * 1.2
        ..y = y + (_rng.nextDouble() - 0.5) * 1.2
        ..z = z
        ..vx = (_rng.nextDouble() - 0.5) * 6
        ..vy = _rng.nextDouble() * 4
        ..vz = world.speed * 0.6 + _rng.nextDouble() * 4
        ..spin = _rng.nextDouble() * 6
        ..life = 1.2;
      if (++spawned >= n) break;
    }
  }

  @override
  void update(double dt) {
    world.update(dt);
    if (_flash > 0) _flash -= dt;
    final reduced = session.context.settings.reducedEffects;
    for (final e in world.events) {
      switch (e.kind) {
        case ShatterEventKind.shatter:
          audio.play(Sfx.pop);
          _burst(e.x, e.y, e.z, reduced ? 8 : 26);
        case ShatterEventKind.crash:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          _flash = 0.5;
          _burst(0, ShatterWorld.eyeY, e.z, reduced ? 10 : 40);
        case ShatterEventKind.crystal:
          audio.play(Sfx.coin);
        case ShatterEventKind.bounce:
          audio.play(Sfx.thud);
        case ShatterEventKind.checkpoint:
          audio.play(Sfx.powerup);
        case ShatterEventKind.throwBall:
          break;
      }
    }
    for (final s in _shards) {
      if (s.life <= 0) continue;
      s
        ..life -= dt
        ..vy += ShatterWorld.gravity * dt
        ..x += s.vx * dt
        ..y += s.vy * dt
        ..z += s.vz * dt;
      if (s.y < 0) {
        s.y = 0;
        s.vy = -s.vy * 0.3;
      }
    }
    if (world.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) {
        _reported = true;
        finish(
          RunResult(
            score: world.score,
            headline: 'Out of balls after ${world.z.round()} m.',
            details: {
              'Distance': '${world.z.round()} m',
              'Glass shattered': '${world.shattered}',
              'Crystals': '${world.crystalsTaken}',
              'Crashes': '${world.crashes}',
            },
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------- 3D
  static const int _segments = 14;
  static const double _segLen = 10;
  static const int _paneCap = 64, _crystalCap = 24;

  InstancedMesh? _walls, _panes, _crystalMesh, _ballMesh, _shardMesh;
  final vm.Vector3 _t = vm.Vector3.zero(), _s = vm.Vector3.zero();
  final vm.Quaternion _q = vm.Quaternion.identity();

  static vm.Vector4 _v4(Color c) => vm.Vector4(c.r, c.g, c.b, 1);

  static PhysicallyBasedMaterial _mat(Color c, {double rough = 0.5, double metal = 0}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = _v4(c)
        ..roughnessFactor = rough
        ..metallicFactor = metal;

  void _fill(InstancedMesh m, int n, [Color? color]) {
    final zero = vm.Matrix4.zero();
    for (var i = 0; i < n; i++) {
      m.addInstance(zero, color: color == null ? null : _v4(color));
    }
  }

  @override
  void buildScene(Scene scene) {
    applyGradientSky(scene, zenith: vm.Vector3(0.02, 0.05, 0.12), horizon: vm.Vector3(0.2, 0.6, 0.65));
    _walls = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(1, 1, 1)),
      material: _mat(Colors.white, rough: 0.6),
    );
    for (var i = 0; i < _segments * 4; i++) {
      final shade = i.isEven ? const Color(0xFF1F2A44) : const Color(0xFF26355A);
      _walls!.addInstance(vm.Matrix4.zero(), color: _v4(shade));
    }
    _panes = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(1, 1, 1)),
      material: _mat(Colors.white, rough: 0.05, metal: 0.3),
    );
    _fill(_panes!, _paneCap, const Color(0xFF9FF3F3));
    _crystalMesh = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(0.5, 0.5, 0.5)),
      material: _mat(const Color(0xFF4EA8FF), rough: 0.1, metal: 0.2)
        ..emissiveFactor = vm.Vector4(0.1, 0.3, 0.9, 1),
    );
    _fill(_crystalMesh!, _crystalCap);
    _ballMesh = InstancedMesh(
      geometry: SphereGeometry(radius: ShatterWorld.ballRadius),
      material: _mat(const Color(0xFFDDE3EE), rough: 0.15, metal: 0.95),
    );
    _fill(_ballMesh!, ShatterWorld.ballPoolSize);
    _shardMesh = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(0.12, 0.12, 0.02)),
      material: _mat(const Color(0xFFCFFAFA), rough: 0.05, metal: 0.4),
    );
    _fill(_shardMesh!, _shards.length);
    for (final m in [_walls!, _panes!, _crystalMesh!, _ballMesh!, _shardMesh!]) {
      scene.add(Node()..addComponent(InstancedMeshComponent(m)));
    }
    syncScene();
  }

  void _box(vm.Matrix4 m, double x, double y, double z, double sx, double sy, double sz) {
    _t.setValues(x, y, z);
    _s.setValues(sx, sy, sz);
    m.setFromTranslationRotationScale(_t, _q, _s);
  }

  @override
  void syncScene() {
    const w = ShatterWorld.halfWidth, h = ShatterWorld.height;
    final base = (world.z / _segLen).floor() * _segLen;
    _walls?.updateInstanceTransforms((list) {
      for (var i = 0; i < _segments; i++) {
        final zc = base + i * _segLen + _segLen / 2 - _segLen;
        _box(list[i * 4], -w - 0.1, h / 2, zc, 0.2, h, _segLen - 0.05);
        _box(list[i * 4 + 1], w + 0.1, h / 2, zc, 0.2, h, _segLen - 0.05);
        _box(list[i * 4 + 2], 0, -0.1, zc, w * 2, 0.2, _segLen - 0.05);
        _box(list[i * 4 + 3], 0, h + 0.1, zc, w * 2, 0.2, _segLen - 0.05);
      }
    }, recomputeWinding: false);
    final panes = world.panes;
    for (var i = 0; i < _paneCap && i < panes.length; i++) {
      _panes!.setInstanceColor(i, _v4(panes[i].solid ? const Color(0xFF3A4566) : const Color(0xFF9FF3F3)));
    }
    _panes?.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        if (i >= panes.length || panes[i].broken) {
          list[i].setZero();
          continue;
        }
        final p = panes[i];
        _box(
          list[i],
          (p.x0 + p.x1) / 2 + p.offset,
          (p.y0 + p.y1) / 2,
          p.z,
          p.x1 - p.x0,
          p.y1 - p.y0,
          p.solid ? 0.3 : 0.06,
        );
      }
    }, recomputeWinding: false);
    final crystals = world.crystals;
    _crystalMesh?.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        if (i >= crystals.length || crystals[i].taken) {
          list[i].setZero();
          continue;
        }
        final c = crystals[i];
        list[i].setFromTranslationRotationScale(
          vm.Vector3(c.x, c.y, c.z),
          vm.Quaternion.axisAngle(vm.Vector3(0.4, 1, 0.2).normalized(), world.time * 2 + i),
          vm.Vector3.all(1),
        );
      }
    }, recomputeWinding: false);
    _ballMesh?.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        final b = world.balls[i];
        if (!b.alive) {
          list[i].setZero();
        } else {
          _box(list[i], b.x, b.y, b.z, 1, 1, 1);
        }
      }
    }, recomputeWinding: false);
    _shardMesh?.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        final s = _shards[i];
        if (s.life <= 0) {
          list[i].setZero();
        } else {
          list[i].setFromTranslationRotationScale(
            vm.Vector3(s.x, s.y, s.z),
            vm.Quaternion.axisAngle(vm.Vector3(1, 0.5, 0.2).normalized(), s.spin * s.life * 4),
            vm.Vector3.all(1),
          );
        }
      }
    }, recomputeWinding: false);
  }

  // ---------------------------------------------------------------- fallback
  final Paint _p = Paint();

  void _rect3(Canvas canvas, Projector pr, double x0, double x1, double y0, double y1, double z, Color c) {
    final a = pr.projectXYZ(x0, y0, z), b = pr.projectXYZ(x1, y1, z);
    if (a == null || b == null) return;
    canvas.drawRect(Rect.fromPoints(a, b), _p..color = c);
  }

  @override
  void paintFallback(Canvas canvas, Size size, Projector pr) {
    canvas.drawRect(Offset.zero & size, _p..color = const Color(0xFF101830));
    const w = ShatterWorld.halfWidth, h = ShatterWorld.height;
    // Corridor rings every 5 m give depth.
    for (var k = 12; k >= 0; k--) {
      final z = (world.z / 5).floor() * 5 + k * 5.0;
      final a = pr.projectXYZ(-w, 0, z), b = pr.projectXYZ(w, h, z);
      if (a == null || b == null) continue;
      canvas.drawRect(
        Rect.fromPoints(a, b),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF2E3F6B),
      );
    }
    final items = <(double, VoidCallback)>[];
    for (final p in world.panes) {
      if (p.broken || p.z < world.z) continue;
      items.add((
        p.z,
        () => _rect3(
          canvas,
          pr,
          p.x0 + p.offset,
          p.x1 + p.offset,
          p.y0,
          p.y1,
          p.z,
          p.solid ? const Color(0xFF3A4566) : const Color(0x889FF3F3),
        ),
      ));
    }
    for (final c in world.crystals) {
      if (c.taken || c.z < world.z) continue;
      items.add((
        c.z,
        () {
          final o = pr.projectXYZ(c.x, c.y, c.z);
          if (o != null) {
            canvas.drawCircle(
              o,
              pr.scaleAt(vm.Vector3(c.x, c.y, c.z), 0.3),
              _p..color = const Color(0xFF4EA8FF),
            );
          }
        },
      ));
    }
    for (final b in world.balls) {
      if (!b.alive || b.z < world.z) continue;
      items.add((
        b.z,
        () {
          final o = pr.projectXYZ(b.x, b.y, b.z);
          if (o != null) {
            canvas.drawCircle(
              o,
              pr.scaleAt(vm.Vector3(b.x, b.y, b.z), ShatterWorld.ballRadius),
              _p..color = Colors.white,
            );
          }
        },
      ));
    }
    items.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, paint) in items) {
      paint();
    }
  }

  // ---------------------------------------------------------------- HUD
  @override
  void paintHud(Canvas canvas, Size size, Projector pr, EdgeInsets safe) {
    final top = safe.top + 14;
    CanvasText.draw(
      canvas,
      '${world.ammo}',
      Offset(size.width / 2, top),
      size: 40,
      align: Alignment.topCenter,
      color: world.ammo <= 5 ? const Color(0xFFFF6B6B) : Colors.white,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      'BALLS',
      Offset(size.width / 2, top + 48),
      size: 11,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
    CanvasText.draw(
      canvas,
      '${world.z.round()} m',
      Offset(size.width - 16, top + 6),
      size: 18,
      align: Alignment.topRight,
      color: const Color(0xFF64DFDF),
    );
    if (world.time < 3) {
      CanvasText.draw(
        canvas,
        'Tap to throw · break the glass before it hits you',
        Offset(size.width / 2, size.height - safe.bottom - 40),
        size: 14,
        align: Alignment.center,
      );
    }
    if (_flash > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFFFF3B5C).withValues(alpha: _flash * 0.5),
      );
      CanvasText.draw(
        canvas,
        '-10',
        Offset(size.width / 2, size.height * 0.4),
        size: 40,
        align: Alignment.center,
        color: Colors.white,
        weight: FontWeight.w900,
      );
    }
    if (!gpuActive) {
      CanvasText.draw(
        canvas,
        '2.5D fallback renderer',
        Offset(size.width - 12, size.height - safe.bottom - 8),
        size: 9,
        align: Alignment.bottomRight,
        color: Colors.white30,
      );
    }
  }
}
