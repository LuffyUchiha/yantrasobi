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
import 'mob_world.dart';

class MobMagnetCartridge extends SceneCartridge<MobMagnetGame> {
  const MobMagnetCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'mob-magnet',
    title: 'Mob Magnet',
    tagline: 'Touch a stranger, gain a follower. Grow the biggest mob.',
    description:
        'A 3D city crowd brawl. Steer your leader through the streets: every idle citizen you '
        'touch joins your mob. Bigger mobs swallow smaller ones on contact, so grow fast, steer '
        'clear of larger rivals and run down the small ones. Be the biggest crowd when the '
        'clock runs out.',
    genre: 'Crowd collector',
    engine: CartridgeEngine.scene3d,
    version: '1.0.0',
    accent: Color(0xFF00C2A8),
    icon: Icons.diversity_3_rounded,
    tags: ['3d', 'crowd', 'io', 'city'],
    controls: ['Drag anywhere: joystick to steer your leader'],
    mechanics: ['recruiting', 'crowd absorption', 'rival mobs', 'timer'],
    goal: 'Have the largest mob after 75 seconds, or absorb every rival leader.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  MobMagnetGame createGame(SceneCartridgeSession<MobMagnetGame> session) => MobMagnetGame(session);
}

class MobMagnetGame extends SceneGame {
  MobMagnetGame(super.session, {int? seed})
    : world = MobWorld(seed: seed ?? DateTime.now().millisecondsSinceEpoch);

  final MobWorld world;
  bool _reported = false;
  Offset? _stickOrigin;
  Offset? _stickKnob;
  double _camX = MobWorld.size / 2, _camZ = MobWorld.size / 2, _camH = 30;

  static const List<Color> teamColors = [
    Color(0xFFB8BCCB), // neutral
    Color(0xFF00C2A8), // player
    Color(0xFFFF5A5F),
    Color(0xFFFFB627),
    Color(0xFFB57BFF),
  ];
  static const List<String> teamNames = ['', 'You', 'Coral', 'Amber', 'Violet'];

  @override
  int get entityCount => world.entityCount;

  @override
  SceneCameraSpec camera(Size size) => SceneCameraSpec(
    eye: vm.Vector3(_camX, _camH, _camZ - _camH * 0.55),
    target: vm.Vector3(_camX, 0, _camZ + 2),
    fovY: 0.9,
  );

  // ------------------------------------------------------------- input
  static const double _stickRadius = 56;

  @override
  void pointerDown(Offset p, Size size) {
    _stickOrigin = p;
    _stickKnob = p;
  }

  @override
  void pointerMove(Offset p, Size size) {
    final o = _stickOrigin;
    if (o == null) return;
    var d = p - o;
    if (d.distance > _stickRadius) d = d / d.distance * _stickRadius;
    _stickKnob = o + d;
    // Screen right = world +X; screen up = world +Z (camera looks along +Z).
    world.inputX = d.dx / _stickRadius;
    world.inputZ = -d.dy / _stickRadius;
  }

  @override
  void pointerUp(Offset p, Size size) {
    _stickOrigin = null;
    _stickKnob = null;
    world.inputX = 0;
    world.inputZ = 0;
  }

  // ------------------------------------------------------------- rules
  @override
  void update(double dt) {
    world.update(dt);
    final l = world.player.leader;
    final k = math.min(1.0, dt * 4);
    _camX += (l.x - _camX) * k;
    _camZ += (l.z - _camZ) * k;
    final targetH = 28 + math.sqrt(world.player.size) * 1.4;
    _camH += (targetH - _camH) * math.min(1.0, dt);
    var recruited = false;
    for (final e in world.events) {
      switch (e.kind) {
        case MobEventKind.recruit:
          if (e.team == 1) recruited = true;
        case MobEventKind.absorb:
          if (e.team == 1) recruited = true;
        case MobEventKind.eliminated:
          audio.play(Sfx.powerup);
          audio.haptic(HapticKind.medium);
        case MobEventKind.playerEliminated:
          audio.haptic(HapticKind.heavy);
      }
    }
    if (recruited) audio.play(Sfx.pop);
    if (world.isOver && !_reported) {
      _reported = true;
      final won = world.phase == MobPhase.won;
      finish(
        RunResult(
          score: world.score,
          won: won,
          headline: won
              ? 'Biggest mob in town: ${world.player.size} strong!'
              : (world.player.alive ? 'Finished rank #${world.rank}.' : 'Your leader was swallowed.'),
          details: {
            'Mob size': '${world.player.size}',
            'Rank': '#${world.rank}',
            'Absorbed': '${world.player.absorbed}',
            'Rivals left': '${world.teams.skip(2).where((t) => t.alive).length}',
          },
        ),
      );
    }
  }

