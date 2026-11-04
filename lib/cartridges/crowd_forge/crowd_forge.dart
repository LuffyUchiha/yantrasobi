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
import 'crowd_world.dart';

class CrowdForgeCartridge extends SceneCartridge<CrowdForgeGame> {
  const CrowdForgeCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'crowd-forge',
    title: 'Crowd Forge',
    tagline: 'Fire a stream. Multiply it. Flatten the forge.',
    description:
        'A 3D crowd launcher. Hold to pour little blue runners from your launcher, slide to '
        'steer them through multiplier gates, and swamp the red horde before it reaches you. '
        'Every 45 shots you launch a champion. Destroy the enemy forge to move up a level.',
    genre: 'Crowd launcher',
    engine: CartridgeEngine.scene3d,
    version: '1.0.0',
    accent: Color(0xFF4EA8FF),
    icon: Icons.groups_rounded,
    tags: ['3d', 'crowd', 'multiplier', 'hyper-casual'],
    controls: ['Hold anywhere to fire', 'Slide left/right to aim the launcher'],
    mechanics: ['multiplier gates', 'crowd combat', 'champion meter', 'levels'],
    goal: 'Knock the enemy forge HP to zero before 20 red runners breach your base.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  CrowdForgeGame createGame(SceneCartridgeSession<CrowdForgeGame> session) => CrowdForgeGame(session);
}

