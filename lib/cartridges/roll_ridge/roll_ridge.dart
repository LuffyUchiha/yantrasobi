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
import 'ridge_world.dart';

class RollRidgeCartridge extends SceneCartridge<RollRidgeGame> {
  const RollRidgeCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'roll-ridge',
    title: 'Roll Ridge',
    tagline: 'One ball. One winding sky track. Do not look down.',
    description:
        'Steer a rolling ball along a narrow track floating in the sky. Ramps launch you over gaps, '
        'sweeping bars and sliding pushers try to knock you off, and narrow bridges test your '
        'nerve. Grab gems, pass checkpoints, and roll across the finish with lives to spare.',
    genre: 'Rolling obstacle course',
    engine: CartridgeEngine.scene3d,
    version: '1.0.0',
    accent: Color(0xFF8AC926),
    icon: Icons.trip_origin_rounded,
    tags: ['3d', 'ball', 'obstacle course', 'hyper-casual'],
    controls: ['Drag left/right to steer the ball'],
    mechanics: ['rolling physics', 'ramps and gaps', 'moving hazards', 'checkpoints'],
    goal: 'Reach the finish line before losing all 3 lives to falls.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  RollRidgeGame createGame(SceneCartridgeSession<RollRidgeGame> session) => RollRidgeGame(session);
}