  // ------------------------------------------------------------- 3D
  InstancedMesh? _crowd;
  final List<int> _shownTeam = [];
  final vm.Vector3 _t = vm.Vector3.zero();
  final vm.Vector3 _s = vm.Vector3.zero();
  final vm.Quaternion _q = vm.Quaternion.identity();

  static vm.Vector4 _v4(Color c) => vm.Vector4(c.r, c.g, c.b, 1);

  static PhysicallyBasedMaterial _mat(Color c, {double rough = 0.7}) => PhysicallyBasedMaterial()
    ..baseColorFactor = _v4(c)
    ..roughnessFactor = rough
    ..metallicFactor = 0;

  static const List<Color> _buildingColors = [
    Color(0xFF3A4170),
    Color(0xFF4A3F6B),
    Color(0xFF2F5568),
    Color(0xFF5A4B5E),
  ];

  @override
  void buildScene(Scene scene) {
    applyGradientSky(scene, zenith: vm.Vector3(0.05, 0.08, 0.22), horizon: vm.Vector3(0.40, 0.55, 0.75));
    const s = MobWorld.size;
    scene.add(
      Node(mesh: Mesh(CuboidGeometry(vm.Vector3(s + 120, 0.2, s + 120)), _mat(const Color(0xFF23263D))))
        ..position = vm.Vector3(s / 2, -0.1, s / 2),
    );
    final mats = [for (final c in _buildingColors) _mat(c, rough: 0.55)];
    for (var i = 0; i < world.buildings.length; i++) {
      final b = world.buildings[i];
      scene.add(
        Node(
          mesh: Mesh(CuboidGeometry(vm.Vector3(b.x1 - b.x0, b.height, b.z1 - b.z0)), mats[i % mats.length]),
        )..position = vm.Vector3((b.x0 + b.x1) / 2, b.height / 2, (b.z0 + b.z1) / 2),
      );
    }
    _crowd = InstancedMesh(
      geometry: CapsuleGeometry(radius: 0.26, height: 0.9, radialSegments: 8, capRings: 3),
      material: _mat(Colors.white, rough: 0.45),
    );
    final hidden = vm.Matrix4.zero();
    for (var i = 0; i < MobWorld.maxPeople; i++) {
      _crowd!.addInstance(hidden, color: _v4(teamColors[0]));
      _shownTeam.add(0);
    }
    scene.add(Node()..addComponent(InstancedMeshComponent(_crowd!)));
    syncScene();
  }

