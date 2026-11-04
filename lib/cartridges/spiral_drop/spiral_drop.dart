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
import 'spiral_world.dart';

class SpiralDropCartridge extends SceneCartridge<SpiralDropGame> {
  const SpiralDropCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'spiral-drop',
    title: 'Spiral Drop',
    tagline: 'Twist the tower. Find the gap. Fall in style.',
    description:
        'A bouncing ball sits in front of a tall spiral tower. Drag to twist the tower so the '
        'ball drops through the gaps in each ring. Red segments are deadly, but fall through '
        'three rings without bouncing and the ball blazes, smashing the next ring it lands on.',
    genre: 'Tower descent',
    engine: CartridgeEngine.scene3d,
    version: '1.0.0',
    accent: Color(0xFFFF8A3D),
    icon: Icons.cyclone_rounded,
    tags: ['3d', 'helix', 'one-thumb', 'hyper-casual'],
    controls: ['Drag left/right to rotate the tower'],
    mechanics: ['tower rotation', 'gap falling', 'hazard segments', 'blaze combo'],
    goal: 'Reach the bottom platform without landing on a red segment.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  SpiralDropGame createGame(SceneCartridgeSession<SpiralDropGame> session) => SpiralDropGame(session);
}

class SpiralDropGame extends SceneGame {
  SpiralDropGame(super.session, {int? seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      world = SpiralWorld(
        level: math.max(1, session.context.save.intData('level', 1)),
        seed: seed ?? DateTime.now().millisecondsSinceEpoch,
      ) {
    _camY = world.ballY;
  }

  final int level;
  final SpiralWorld world;
  bool _reported = false;
  double _camY = 0;
  double? _lastX;
  double _hint = 4;
  double _flash = 0;

  static const Color _solid = Color(0xFF6C7BFF);
  static const Color _solidAlt = Color(0xFF8E9BFF);
  static const Color _hazard = Color(0xFFFF3B5C);
  static const Color _finish = Color(0xFF3DDC97);
  static const Color _ball = Color(0xFFFF8A3D);

  @override
  SceneCameraSpec camera(Size size) => SceneCameraSpec(
    eye: vm.Vector3(0, _camY + 5.2, -9.5),
    target: vm.Vector3(0, _camY - 2.2, 0),
    fovY: 0.85,
  );

  @override
  int get entityCount => world.entityCount;

  @override
  void pointerDown(Offset p, Size size) {
    _lastX = p.dx;
    _hint = 0;
  }

  @override
  void pointerMove(Offset p, Size size) {
    final last = _lastX;
    if (last == null) return;
    // Dragging right spins the front of the tower to the right (world +X).
    world.rotate((p.dx - last) / size.width * 2 * math.pi * 0.9);
    _lastX = p.dx;
  }

  @override
  void pointerUp(Offset p, Size size) => _lastX = null;

  @override
  void update(double dt) {
    world.update(dt);
    // Camera follows the ball down, never back up.
    final target = math.min(_camY, world.ballY);
    _camY += (target - _camY) * math.min(1, dt * 6);
    if (_hint > 0) _hint -= dt;
    if (_flash > 0) _flash -= dt;
    for (final e in world.events) {
      switch (e.kind) {
        case SpiralEventKind.bounce:
          audio.play(Sfx.tap);
        case SpiralEventKind.pass:
          audio.play(e.combo >= SpiralWorld.blazeCombo ? Sfx.powerup : Sfx.whoosh);
        case SpiralEventKind.smash:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.heavy);
          _flash = 0.25;
          _dirtyRings = true;
        case SpiralEventKind.hazard:
          audio.haptic(HapticKind.heavy);
        case SpiralEventKind.finish:
          audio.haptic(HapticKind.medium);
      }
      if (e.kind == SpiralEventKind.pass) _dirtyRings = true;
    }
    if (world.isOver && !_reported) {
      _reported = true;
      final won = world.phase == SpiralPhase.won;
      if (won) {
        session.context.save.data['level'] = level + 1;
        session.context.commitSave();
      }
      finish(
        RunResult(
          score: world.score,
          won: won,
          headline: won
              ? 'Tower $level conquered! Level ${level + 1} unlocked.'
              : 'Hit a red segment on ring ${world.ringsPassed + 1} of ${world.ringCount}.',
          details: {
            'Level': '$level',
            'Rings passed': '${world.ringsPassed}/${world.ringCount}',
            'Blaze smashes': '${world.smashes}',
          },
        ),
      );
    }
  }

  // ------------------------------------------------------------------ 3D
  final Node _tower = Node();
  Node? _ballNode;
  InstancedMesh? _segments;
  bool _dirtyRings = false;

  /// Instance index → (ring, segment).
  final List<(int, int)> _instanceMap = [];

  static vm.Vector4 _v4(Color c) => vm.Vector4(c.r, c.g, c.b, 1);

  static PhysicallyBasedMaterial _mat(Color c, {double rough = 0.5, double metal = 0}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = _v4(c)
        ..roughnessFactor = rough
        ..metallicFactor = metal;

  /// Builds one annular sector slab spanning [SpiralWorld.segmentArc].
  static Geometry _sectorGeometry() {
    const r0 = SpiralWorld.innerRadius, r1 = SpiralWorld.outerRadius;
    const h = SpiralWorld.ringThickness / 2;
    const steps = 6;
    final arc = SpiralWorld.segmentArc * 0.985; // hairline seam between segments
    vm.Vector3 p(double phi, double r, double y) => vm.Vector3(math.sin(phi) * r, y, -math.cos(phi) * r);
    final b = GeometryBuilder(deduplicate: false);
    void quad(vm.Vector3 a, vm.Vector3 bb, vm.Vector3 c, vm.Vector3 d, vm.Vector3 n) {
      b.normal(n);
      final ia = b.addVertex(a), ib = b.addVertex(bb), ic = b.addVertex(c), id = b.addVertex(d);
      // Orient triangles so the right-handed face normal matches n (CCW front faces).
      final face = (bb - a).cross(c - a);
      if (face.dot(n) >= 0) {
        b
          ..addTriangle(ia, ib, ic)
          ..addTriangle(ia, ic, id);
      } else {
        b
          ..addTriangle(ia, ic, ib)
          ..addTriangle(ia, id, ic);
      }
    }

    for (var i = 0; i < steps; i++) {
      final a0 = arc * i / steps, a1 = arc * (i + 1) / steps;
      final mid = (a0 + a1) / 2;
      final out = vm.Vector3(math.sin(mid), 0, -math.cos(mid));
      quad(p(a0, r0, h), p(a0, r1, h), p(a1, r1, h), p(a1, r0, h), vm.Vector3(0, 1, 0));
      quad(p(a0, r0, -h), p(a1, r0, -h), p(a1, r1, -h), p(a0, r1, -h), vm.Vector3(0, -1, 0));
      quad(p(a0, r1, -h), p(a1, r1, -h), p(a1, r1, h), p(a0, r1, h), out);
      quad(p(a0, r0, -h), p(a0, r0, h), p(a1, r0, h), p(a1, r0, -h), -out);
    }
    final s0 = vm.Vector3(-1, 0, 0); // side normal at phi = 0 is −X
    quad(p(0, r0, -h), p(0, r1, -h), p(0, r1, h), p(0, r0, h), s0);
    final s1 = vm.Vector3(math.cos(arc), 0, math.sin(arc));
    quad(p(arc, r0, -h), p(arc, r0, h), p(arc, r1, h), p(arc, r1, -h), s1);
    return b.build();
  }

  vm.Vector4 _segColor(Ring r, SegKind k, int s) {
    if (r.finish) return _v4(_finish);
    if (k == SegKind.hazard) return _v4(_hazard);
    return _v4(s.isEven ? _solid : _solidAlt);
  }

  @override
  void buildScene(Scene scene) {
    final last = world.rings.last.y;
    const pillarTop = 1.2;
    final pillarHeight = pillarTop - last + 1;
    _tower.add(
      Node(
        mesh: Mesh(
          CylinderGeometry(
            bottomRadius: SpiralWorld.innerRadius,
            topRadius: SpiralWorld.innerRadius,
            height: pillarHeight,
            radialSegments: 32,
          ),
          _mat(const Color(0xFFE9ECF8), rough: 0.35),
        ),
      )..position = vm.Vector3(0, pillarTop - pillarHeight / 2, 0),
    );
    _segments = InstancedMesh(geometry: _sectorGeometry(), material: _mat(Colors.white, rough: 0.4));
    for (final ring in world.rings) {
      for (var s = 0; s < SpiralWorld.segmentsPerRing; s++) {
        final kind = ring.segments[s];
        if (kind == SegKind.gap) continue;
        final m = vm.Matrix4.identity()
          ..setTranslationRaw(0, ring.y, 0)
          ..rotateY(-s * SpiralWorld.segmentArc);
        _segments!.addInstance(m, color: _segColor(ring, kind, s));
        _instanceMap.add((ring.index, s));
      }
    }
    _tower.add(Node()..addComponent(InstancedMeshComponent(_segments!)));
    scene.add(_tower);
    _ballNode = Node(mesh: Mesh(SphereGeometry(radius: SpiralWorld.ballRadius), _mat(_ball, rough: 0.25)));
    scene.add(_ballNode!);
    syncScene();
  }

  @override
  void syncScene() {
    // Positive tower angle turns the tower counter-clockwise seen from above.
    _tower.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), -world.towerAngle);
    _ballNode?.position = vm.Vector3(0, world.ballY, -SpiralWorld.ballOrbit);
    final blaze = world.blazing;
    _ballNode?.scale = vm.Vector3.all(blaze ? 1.25 : 1);
    if (_dirtyRings) {
      _dirtyRings = false;
      _segments?.updateInstanceTransforms((list) {
        for (var i = 0; i < list.length; i++) {
          final (ri, _) = _instanceMap[i];
          if (world.rings[ri].passed) list[i].setZero();
        }
      });
    }
  }