class CrowdForgeGame extends SceneGame {
  CrowdForgeGame(super.session, {int? seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      world = CrowdWorld(
        level: math.max(1, session.context.save.intData('level', 1)),
        seed: seed ?? DateTime.now().millisecondsSinceEpoch,
      );

  final int level;
  final CrowdWorld world;
  bool _reported = false;
  double _hintTimer = 4;

  static final SceneCameraSpec _camera = SceneCameraSpec(
    eye: vm.Vector3(0, 13.5, -9),
    target: vm.Vector3(0, 0, 13),
    fovY: 0.95,
  );

  @override
  SceneCameraSpec camera(Size size) => _camera;

  @override
  int get entityCount => world.entityCount;

  // ---------------------------------------------------------------- input
  void _aimFrom(Offset p, Size size) => world.aim((p.dx / size.width) * 2.4 - 1.2);

  @override
  void pointerDown(Offset p, Size size) {
    _aimFrom(p, size);
    world.firing = true;
    _hintTimer = 0;
  }

  @override
  void pointerMove(Offset p, Size size) => _aimFrom(p, size);

  @override
  void pointerUp(Offset p, Size size) => world.firing = false;

  // ---------------------------------------------------------------- rules
  @override
  void update(double dt) {
    world.update(dt);
    if (_hintTimer > 0) _hintTimer -= dt;
    var clash = false, multiply = false, forge = false;
    for (final e in world.events) {
      switch (e.kind) {
        case CrowdEventKind.multiply:
          multiply = true;
        case CrowdEventKind.clash:
          clash = true;
        case CrowdEventKind.forgeHit:
          forge = true;
        case CrowdEventKind.breach:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.medium);
        case CrowdEventKind.champion:
          audio.play(Sfx.powerup);
        case CrowdEventKind.blade:
          audio.play(Sfx.thud);
        case CrowdEventKind.fire:
          break;
      }
    }
    if (multiply) audio.play(Sfx.coin);
    if (clash) audio.play(Sfx.pop);
    if (forge) audio.play(Sfx.thud);
    if (world.isOver && !_reported) {
      _reported = true;
      final won = world.phase == CrowdPhase.won;
      final save = session.context.save;
      if (won) {
        save.data['level'] = level + 1;
        session.context.commitSave();
      }
      finish(
        RunResult(
          score: world.score,
          won: won,
          headline: won ? 'Forge $level destroyed! Level ${level + 1} unlocked.' : 'Your base was overrun.',
          details: {
            'Level': '$level',
            'Runners fired': '${world.fired}',
            'Clones forged': '${world.clones}',
            'Foes defeated': '${world.foesDefeated}',
          },
        ),
      );
    }
  }

  // ---------------------------------------------------------------- 3D
  InstancedMesh? _unitMesh;
  InstancedMesh? _foeMesh;
  Node? _launcher;
  Node? _forge;
  final List<Node> _gateNodes = [];
  final List<Node> _bladeNodes = [];
  final vm.Vector3 _t = vm.Vector3.zero();
  final vm.Vector3 _s = vm.Vector3.zero();
  final vm.Quaternion _q = vm.Quaternion.identity();

  static PhysicallyBasedMaterial _mat(Color c, {double rough = 0.6, double metal = 0.0}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(c.r, c.g, c.b, 1)
        ..roughnessFactor = rough
        ..metallicFactor = metal;

  static Node _box(vm.Vector3 extents, Material m, vm.Vector3 at) =>
      Node(mesh: Mesh(CuboidGeometry(extents), m))..position = at;

  @override
  void buildScene(Scene scene) {
    const lw = CrowdWorld.laneHalfWidth;
    const fz = CrowdWorld.forgeZ;
    scene.add(
      _box(vm.Vector3(lw * 2, 0.2, fz + 6), _mat(const Color(0xFF2B3050)), vm.Vector3(0, -0.1, fz / 2)),
    );
    final rail = _mat(const Color(0xFF8C93C8), rough: 0.3, metal: 0.4);
    for (final side in [-1.0, 1.0]) {
      scene.add(_box(vm.Vector3(0.3, 0.5, fz + 6), rail, vm.Vector3(side * (lw + 0.15), 0.15, fz / 2)));
    }
    // Lane stripes (abutting tiles, no overlaps).
    final stripe = _mat(const Color(0xFF353B63));
    for (var z = 2.0; z < fz; z += 4) {
      scene.add(_box(vm.Vector3(0.12, 0.02, 2), stripe, vm.Vector3(0, 0.01, z)));
    }
    _launcher = Node(mesh: Mesh(CuboidGeometry(vm.Vector3(1.4, 0.7, 1.1)), _mat(const Color(0xFF4EA8FF))));
    final barrel =
        Node(
            mesh: Mesh(
              CylinderGeometry(bottomRadius: 0.28, topRadius: 0.22, height: 1.0),
              _mat(const Color(0xFFDDE8FF), rough: 0.2, metal: 0.7),
            ),
          )
          ..position = vm.Vector3(0, 0.25, 0.55)
          ..rotation = vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2);
    _launcher!.add(barrel);
    scene.add(_launcher!);
    _forge = Node(mesh: Mesh(CuboidGeometry(vm.Vector3(lw * 2 - 0.6, 3, 1.6)), _mat(const Color(0xFFE5484D))))
      ..position = vm.Vector3(0, 1.5, fz + 0.3);
    scene.add(_forge!);
    final post = _mat(const Color(0xFF3DDCFF), rough: 0.25, metal: 0.2);
    for (final g in world.gates) {
      final n = Node()..position = vm.Vector3(g.x, 0, g.z);
      n.add(_box(vm.Vector3(0.18, 1.8, 0.18), post, vm.Vector3(-g.width / 2, 0.9, 0)));
      n.add(_box(vm.Vector3(0.18, 1.8, 0.18), post, vm.Vector3(g.width / 2, 0.9, 0)));
      n.add(_box(vm.Vector3(g.width + 0.18, 0.18, 0.18), post, vm.Vector3(0, 1.8, 0)));
      n.add(
        _box(vm.Vector3(g.width - 0.2, 0.03, 0.5), _mat(const Color(0xFF1D6E80)), vm.Vector3(0, 0.015, 0)),
      );
      _gateNodes.add(n);
      scene.add(n);
    }
    final bladeMat = _mat(const Color(0xFFC9CED6), rough: 0.15, metal: 0.9);
    for (final b in world.blades) {
      final n = Node(
        mesh: Mesh(CylinderGeometry(bottomRadius: b.radius, topRadius: b.radius, height: 0.12), bladeMat),
      )..position = vm.Vector3(b.x, 0.35, b.z);
      _bladeNodes.add(n);
      scene.add(n);
    }
    _unitMesh = InstancedMesh(
      geometry: CapsuleGeometry(radius: 0.2, height: 0.75, radialSegments: 10, capRings: 3),
      material: _mat(const Color(0xFF4EA8FF), rough: 0.45),
    );
    _foeMesh = InstancedMesh(
      geometry: CapsuleGeometry(radius: 0.22, height: 0.8, radialSegments: 10, capRings: 3),
      material: _mat(const Color(0xFFFF5A5F), rough: 0.45),
    );
    final hidden = vm.Matrix4.zero();
    for (var i = 0; i < CrowdWorld.maxUnits; i++) {
      _unitMesh!.addInstance(hidden);
    }
    for (var i = 0; i < CrowdWorld.maxFoes; i++) {
      _foeMesh!.addInstance(hidden);
    }
    scene.add(Node()..addComponent(InstancedMeshComponent(_unitMesh!)));
    scene.add(Node()..addComponent(InstancedMeshComponent(_foeMesh!)));
    syncScene();
  }

  void _place(vm.Matrix4 m, double x, double y, double z, double scale) {
    if (scale == 0) {
      m.setZero();
      return;
    }
    _t.setValues(x, y, z);
    _s.setValues(scale, scale, scale);
    m.setFromTranslationRotationScale(_t, _q, _s);
  }

  @override
  void syncScene() {
    _launcher?.position = vm.Vector3(world.launcherX, 0.35, 0);
    final hpFrac = world.forgeHp / world.forgeMaxHp;
    _forge?.scale = vm.Vector3(1, 0.25 + 0.75 * hpFrac, 1);
    _forge?.position = vm.Vector3(0, 1.5 * (0.25 + 0.75 * hpFrac), CrowdWorld.forgeZ + 0.3);
    for (var i = 0; i < _gateNodes.length; i++) {
      _gateNodes[i].position = vm.Vector3(world.gates[i].x, 0, world.gates[i].z);
    }
    for (var i = 0; i < _bladeNodes.length; i++) {
      final b = world.blades[i];
      _bladeNodes[i]
        ..position = vm.Vector3(b.x, 0.35, b.z)
        ..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), b.angle);
    }
    _unitMesh?.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        final u = world.units[i];
        _place(list[i], u.x, 0.55, u.z, u.alive ? (u.champion ? 2.2 : 1) : 0);
      }
    }, recomputeWinding: false);
    _foeMesh?.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        final f = world.foes[i];
        _place(list[i], f.x, 0.55, f.z, f.alive ? (f.brute ? 1.9 : 1) : 0);
      }
    }, recomputeWinding: false);
  }

  // ---------------------------------------------------------------- 2.5D fallback
  final Paint _p = Paint();

  Path _quad(Projector pr, List<List<double>> pts) {
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = pr.projectXYZ(pts[i][0], pts[i][1], pts[i][2]) ?? Offset.zero;
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    return path..close();
  }

  @override
  void paintFallback(Canvas canvas, Size size, Projector pr) {
    const lw = CrowdWorld.laneHalfWidth;
    const fz = CrowdWorld.forgeZ;
    canvas.drawRect(
      Offset.zero & size,
      _p
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF151833), Color(0xFF0B0C15)],
        ).createShader(Offset.zero & size),
    );
    _p.shader = null;
    _p.color = const Color(0xFF2B3050);
    canvas.drawPath(
      _quad(pr, [
        [-lw, 0, -3],
        [lw, 0, -3],
        [lw, 0, fz + 3],
        [-lw, 0, fz + 3],
      ]),
      _p,
    );
    _p.color = const Color(0xFF8C93C8);
    for (final side in [-1.0, 1.0]) {
      final x = side * (lw + 0.15);
      canvas.drawPath(
        _quad(pr, [
          [x - 0.15, 0.3, -3],
          [x + 0.15, 0.3, -3],
          [x + 0.15, 0.3, fz + 3],
          [x - 0.15, 0.3, fz + 3],
        ]),
        _p,
      );
    }
    _p.color = const Color(0xFF353B63);
    for (var z = 1.0; z < fz; z += 4) {
      canvas.drawPath(
        _quad(pr, [
          [-0.06, 0, z],
          [0.06, 0, z],
          [0.06, 0, z + 2],
          [-0.06, 0, z + 2],
        ]),
        _p,
      );
    }
    // Forge (drawn first: farthest).
    final hpFrac = world.forgeHp / world.forgeMaxHp;
    final h = 3 * (0.25 + 0.75 * hpFrac);
    _p.color = const Color(0xFFE5484D);
    canvas.drawPath(
      _quad(pr, [
        [-lw + 0.3, 0, fz],
        [lw - 0.3, 0, fz],
        [lw - 0.3, h, fz],
        [-lw + 0.3, h, fz],
      ]),
      _p,
    );
    // Depth-sorted actors: gates, blades, units, foes.
    final items = <_Drawable>[];
    for (final g in world.gates) {
      items.add(_Drawable(g.z, () => _paintGate(canvas, pr, g)));
    }
    for (final b in world.blades) {
      items.add(_Drawable(b.z, () => _paintBlade(canvas, pr, b)));
    }
    for (final u in world.units) {
      if (u.alive) {
        items.add(_Drawable(u.z, () => _paintActor(canvas, pr, u.x, u.z, u.champion ? 2.2 : 1, _unitColor)));
      }
    }
    for (final f in world.foes) {
      if (f.alive) {
        items.add(_Drawable(f.z, () => _paintActor(canvas, pr, f.x, f.z, f.brute ? 1.9 : 1, _foeColor)));
      }
    }
    items.sort((a, b) => b.z.compareTo(a.z));
    for (final d in items) {
      d.paint();
    }
    // Launcher (nearest).
    _p.color = const Color(0xFF4EA8FF);
    final lx = world.launcherX;
    canvas.drawPath(
      _quad(pr, [
        [lx - 0.7, 0, -0.5],
        [lx + 0.7, 0, -0.5],
        [lx + 0.7, 0.7, 0.2],
        [lx - 0.7, 0.7, 0.2],
      ]),
      _p,
    );
    _p.color = const Color(0xFFDDE8FF);
    final muzzle = pr.projectXYZ(lx, 0.6, 1.0);
    if (muzzle != null) canvas.drawCircle(muzzle, pr.scaleAt(vm.Vector3(lx, 0.6, 1), 0.3), _p);
  }

  static const Color _unitColor = Color(0xFF4EA8FF);
  static const Color _foeColor = Color(0xFFFF5A5F);

  void _paintActor(Canvas canvas, Projector pr, double x, double z, double scale, Color c) {
    final base = pr.projectXYZ(x, 0.55 * scale, z);
    if (base == null) return;
    final r = pr.scaleAt(vm.Vector3(x, 0.5, z), 0.22 * scale);
    _p.color = c;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: base, width: r * 2, height: r * 4.4),
        Radius.circular(r),
      ),
      _p,
    );
    _p.color = Colors.white.withValues(alpha: 0.35);
    canvas.drawCircle(base + Offset(-r * 0.3, -r * 1.2), r * 0.4, _p);
  }

  void _paintGate(Canvas canvas, Projector pr, Gate g) {
    _p.color = const Color(0x551D6E80);
    canvas.drawPath(
      _quad(pr, [
        [g.x - g.width / 2, 0, g.z],
        [g.x + g.width / 2, 0, g.z],
        [g.x + g.width / 2, 1.8, g.z],
        [g.x - g.width / 2, 1.8, g.z],
      ]),
      _p,
    );
    final stroke = Paint()
      ..color = const Color(0xFF3DDCFF)
      ..strokeWidth = math.max(2, pr.scaleAt(vm.Vector3(g.x, 0, g.z), 0.18))
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      _quad(pr, [
        [g.x - g.width / 2, 0, g.z],
        [g.x - g.width / 2, 1.8, g.z],
        [g.x + g.width / 2, 1.8, g.z],
        [g.x + g.width / 2, 0, g.z],
      ]),
      stroke,
    );
  }

  void _paintBlade(Canvas canvas, Projector pr, Blade b) {
    final c = pr.projectXYZ(b.x, 0.35, b.z);
    if (c == null) return;
    final r = pr.scaleAt(vm.Vector3(b.x, 0.35, b.z), b.radius);
    _p.color = const Color(0xFFC9CED6);
    canvas.drawOval(Rect.fromCenter(center: c, width: r * 2, height: r * 0.9), _p);
    _p.color = const Color(0xFF6B7280);
    final a = b.angle;
    canvas.drawLine(
      c + Offset(math.cos(a) * r, math.sin(a) * r * 0.45),
      c - Offset(math.cos(a) * r, math.sin(a) * r * 0.45),
      _p..strokeWidth = 2,
    );
  }

  // ---------------------------------------------------------------- HUD
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
      '${world.score}',
      Offset(size.width - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
    );
    final barTop = safe.top + 64;
    CanvasText.draw(canvas, 'FORGE', Offset(16, barTop - 2), size: 11, color: Colors.white70);
    drawBar(
      canvas,
      Rect.fromLTWH(64, barTop, size.width - 80, 10),
      world.forgeHp / world.forgeMaxHp,
      const Color(0xFFE5484D),
    );
    CanvasText.draw(canvas, 'BASE', Offset(16, barTop + 16), size: 11, color: Colors.white70);
    drawBar(
      canvas,
      Rect.fromLTWH(64, barTop + 18, size.width - 80, 10),
      world.baseHp / world.baseMaxHp,
      const Color(0xFF4EA8FF),
    );
    for (final g in world.gates) {
      final o = pr.projectXYZ(g.x, 2.4, g.z);
      if (o == null) continue;
      CanvasText.draw(
        canvas,
        '×${g.multiplier}',
        o,
        size: math.max(14, pr.scaleAt(vm.Vector3(g.x, 2.4, g.z), 0.9)),
        align: Alignment.center,
        color: const Color(0xFF7CF5FF),
        weight: FontWeight.w900,
      );
    }
    // Champion meter + counters.
    final bottom = size.height - safe.bottom - 28;
    drawBar(
      canvas,
      Rect.fromLTWH(size.width * 0.2, bottom, size.width * 0.6, 10),
      world.championProgress,
      const Color(0xFFFFD166),
    );
    CanvasText.draw(
      canvas,
      'CHAMPION',
      Offset(size.width / 2, bottom - 4),
      size: 11,
      align: Alignment.bottomCenter,
      color: Colors.white70,
    );
    CanvasText.draw(
      canvas,
      '${world.liveUnits} runners',
      Offset(16, bottom - 4),
      size: 12,
      align: Alignment.bottomLeft,
      color: const Color(0xFF9CCBFF),
    );
    if (_hintTimer > 0) {
      CanvasText.draw(
        canvas,
        'Hold to fire · slide to aim',
        Offset(size.width / 2, size.height * 0.55),
        size: 18,
        align: Alignment.center,
        weight: FontWeight.w800,
      );
    }
    if (!gpuActive) {
      CanvasText.draw(
        canvas,
        '2.5D fallback renderer',
        Offset(size.width - 12, bottom + 12),
        size: 9,
        align: Alignment.bottomRight,
        color: Colors.white30,
      );
    }
  }
}

class _Drawable {
  _Drawable(this.z, this.paint);
  final double z;
  final VoidCallback paint;
}
