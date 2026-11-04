import 'dart:math' as math;
import 'dart:ui';

import 'package:asobi_party/asobi_party.dart' show MultiplayerSpec, SyncModel;

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'survivor_world.dart';

class ArrowSurvivorCartridge extends FlameCartridge<ArrowSurvivorGame> {
  const ArrowSurvivorCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'arrow-survivor',
    title: 'Arrow Survivor',
    tagline: 'Keep moving. Your bow does the rest.',
    description:
        'An arena survival roguelite. Your archer fires automatically at the nearest '
        'foe while you steer. Clear ten waves of chasers, dashers, spitters, tanks and '
        'two bosses, picking one of three upgrade cards between waves.',
    genre: 'Survivor roguelite',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF3DDC97),
    icon: Icons.my_location_rounded,
    tags: ['action', 'roguelite', 'arena', 'auto-attack'],
    controls: ['Drag anywhere: virtual joystick to move', 'Tap a card to pick an upgrade'],
    mechanics: ['auto-attack', 'waves', 'upgrade cards', 'bosses'],
    goal: 'Survive all 10 waves. Upgrades between waves; hearts restore HP.',
    multiplayer: MultiplayerSpec(
      sync: SyncModel.parallel,
      maxPlayers: 8,
      summary: 'Same waves for everyone; highest score wins',
    ),
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  ArrowSurvivorGame createGame(FlameCartridgeSession<ArrowSurvivorGame> session) =>
      ArrowSurvivorGame(session, seed: session.context.matchSeed);
}

class ArrowSurvivorGame extends AsobiFlameGame {
  ArrowSurvivorGame(super.session, {this.seed});

  final int? seed;
  SurvivorWorld? _world;
  final Sparks sparks = Sparks();
  Vector2? _stickOrigin;
  Vector2? _stickKnob;
  double _shake = 0;
  bool _reported = false;

  SurvivorWorld get world0 => _world!;

  @override
  int get entityCount => (_world?.entityCount ?? 0) + sparks.count;