  // ------------------------------------------------------------------ 2.5D fallback
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
          colors: [Color(0xFF1C1F3F), Color(0xFF0B0C15)],
        ).createShader(rect),
    );
    _p.shader = null;
    // Pillar.
    final topC = pr.projectXYZ(0, _camY + 6, 0), botC = pr.projectXYZ(0, _camY - 14, 0);
    if (topC != null && botC != null) {
      final w = pr.scaleAt(vm.Vector3(0, _camY - 2, 0), SpiralWorld.innerRadius);
      _p.color = const Color(0xFFD9DDEE);
      canvas.drawRect(Rect.fromLTRB(topC.dx - w, topC.dy, botC.dx + w, botC.dy), _p);
    }
    // Rings from lowest (farthest from camera) to highest, back segments first.
    final visible = world.rings
        .where((r) => !r.passed && r.y < _camY + 5 && r.y > _camY - 16)
        .toList()
        .reversed;
    for (final ring in visible) {
      final order = List<int>.generate(SpiralWorld.segmentsPerRing, (i) => i)
        ..sort((a, b) => _segDepth(ring, b, pr).compareTo(_segDepth(ring, a, pr)));
      for (final s in order) {
        final k = ring.segments[s];
        if (k == SegKind.gap) continue;
        final c = _segColor(ring, k, s);
        _p.color = Color.from(alpha: 1, red: c.x, green: c.y, blue: c.z);
        canvas.drawPath(_segPath(ring, s, pr), _p);
      }
    }
    // Ball.
    final ballC = pr.projectXYZ(0, world.ballY, -SpiralWorld.ballOrbit);
    if (ballC != null) {
      final r = pr.scaleAt(vm.Vector3(0, world.ballY, -SpiralWorld.ballOrbit), SpiralWorld.ballRadius);
      _p.color = world.blazing ? const Color(0xFFFFD166) : _ball;
      canvas.drawCircle(ballC, r * (world.blazing ? 1.25 : 1), _p);
    }
  }

  double _segDepth(Ring ring, int s, Projector pr) {
    final phi = (s + 0.5) * SpiralWorld.segmentArc + world.towerAngle;
    return pr.depth(vm.Vector3(math.sin(phi) * 1.5, ring.y, -math.cos(phi) * 1.5));
  }

  Path _segPath(Ring ring, int s, Projector pr) {
    final path = Path();
    const steps = 4;
    final a0 = s * SpiralWorld.segmentArc + world.towerAngle;
    final a1 = a0 + SpiralWorld.segmentArc * 0.97;
    final y = ring.y + SpiralWorld.ringThickness / 2;
    var first = true;
    void pt(double phi, double r) {
      final o = pr.projectXYZ(math.sin(phi) * r, y, -math.cos(phi) * r);
      if (o == null) return;
      if (first) {
        path.moveTo(o.dx, o.dy);
        first = false;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }

    for (var i = 0; i <= steps; i++) {
      pt(a0 + (a1 - a0) * i / steps, SpiralWorld.outerRadius);
    }
    for (var i = steps; i >= 0; i--) {
      pt(a0 + (a1 - a0) * i / steps, SpiralWorld.innerRadius);
    }
    return path..close();
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
      '${world.score}',
      Offset(size.width - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
    );
    drawBar(canvas, Rect.fromLTWH(16, safe.top + 64, size.width - 32, 10), world.progress, _ball);
    CanvasText.draw(
      canvas,
      '${world.ringsPassed}/${world.ringCount} rings',
      Offset(size.width / 2, safe.top + 78),
      size: 11,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
    if (world.combo >= 2) {
      CanvasText.draw(
        canvas,
        world.blazing ? 'BLAZE ×${world.combo}!' : 'COMBO ×${world.combo}',
        Offset(size.width / 2, size.height * 0.28),
        size: world.blazing ? 30 : 22,
        align: Alignment.center,
        color: world.blazing ? const Color(0xFFFFD166) : Colors.white,
        weight: FontWeight.w900,
      );
    }
    if (_flash > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Colors.white.withValues(alpha: (_flash / 0.25) * 0.35),
      );
    }
    if (_hint > 0) {
      CanvasText.draw(
        canvas,
        'Drag sideways to twist the tower',
        Offset(size.width / 2, size.height - safe.bottom - 40),
        size: 16,
        align: Alignment.center,
        weight: FontWeight.w800,
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