  @override
  void syncScene() {
    final crowd = _crowd;
    if (crowd == null) return;
    final people = world.people;
    for (var i = 0; i < people.length && i < MobWorld.maxPeople; i++) {
      final team = people[i].team;
      if (_shownTeam[i] != team) {
        _shownTeam[i] = team;
        crowd.setInstanceColor(i, _v4(teamColors[team % teamColors.length]));
      }
    }
    crowd.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        if (i >= people.length) {
          list[i].setZero();
          continue;
        }
        final p = people[i];
        final sc = p.leader ? 1.6 : 1.0;
        _t.setValues(p.x, 0.7 * sc, p.z);
        _s.setValues(sc, sc, sc);
        list[i].setFromTranslationRotationScale(_t, _q, _s);
      }
    }, recomputeWinding: false);
  }

  // ------------------------------------------------------------- fallback
  final Paint _p = Paint();

  Path _quad(Projector pr, List<(double, double, double)> pts) {
    final path = Path();
    var first = true;
    for (final (x, y, z) in pts) {
      final o = pr.projectXYZ(x, y, z);
      if (o == null) continue;
      if (first) {
        path.moveTo(o.dx, o.dy);
        first = false;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    return path..close();
  }

  @override
  void paintFallback(Canvas canvas, Size size, Projector pr) {
    canvas.drawRect(Offset.zero & size, _p..color = const Color(0xFF0E1020));
    const s = MobWorld.size;
    _p.color = const Color(0xFF23263D);
    canvas.drawPath(_quad(pr, [(-60, 0, -60), (s + 60, 0, -60), (s + 60, 0, s + 60), (-60, 0, s + 60)]), _p);
    final items = <(double, VoidCallback)>[];
    for (var i = 0; i < world.buildings.length; i++) {
      final b = world.buildings[i];
      if ((b.x0 - _camX).abs() > 45 || (b.z0 - _camZ).abs() > 60) continue;
      final color = _buildingColors[i % _buildingColors.length];
      items.add((
        pr.depth(vm.Vector3((b.x0 + b.x1) / 2, 0, b.z0)),
        () {
          _p.color = color;
          canvas.drawPath(
            _quad(pr, [(b.x0, 0, b.z0), (b.x1, 0, b.z0), (b.x1, b.height, b.z0), (b.x0, b.height, b.z0)]),
            _p,
          );
          _p.color = Color.lerp(color, Colors.white, 0.18)!;
          canvas.drawPath(
            _quad(pr, [
              (b.x0, b.height, b.z0),
              (b.x1, b.height, b.z0),
              (b.x1, b.height, b.z1),
              (b.x0, b.height, b.z1),
            ]),
            _p,
          );
        },
      ));
    }
    for (final p in world.people) {
      if ((p.x - _camX).abs() > 40 || (p.z - _camZ).abs() > 55) continue;
      items.add((
        pr.depth(vm.Vector3(p.x, 0, p.z)),
        () {
          final sc = p.leader ? 1.6 : 1.0;
          final c = pr.projectXYZ(p.x, 0.7 * sc, p.z);
          if (c == null) return;
          final r = pr.scaleAt(vm.Vector3(p.x, 0.7, p.z), 0.26 * sc);
          _p.color = teamColors[p.team % teamColors.length];
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: c, width: r * 2, height: r * 5),
              Radius.circular(r),
            ),
            _p,
          );
        },
      ));
    }
    items.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, paint) in items) {
      paint();
    }
  }

  // ------------------------------------------------------------- HUD
  @override
  void paintHud(Canvas canvas, Size size, Projector pr, EdgeInsets safe) {
    final top = safe.top + 14;
    final t = world.timeLeft.ceil();
    CanvasText.draw(
      canvas,
      '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}',
      Offset(size.width / 2, top),
      size: 22,
      align: Alignment.topCenter,
      color: t <= 10 ? const Color(0xFFFF6B6B) : Colors.white,
    );
    CanvasText.draw(
      canvas,
      '${world.player.size}',
      Offset(size.width - 16, top),
      size: 24,
      align: Alignment.topRight,
      color: teamColors[1],
      weight: FontWeight.w900,
    );
    // Leaderboard.
    final ranked = world.teams.skip(1).where((t) => t.alive).toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    var y = safe.top + 60.0;
    for (var i = 0; i < ranked.length; i++) {
      final team = ranked[i];
      CanvasText.draw(
        canvas,
        '${i + 1}. ${teamNames[team.id]}  ${team.size}',
        Offset(16, y),
        size: 13,
        color: teamColors[team.id % teamColors.length],
        weight: team.id == 1 ? FontWeight.w900 : FontWeight.w600,
      );
      y += 17;
    }
    // Rival labels over leaders.
    for (final team in world.teams.skip(2)) {
      if (!team.alive) continue;
      final o = pr.projectXYZ(team.leader.x, 2.4, team.leader.z);
      if (o == null || o.dx < 0 || o.dx > size.width || o.dy < 0 || o.dy > size.height) continue;
      CanvasText.draw(
        canvas,
        '${teamNames[team.id]} ${team.size}',
        o,
        size: 12,
        align: Alignment.bottomCenter,
        color: teamColors[team.id % teamColors.length],
      );
    }
    final o = _stickOrigin, k = _stickKnob;
    if (o != null && k != null) {
      canvas.drawCircle(o, _stickRadius, Paint()..color = const Color(0x22FFFFFF));
      canvas.drawCircle(k, 24, Paint()..color = const Color(0x66FFFFFF));
    }
    if (world.time < 3.5) {
      CanvasText.draw(
        canvas,
        'Drag to steer · touch grey citizens to recruit',
        Offset(size.width / 2, size.height - safe.bottom - 40),
        size: 14,
        align: Alignment.center,
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