class RollRidgeGame extends SceneGame {
  RollRidgeGame(super.session, {int? seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      world = RidgeWorld(
        level: math.max(1, session.context.save.intData('level', 1)),
        seed: seed ?? DateTime.now().millisecondsSinceEpoch,
      ) {
    _camX = world.x;
  }

  final int level;
  final RidgeWorld world;
  bool _reported = false;
  double? _dragOrigin;
  double _camX = 0;
  double _flash = 0;

  @override
  int get entityCount => world.entityCount;

  @override
  SceneCameraSpec camera(Size size) => SceneCameraSpec(
    eye: vm.Vector3(_camX, math.max(world.y, 0) + 5.2, world.z - 8.5),
    target: vm.Vector3(_camX, math.max(world.y, 0) - 0.5, world.z + 7),
    fovY: 0.95,
  );

  @override
  void pointerDown(Offset p, Size size) => _dragOrigin = p.dx;

  @override
  void pointerMove(Offset p, Size size) {
    final o = _dragOrigin;
    if (o == null) return;
    world.steer = ((p.dx - o) / 70).clamp(-1.0, 1.0);
  }

  @override
  void pointerUp(Offset p, Size size) {
    _dragOrigin = null;
    world.steer = 0;
  }

  @override
  void update(double dt) {
    world.update(dt);
    _camX += (world.x - _camX) * math.min(1.0, dt * 3);
    if (_flash > 0) _flash -= dt;
    for (final e in world.events) {
      switch (e.kind) {
        case RidgeEventKind.fall:
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
          _flash = 0.4;
        case RidgeEventKind.gem:
          audio.play(Sfx.coin);
        case RidgeEventKind.bump:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.medium);
        case RidgeEventKind.checkpoint:
          audio.play(Sfx.powerup);
        case RidgeEventKind.jump:
          audio.play(Sfx.whoosh);
        case RidgeEventKind.respawn:
        case RidgeEventKind.finish:
          break;
      }
    }
    _gemsDirty = true;
    if (world.isOver && !_reported) {
      _reported = true;
      final won = world.phase == RidgePhase.won;
      if (won) {
        session.context.save.data['level'] = level + 1;
        session.context.commitSave();
      }
      finish(
        RunResult(
          score: world.score,
          won: won,
          headline: won
              ? 'Ridge $level cleared! Level ${level + 1} unlocked.'
              : 'Out of lives at ${(world.progress * 100).round()}% of the track.',
          details: {
            'Level': '$level',
            'Gems': '${world.gemsTaken}',
            'Lives left': '${math.max(0, world.lives)}',
            'Time': '${world.time.toStringAsFixed(1)}s',
          },
        ),
      );
    }
  }

  // ------------------------------------------------------------------ 3D
  static const Color _flatColor = Color(0xFF5E6AD2);
  static const Color _narrowColor = Color(0xFFFF8A3D);
  static const Color _rampColor = Color(0xFFFFC145);
  static const Color _checkColor = Color(0xFF3DDC97);
  static const Color _finishA = Color(0xFFF5F5F5);
  static const Color _finishB = Color(0xFF222222);

  Node? _ball;
  final List<Node> _hazardNodes = [];
  final List<Node> _gemNodes = [];
  bool _gemsDirty = true;

  static vm.Vector4 _v4(Color c) => vm.Vector4(c.r, c.g, c.b, 1);

  static PhysicallyBasedMaterial _mat(Color c, {double rough = 0.5, double metal = 0}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = _v4(c)
        ..roughnessFactor = rough
        ..metallicFactor = metal;

  Color _tileColor(TrackSegment s, int slice) => switch (s.kind) {
    SegmentKind.narrow => _narrowColor,
    SegmentKind.ramp => _rampColor,
    SegmentKind.checkpoint => _checkColor,
    SegmentKind.finish => slice.isEven ? _finishA : _finishB,
    _ => slice.isEven ? _flatColor : Color.lerp(_flatColor, Colors.white, 0.12)!,
  };

  @override
  void buildScene(Scene scene) {
    applyGradientSky(scene, zenith: vm.Vector3(0.18, 0.42, 0.95), horizon: vm.Vector3(0.85, 0.75, 0.98));
    final tiles = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(1, 0.5, 1)),
      material: _mat(Colors.white, rough: 0.55),
    );
    for (final s in world.segments) {
      if (!s.hasFloor) continue;
      final slices = s.length.ceil();
      for (var i = 0; i < slices; i++) {
        final dz = s.length / slices;
        final z = s.z0 + (i + 0.5) * dz;
        final h = s.heightAt(z);
        // Yaw each tile along the curve so bends read smoothly.
        final slope = (s.centerAt(z + dz / 2) - s.centerAt(z - dz / 2)) / dz;
        final yaw = math.atan(slope);
        final m = vm.Matrix4.identity()
          ..setTranslationRaw(s.centerAt(z), h - 0.25, z)
          ..rotateY(yaw)
          ..scaleByVector3(vm.Vector3(s.width, 1, dz / math.cos(yaw) + 0.04));
        tiles.addInstance(m, color: _v4(_tileColor(s, i)));
      }
    }
    scene.add(Node()..addComponent(InstancedMeshComponent(tiles)));
    final hazardMat = _mat(const Color(0xFFFF3B5C), rough: 0.35, metal: 0.2);
    final postMat = _mat(const Color(0xFFDDE1F0), rough: 0.3, metal: 0.6);
    for (final h in world.hazards) {
      final n = Node()..position = vm.Vector3(h.x, 0, h.z);
      switch (h.kind) {
        case HazardKind.sweeper:
          n.add(
            Node(mesh: Mesh(CylinderGeometry(bottomRadius: 0.2, topRadius: 0.2, height: 1.2), postMat))
              ..position = vm.Vector3(0, 0.6, 0),
          );
          n.add(
            Node(mesh: Mesh(CuboidGeometry(vm.Vector3(h.size * 2, 0.35, 0.35)), hazardMat))
              ..position = vm.Vector3(0, 0.5, 0),
          );
        case HazardKind.pusher:
          n.add(
            Node(mesh: Mesh(CuboidGeometry(vm.Vector3(1.4, 1.0, 1.0)), hazardMat))
              ..position = vm.Vector3(0, 0.5, 0),
          );
        case HazardKind.bumper:
          n.add(
            Node(
              mesh: Mesh(
                CylinderGeometry(bottomRadius: h.size, topRadius: h.size * 0.8, height: 0.9),
                hazardMat,
              ),
            )..position = vm.Vector3(0, 0.45, 0),
          );
      }
      _hazardNodes.add(n);
      scene.add(n);
    }
    final gemMat = _mat(const Color(0xFF7CF5FF), rough: 0.1, metal: 0.3)
      ..emissiveFactor = vm.Vector4(0.1, 0.5, 0.6, 1);
    for (final g in world.gems) {
      final n = Node(mesh: Mesh(CuboidGeometry(vm.Vector3(0.45, 0.45, 0.45)), gemMat))
        ..position = vm.Vector3(g.x, 0.8, g.z);
      _gemNodes.add(n);
      scene.add(n);
    }
    _ball = Node(
      mesh: Mesh(SphereGeometry(radius: RidgeWorld.ballRadius), _mat(const Color(0xFFFF5FA2), rough: 0.3)),
    );
    // A stripe makes the roll visible.
    _ball!.add(
      Node(
        mesh: Mesh(
          TorusGeometry(radius: RidgeWorld.ballRadius * 0.99, tubeRadius: 0.06),
          _mat(Colors.white, rough: 0.4),
        ),
      )..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), math.pi / 2),
    );
    scene.add(_ball!);
    syncScene();
  }

  @override
  void syncScene() {
    _ball
      ?..position = vm.Vector3(world.x, world.y, world.z)
      ..rotation = vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), world.roll);
    for (var i = 0; i < _hazardNodes.length; i++) {
      final h = world.hazards[i];
      final n = _hazardNodes[i];
      switch (h.kind) {
        case HazardKind.sweeper:
          n.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), -h.state);
        case HazardKind.pusher:
          n.position = vm.Vector3(h.x + h.state, 0, h.z);
        case HazardKind.bumper:
          break;
      }
    }
    if (_gemsDirty) {
      _gemsDirty = false;
      for (var i = 0; i < _gemNodes.length; i++) {
        final g = world.gems[i];
        _gemNodes[i]
          ..visible = !g.taken
          ..rotation = vm.Quaternion.axisAngle(vm.Vector3(0.3, 1, 0.2).normalized(), world.time * 2 + i);
      }
    }
  }

  // ------------------------------------------------------------------ fallback
  final Paint _p = Paint();

  @override
  void paintFallback(Canvas canvas, Size size, Projector pr) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      _p
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF8EC5FF), Color(0xFFE0C3FC)],
        ).createShader(rect),
    );
    _p.shader = null;
    // Track slices from far to near.
    final slices = <(double, TrackSegment, int)>[];
    for (final s in world.segments) {
      if (!s.hasFloor || s.z1 < world.z - 10 || s.z0 > world.z + 60) continue;
      final n = s.length.ceil();
      for (var i = 0; i < n; i++) {
        slices.add((s.z0 + i * s.length / n, s, i));
      }
    }
    slices.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (z, s, i) in slices) {
      final dz = s.length / s.length.ceil();
      final c0 = s.centerAt(z), c1 = s.centerAt(z + dz);
      final h0 = s.heightAt(z), h1 = s.heightAt(z + dz);
      final pts = [
        pr.projectXYZ(c0 - s.width / 2, h0, z),
        pr.projectXYZ(c0 + s.width / 2, h0, z),
        pr.projectXYZ(c1 + s.width / 2, h1, z + dz),
        pr.projectXYZ(c1 - s.width / 2, h1, z + dz),
      ];
      if (pts.any((p) => p == null)) continue;
      _p.color = _tileColor(s, i);
      canvas.drawPath(Path()..addPolygon([for (final p in pts) p!], true), _p);
    }
    for (final h in world.hazards) {
      final hx = h.kind == HazardKind.pusher ? h.x + h.state : h.x;
      final c = pr.projectXYZ(hx, 0.5, h.z);
      if (c == null || h.z < world.z - 2) continue;
      final r = pr.scaleAt(vm.Vector3(hx, 0.5, h.z), h.kind == HazardKind.sweeper ? h.size : 0.7);
      _p.color = const Color(0xFFFF3B5C);
      if (h.kind == HazardKind.sweeper) {
        final a = pr.projectXYZ(h.x + math.cos(h.state) * h.size, 0.5, h.z + math.sin(h.state) * h.size);
        final b = pr.projectXYZ(h.x - math.cos(h.state) * h.size, 0.5, h.z - math.sin(h.state) * h.size);
        if (a != null && b != null) canvas.drawLine(a, b, _p..strokeWidth = math.max(3, r * 0.15));
      } else {
        canvas.drawRect(Rect.fromCenter(center: c, width: r * 2, height: r * 1.4), _p);
      }
    }
    for (final g in world.gems) {
      if (g.taken || g.z < world.z - 2) continue;
      final c = pr.projectXYZ(g.x, 0.8, g.z);
      if (c == null) continue;
      _p.color = const Color(0xFF7CF5FF);
      canvas.drawCircle(c, pr.scaleAt(vm.Vector3(g.x, 0.8, g.z), 0.25), _p);
    }
    final bc = pr.projectXYZ(world.x, world.y, world.z);
    if (bc != null) {
      _p.color = const Color(0xFFFF5FA2);
      canvas.drawCircle(bc, pr.scaleAt(vm.Vector3(world.x, world.y, world.z), RidgeWorld.ballRadius), _p);
    }
  }

  // ------------------------------------------------------------------ HUD
  @override
  void paintHud(Canvas canvas, Size size, Projector pr, EdgeInsets safe) {
    final top = safe.top + 14;
    CanvasText.draw(
      canvas,
      'LEVEL $level',
      Offset(size.width / 2, top),
      size: 18,
      align: Alignment.topCenter,
    );
    CanvasText.draw(
      canvas,
      '${world.gemsTaken}',
      Offset(size.width - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFF7CF5FF),
    );
    drawBar(
      canvas,
      Rect.fromLTWH(16, safe.top + 64, size.width - 32, 10),
      world.progress,
      const Color(0xFF8AC926),
    );
    for (var i = 0; i < RidgeWorld.startLives; i++) {
      canvas.drawCircle(
        Offset(22 + i * 22.0, safe.top + 92),
        8,
        Paint()..color = i < world.lives ? const Color(0xFFFF5FA2) : const Color(0x44FFFFFF),
      );
    }
    if (world.time < 3) {
      CanvasText.draw(
        canvas,
        'Drag sideways to steer',
        Offset(size.width / 2, size.height - safe.bottom - 40),
        size: 16,
        align: Alignment.center,
        weight: FontWeight.w800,
      );
    }
    if (_flash > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFFFF3B5C).withValues(alpha: _flash * 0.5),
      );
    }
    if (!gpuActive) {
      CanvasText.draw(
        canvas,
        '2.5D fallback renderer',
        Offset(size.width - 12, size.height - safe.bottom - 8),
        size: 9,
        align: Alignment.bottomRight,
        color: Colors.black38,
      );
    }
  }
}