  @override
  int get liveScore => _world?.score ?? 0;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (_world == null) {
      _world = SurvivorWorld(
        width: size.x,
        height: arenaHeight,
        seed: seed ?? DateTime.now().microsecondsSinceEpoch,
      );
    } else {
      _world!.resize(size.x, arenaHeight);
    }
  }

  static const double _stickRadius = 56;

  /// The arena sits below the HUD so the archer never hides under it.
  double get arenaTop => hudTop + 28;
  double get arenaHeight => math.max(200, size.y - arenaTop - safePadding.bottom - 8);

  @override
  void onPointerDown(Vector2 position) {
    final w = _world;
    if (w == null) return;
    if (w.phase == SurvivorPhase.choosing) {
      for (var i = 0; i < w.choices.length; i++) {
        if (cardRect(i, size).contains(Offset(position.x, position.y))) {
          w.choose(i);
          audio.play(Sfx.powerup);
          audio.haptic(HapticKind.medium);
          return;
        }
      }
      return;
    }
    _stickOrigin = position.clone();
    _stickKnob = position.clone();
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final o = _stickOrigin;
    if (o == null) return;
    final d = position - o;
    if (d.length > _stickRadius) d.scaleTo(_stickRadius);
    _stickKnob = o + d;
    _world?.input.setFrom(d / _stickRadius);
  }

  @override
  void onPointerUp(Vector2 position) {
    _stickOrigin = null;
    _stickKnob = null;
    _world?.input.setZero();
  }

  static Rect cardRect(int i, Vector2 size) {
    final w = math.min(size.x - 48, 340.0);
    const h = 92.0;
    final top = size.y / 2 - 1.5 * h - 12 + i * (h + 12) + 30;
    return Rect.fromLTWH((size.x - w) / 2, top, w, h);
  }

  @override
  void update(double dt) {
    super.update(dt);
    final w = _world;
    if (w == null) return;
    w.update(dt);
    final reduced = ctx.settings.reducedEffects;
    for (final e in w.events) {
      switch (e.kind) {
        case SurvivorEventKind.shoot:
          audio.play(Sfx.whoosh);
        case SurvivorEventKind.hit:
          audio.play(Sfx.tap);
          sparks.burst(e.x, e.y, reduced ? 2 : 4, const Color(0xFFFFFFFF), speed: 120);
        case SurvivorEventKind.kill:
          audio.play(e.enemy == EnemyKind.boss ? Sfx.win : Sfx.pop);
          sparks.burst(e.x, e.y, reduced ? 6 : (e.enemy == EnemyKind.boss ? 60 : 14), _enemyColor(e.enemy!));
          if (e.enemy == EnemyKind.boss && !reduced) _shake = 0.5;
        case SurvivorEventKind.hurt:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          if (!reduced) _shake = 0.25;
        case SurvivorEventKind.pickup:
          audio.play(Sfx.coin);
          sparks.burst(e.x, e.y, 10, const Color(0xFFFF5C8A));
        case SurvivorEventKind.waveClear:
          audio.play(Sfx.powerup);
        case SurvivorEventKind.choose:
          break;
      }
    }
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (w.isOver && !_reported) {
      _reported = true;
      finish(
        RunResult(
          score: w.score,
          won: w.phase == SurvivorPhase.won,
          headline: w.phase == SurvivorPhase.won
              ? 'All ${w.finalWave} waves cleared!'
              : 'Fell on wave ${w.wave} of ${w.finalWave}',
          details: {'Kills': '${w.kills}', 'Wave': '${w.wave}', 'Time': '${w.time.toStringAsFixed(0)}s'},
        ),
      );
    }
  }

  static Color _enemyColor(EnemyKind k) => switch (k) {
    EnemyKind.chaser => const Color(0xFFFF6B6B),
    EnemyKind.dasher => const Color(0xFFFFC145),
    EnemyKind.spitter => const Color(0xFFB57BFF),
    EnemyKind.tank => const Color(0xFF8D99AE),
    EnemyKind.boss => const Color(0xFFFF2E63),
  };

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final w = _world;
    if (w == null) return;
    canvas.save();
    canvas.translate(0, arenaTop);
    if (_shake > 0) {
      final m = _shake * 14;
      canvas.translate(math.sin(w.time * 90) * m, math.cos(w.time * 77) * m);
    }
    _drawFloor(canvas);
    final paint = Paint();
    // Pickups.
    for (final k in w.pickups) {
      final pulse = 1 + 0.15 * math.sin(w.time * 8);
      paint.color = const Color(0xFFFF5C8A);
      canvas.drawCircle(Offset(k.pos.x, k.pos.y), 8 * pulse, paint);
    }
    // Enemies.
    for (final e in w.enemies) {
      paint.color = e.flash > 0 ? Colors.white : _enemyColor(e.kind);
      final c = Offset(e.pos.x, e.pos.y);
      switch (e.kind) {
        case EnemyKind.tank:
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCircle(center: c, radius: e.radius), const Radius.circular(6)),
            paint,
          );
        case EnemyKind.dasher:
          final path = Path()
            ..moveTo(c.dx, c.dy - e.radius * 1.2)
            ..lineTo(c.dx + e.radius, c.dy + e.radius)
            ..lineTo(c.dx - e.radius, c.dy + e.radius)
            ..close();
          canvas.drawPath(path, paint);
        default:
          canvas.drawCircle(c, e.radius, paint);
      }
      // Eyes face the player.
      final look = (w.player.pos - e.pos);
      if (look.length2 > 0) look.scaleTo(e.radius * 0.35);
      paint.color = const Color(0xFF14152A);
      canvas.drawCircle(c + Offset(look.x, look.y), e.radius * 0.28, paint);
      if (e.kind == EnemyKind.tank || e.kind == EnemyKind.boss) {
        drawBar(
          canvas,
          Rect.fromCenter(center: c - Offset(0, e.radius + 9), width: e.radius * 2, height: 5),
          e.hp / e.maxHp,
          const Color(0xFFFF4D6D),
        );
      }
    }
    // Enemy shots.
    paint.color = const Color(0xFFFF9F1C);
    for (final s in w.shots) {
      canvas.drawCircle(Offset(s.pos.x, s.pos.y), 5, paint);
    }
    // Arrows.
    final arrowPaint = Paint()
      ..color = const Color(0xFFE8F7FF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final a in w.arrows) {
      final tail = a.pos - a.vel.normalized() * 14;
      canvas.drawLine(Offset(a.pos.x, a.pos.y), Offset(tail.x, tail.y), arrowPaint);
    }
    // Blades.
    paint.color = const Color(0xFF7AE7FF);
    for (var i = 0; i < w.player.blades; i++) {
      final b = w.bladePosition(i);
      canvas.save();
      canvas.translate(b.x, b.y);
      canvas.rotate(w.bladeAngle * 3);
      canvas.drawRect(const Rect.fromLTWH(-9, -3, 18, 6), paint);
      canvas.restore();
    }
    // Player.
    final p = w.player;
    final pc = Offset(p.pos.x, p.pos.y);
    final blink = p.invulnerable > 0 && (w.time * 20).floor().isEven;
    if (!blink) {
      paint.color = const Color(0xFF3DDC97);
      canvas.drawCircle(pc, p.radius, paint);
      final tip = pc + Offset(p.facing.x, p.facing.y) * (p.radius + 8);
      final side = Offset(-p.facing.y, p.facing.x) * 7;
      final base = pc + Offset(p.facing.x, p.facing.y) * (p.radius - 2);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(base.dx + side.dx, base.dy + side.dy)
          ..lineTo(base.dx - side.dx, base.dy - side.dy)
          ..close(),
        paint..color = const Color(0xFFE8F7FF),
      );
    }
    sparks.render(canvas);
    canvas.restore();
    _drawStick(canvas);
    _drawHud(canvas, w);
  }

  void _drawFloor(Canvas canvas) {
    final w = _world!;
    final arena = Rect.fromLTWH(0, 0, w.width, w.height);
    canvas.drawRect(arena, Paint()..color = const Color(0xFF12142A));
    final grid = Paint()
      ..color = const Color(0xFF1B1D33)
      ..strokeWidth = 1;
    const step = 40.0;
    for (var x = step; x < w.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, w.height), grid);
    }
    for (var y = step; y < w.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(w.width, y), grid);
    }
    canvas.drawRect(
      arena.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF3DDC97).withValues(alpha: 0.35),
    );
  }

  void _drawStick(Canvas canvas) {
    final o = _stickOrigin;
    final k = _stickKnob;
    if (o == null || k == null) return;
    canvas.drawCircle(Offset(o.x, o.y), _stickRadius, Paint()..color = const Color(0x22FFFFFF));
    canvas.drawCircle(Offset(k.x, k.y), 24, Paint()..color = const Color(0x66FFFFFF));
  }

  void _drawHud(Canvas canvas, SurvivorWorld w) {
    final top = safePadding.top + 14;
    CanvasText.draw(
      canvas,
      'WAVE ${w.wave}/${w.finalWave}',
      Offset(size.x / 2, top),
      size: 18,
      align: Alignment.topCenter,
    );
    CanvasText.draw(
      canvas,
      '${w.score}',
      Offset(size.x - 16, top),
      size: 22,
      align: Alignment.topRight,
      color: const Color(0xFFFFD166),
    );
    drawBar(
      canvas,
      Rect.fromLTWH(16, hudTop, size.x - 32, 10),
      w.player.hp / w.player.maxHp,
      const Color(0xFF3DDC97),
    );
    CanvasText.draw(
      canvas,
      '${w.player.hp.ceil()} / ${w.player.maxHp.ceil()}',
      Offset(size.x / 2, hudTop + 12),
      size: 11,
      align: Alignment.topCenter,
      color: Colors.white70,
    );
    CanvasText.draw(
      canvas,
      '${w.remainingInWave} foes left',
      Offset(16, hudTop + 12),
      size: 11,
      color: Colors.white54,
    );
    if (w.phase == SurvivorPhase.intermission) {
      CanvasText.draw(
        canvas,
        w.wave >= w.finalWave ? 'VICTORY!' : 'WAVE CLEAR!',
        Offset(size.x / 2, size.y * 0.35),
        size: 34,
        align: Alignment.center,
        color: const Color(0xFFFFD166),
        weight: FontWeight.w900,
      );
    }
    if (w.phase == SurvivorPhase.fighting && w.time < 3.5 && w.wave == 1) {
      CanvasText.draw(
        canvas,
        'Drag to move · arrows fire automatically',
        Offset(size.x / 2, size.y - safePadding.bottom - 40),
        size: 14,
        align: Alignment.center,
        color: Colors.white70,
      );
    }
    if (w.phase == SurvivorPhase.choosing) {
      canvas.drawRect(Offset.zero & Size(size.x, size.y), Paint()..color = const Color(0xAA000000));
      CanvasText.draw(
        canvas,
        'CHOOSE AN UPGRADE',
        Offset(size.x / 2, cardRect(0, size).top - 30),
        size: 20,
        align: Alignment.center,
        weight: FontWeight.w900,
      );
      for (var i = 0; i < w.choices.length; i++) {
        final u = w.choices[i];
        final r = cardRect(i, size);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(16)),
          Paint()..color = const Color(0xFF22263F),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(16)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = u == Upgrade.heal ? const Color(0xFFFF5C8A) : const Color(0xFF3DDC97),
        );
        final lvl = w.levels[u] ?? 0;
        CanvasText.draw(canvas, u.title, Offset(r.left + 18, r.top + 16), size: 19, weight: FontWeight.w800);
        CanvasText.draw(
          canvas,
          u.description,
          Offset(r.left + 18, r.top + 46),
          size: 14,
          color: Colors.white70,
        );
        if (u != Upgrade.heal) {
          CanvasText.draw(
            canvas,
            'Lv ${lvl + 1}',
            Offset(r.right - 16, r.top + 18),
            size: 13,
            align: Alignment.topRight,
            color: const Color(0xFFFFD166),
          );
        }
      }
    }
  }
}
