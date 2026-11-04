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
import 'coil_world.dart';

class CoilClashCartridge extends FlameCartridge<CoilClashGame> {
  const CoilClashCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'coil-clash',
    title: 'Coil Clash',
    tagline: 'Grow long. Cut them off. Never touch a coil.',
    description:
        'A free-roaming serpent battle in a huge round arena. Steer your glowing coil with a '
        'floating stick, swallow orbs to grow and trap rivals so their heads hit your body. '
        'Anything that dies bursts into a feast of orbs. Boosting is fast but burns length. '
        'After three minutes the longest living serpent rules the arena.',
    genre: 'Arena serpent battle',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFE86AF0),
    icon: Icons.all_inclusive_rounded,
    tags: ['action', 'io', 'snake', 'arena', 'bots', 'multiplayer-ready'],
    controls: [
      'Drag anywhere: floating stick sets your heading',
      'Hold the BOOST button, or double-tap and hold while steering, to boost (burns length)',
    ],
    mechanics: [
      'free steering',
      'growth',
      'boost burns length',
      'head-to-body kills',
      'head-on: shorter dies',
      'orb drops',
      'leaderboard',
      'minimap',
      'timed round',
    ],
    goal:
        'Be the longest serpent alive when the 3-minute round ends. Touching another body or '
        'the arena rim ends your run. Score = best length + 50 per kill.',
    maxPlayers: 8,
    multiplayer: MultiplayerSpec(
      sync: SyncModel.parallel,
      maxPlayers: 8,
      summary: 'Same arena for everyone; highest score wins',
    ),
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  CoilClashGame createGame(FlameCartridgeSession<CoilClashGame> session) =>
      CoilClashGame(session, seed: session.context.matchSeed);
}

class CoilClashGame extends AsobiFlameGame {
  CoilClashGame(super.session, {this.seed})
    : coil = CoilWorld(seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff) {
    _steer = coil.local.heading;
    _camX = coil.local.x;
    _camY = coil.local.y;
  }

  final int? seed;
  final CoilWorld coil;
  final Sparks sparks = Sparks(capacity: 300);

  static const List<Color> palette = [
    Color(0xFFE86AF0),
    Color(0xFF46E6B4),
    Color(0xFFFFC94D),
    Color(0xFF6FA8FF),
    Color(0xFFFF6B6B),
    Color(0xFFFF9A4C),
    Color(0xFF9BE35A),
    Color(0xFF4FE0F0),
  ];

  static const double _stickRadius = 56;

  // Input.
  Vector2? _stickOrigin;
  Vector2? _stickKnob;
  bool _buttonHeld = false;
  bool _dragBoost = false;
  double _lastUp = -10;
  double _steer = 0;
  int _sentInput = -1;

  // Camera + timing.
  double _camX = 0, _camY = 0, _zoom = 1;
  double _clock = 0;
  double _endTimer = -1;
  double _shake = 0;
  double _eatSfx = 0;
  bool _reported = false;
  bool _wasBoosting = false;

  // Reused paints and buffers (no per-frame allocation besides Offsets/Paths).
  final Paint _fill = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _grid = Paint()
    ..color = const Color(0xFF1C1B33)
    ..strokeWidth = 1.5;
  final Path _arenaPath = Path()
    ..addOval(Rect.fromCircle(center: Offset.zero, radius: CoilWorld.arenaRadius));
  final List<int> _rank = [];

  @override
  int get entityCount => coil.entityCount + sparks.count;

  @override
  int get liveScore => coil.score;

  @override
  Color backgroundColor() => const Color(0xFF07060F);

  Offset get _boostCenter => Offset(size.x - 64, size.y - safePadding.bottom - 64);
  static const double _boostRadius = 40;

  @override
  void onPointerDown(Vector2 position) {
    if (!coil.local.alive || coil.isOver) return;
    final b = _boostCenter;
    if ((position.x - b.dx) * (position.x - b.dx) + (position.y - b.dy) * (position.y - b.dy) <
        (_boostRadius + 8) * (_boostRadius + 8)) {
      _buttonHeld = true;
      return;
    }
    _dragBoost = _clock - _lastUp < 0.28;
    _stickOrigin = position.clone();
    _stickKnob = position.clone();
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final o = _stickOrigin;
    if (o == null) return;
    final dx = position.x - o.x, dy = position.y - o.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > _stickRadius) {
      // Floating stick: the base trails the thumb.
      o.x = position.x - dx / len * _stickRadius;
      o.y = position.y - dy / len * _stickRadius;
    }
    _stickKnob!.setFrom(position);
    if (len > 6) _steer = math.atan2(dy, dx);
  }

  @override
  void onPointerUp(Vector2 position) {
    if (_stickOrigin != null) _lastUp = _clock;
    _stickOrigin = null;
    _stickKnob = null;
    _buttonHeld = false;
    _dragBoost = false;
  }

  bool get boostHeld => _buttonHeld || _dragBoost;

  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    final me = coil.local;
    if (me.alive && !coil.timeUp) {
      final input = CoilInput.fromAngle(_steer, boost: boostHeld);
      if (input.packed != _sentInput) {
        _sentInput = input.packed;
        coil.setInput(coil.localPlayer, input);
      }
    }
    coil.update(dt);
    _handleEvents();
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (_eatSfx > 0) _eatSfx -= dt;

    // Camera follows the head (or rests where it died) and zooms out as you grow.
    final k = 1 - math.exp(-dt * 8);
    _camX += (me.x - _camX) * k;
    _camY += (me.y - _camY) * k;
    final targetZoom = size.x <= 0 ? 1.0 : size.x / (400 + me.radius * 18);
    _zoom += (targetZoom - _zoom) * (1 - math.exp(-dt * 2));

    if (coil.isOver && !_reported) {
      if (_endTimer < 0) {
        _endTimer = 1.2;
        if (!me.alive) {
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
        } else {
          audio.play(coil.won ? Sfx.win : Sfx.lose);
        }
      }
      _endTimer -= dt;
      if (_endTimer <= 0) _report();
    }
  }

  void _handleEvents() {
    final reduced = ctx.settings.reducedEffects;
    final me = coil.localPlayer;
    final s = coil.local;
    if (s.boosting && !_wasBoosting) audio.play(Sfx.whoosh);
    _wasBoosting = s.boosting;
    for (final e in coil.events) {
      switch (e.kind) {
        case CoilEventKind.eat:
          if (e.player != me) break;
          if (_eatSfx <= 0) {
            audio.play(Sfx.coin);
            _eatSfx = 0.07;
          }
          if (!reduced) sparks.burst(e.x, e.y, 3, palette[e.other % palette.length], speed: 90, life: 0.3);
        case CoilEventKind.death:
          final victim = coil.serpents[e.player];
          final near = (e.x - _camX).abs() < 500 && (e.y - _camY).abs() < 800;
          if (near) sparks.burst(e.x, e.y, reduced ? 8 : 26, palette[victim.hue], speed: 260, life: 0.7);
          if (e.player == me) {
            if (!reduced) _shake = 0.4;
          } else if (e.other == me) {
            audio.play(Sfx.pop);
            audio.haptic(HapticKind.medium);
          } else if (near) {
            audio.play(Sfx.thud);
          }
        case CoilEventKind.respawn:
          break;
      }
    }
  }

  void _report() {
    _reported = true;
    final w = coil;
    final me = w.local;
    final String headline;
    if (w.won) {
      headline = 'Longest coil in the arena!';
    } else if (me.alive) {
      headline = 'Time! You finished #${w.rankOf(w.localPlayer)}';
    } else {
      headline = switch (me.lastCause) {
        DeathCause.edge => 'Slid off the arena rim',
        DeathCause.head when me.lastKiller >= 0 => 'Out-sized head-on by ${w.serpents[me.lastKiller].name}',
        DeathCause.head => 'Head-on stalemate',
        _ => me.lastKiller >= 0 ? 'Coiled by ${w.serpents[me.lastKiller].name}' : 'Coiled',
      };
    }
    final save = ctx.save.data;
    final best = (save['bestLength'] as num?)?.toInt() ?? 0;
    if (me.maxLength.floor() > best) {
      save['bestLength'] = me.maxLength.floor();
      ctx.commitSave();
    }
    finish(
      RunResult(
        score: w.score,
        won: w.won,
        headline: headline,
        details: {
          'Best length': '${me.maxLength.floor()}',
          'Kills': '${me.kills}',
          'Survived': '${w.time.floor()}s',
          if (me.alive) 'Rank': '#${w.rankOf(w.localPlayer)}',
        },
      ),
    );
  }

  // ---- Rendering -----------------------------------------------------------

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    final w = coil;
    final reduced = ctx.settings.reducedEffects;
    final halfW = size.x / 2 / _zoom, halfH = size.y / 2 / _zoom;
    final left = _camX - halfW - 40, right = _camX + halfW + 40;
    final top = _camY - halfH - 40, bottom = _camY + halfH + 40;

    canvas.save();
    canvas.translate(size.x / 2, size.y / 2);
    if (_shake > 0) {
      final m = _shake * 12;
      canvas.translate(math.sin(_clock * 90) * m, math.cos(_clock * 77) * m);
    }
    canvas.scale(_zoom);
    canvas.translate(-_camX, -_camY);

    // Arena floor, hex-ish dot grid and glowing rim.
    _fill.color = const Color(0xFF110F22);
    canvas.drawCircle(Offset.zero, CoilWorld.arenaRadius, _fill);
    canvas.save();
    canvas.clipPath(_arenaPath);
    const step = 60.0;
    for (var x = (left / step).floor() * step; x <= right; x += step) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), _grid);
    }
    for (var y = (top / step).floor() * step; y <= bottom; y += step) {
      canvas.drawLine(Offset(left, y), Offset(right, y), _grid);
    }
    canvas.restore();
    _stroke
      ..strokeWidth = 14
      ..color = const Color(0x55FF3B6B);
    canvas.drawCircle(Offset.zero, CoilWorld.arenaRadius + 7, _stroke);
    _stroke
      ..strokeWidth = 3
      ..color = const Color(0xFFFF4D7A);
    canvas.drawCircle(Offset.zero, CoilWorld.arenaRadius, _stroke);

    // Orbs.
    for (var i = 0; i < w.orbCount; i++) {
      final x = w.ox[i], y = w.oy[i];
      if (x < left || x > right || y < top || y > bottom) continue;
      final c = palette[w.ohue[i] % palette.length];
      final grow = ((w.tick - w.oborn[i]) / 20).clamp(0.0, 1.0);
      final pulse = 1 + 0.18 * math.sin(_clock * 5 + i * 1.7);
      final r = (2.6 + w.ov[i] * 1.6) * grow;
      if (!reduced) {
        _fill.color = c.withValues(alpha: 0.22);
        canvas.drawCircle(Offset(x, y), r * 2.4 * pulse, _fill);
      }
      _fill.color = c;
      canvas.drawCircle(Offset(x, y), r, _fill);
    }

    // Serpents (local player drawn last, on top).
    for (final s in w.serpents) {
      if (s.alive && s.id != w.localPlayer) _drawSerpent(canvas, s, reduced);
    }
    if (w.local.alive) _drawSerpent(canvas, w.local, reduced);
    sparks.render(canvas);
    canvas.restore();

    // Names above rival heads (screen space so they stay readable).
    for (final s in w.serpents) {
      if (!s.alive || s.id == w.localPlayer) continue;
      final sx = (s.x - _camX) * _zoom + size.x / 2, sy = (s.y - _camY) * _zoom + size.y / 2;
      if (sx < -40 || sx > size.x + 40 || sy < -40 || sy > size.y + 40) continue;
      CanvasText.draw(
        canvas,
        s.name,
        Offset(sx, sy - (s.radius + 10) * _zoom),
        size: 11,
        align: Alignment.bottomCenter,
        color: Colors.white70,
      );
    }

    _drawStick(canvas);
    _drawHud(canvas, w);
  }

  void _drawSerpent(Canvas canvas, Serpent s, bool reduced) {
    final base = palette[s.hue % palette.length];
    final r = s.radius;
    final n = s.pointCount;
    final path = Path()..moveTo(s.x, s.y);
    for (var i = 0; i < n; i++) {
      path.lineTo(s.pointX(i), s.pointY(i));
    }
    if (s.boosting && !reduced) {
      _stroke
        ..strokeWidth = r * 2 + 14
        ..color = base.withValues(alpha: 0.25);
      canvas.drawPath(path, _stroke);
    }
    _stroke
      ..strokeWidth = r * 2 + 3
      ..color = Color.lerp(base, const Color(0xFF000000), 0.6)!;
    canvas.drawPath(path, _stroke);
    _stroke
      ..strokeWidth = r * 2
      ..color = base;
    canvas.drawPath(path, _stroke);
    // Stripes.
    _fill.color = Color.lerp(base, const Color(0xFFFFFFFF), 0.45)!;
    for (var i = 4; i < n; i += 6) {
      canvas.drawCircle(Offset(s.pointX(i), s.pointY(i)), r * 0.42, _fill);
    }
    // Head and eyes looking where the player steers.
    final hc = Offset(s.x, s.y);
    _fill.color = Color.lerp(base, const Color(0xFFFFFFFF), 0.15)!;
    canvas.drawCircle(hc, r * 1.12, _fill);
    final c = math.cos(s.heading), sn = math.sin(s.heading);
    final look = s.input.angle;
    final lx = math.cos(look) * r * 0.18, ly = math.sin(look) * r * 0.18;
    for (final side in const [-1.0, 1.0]) {
      final ex = s.x + c * r * 0.45 - sn * r * 0.5 * side;
      final ey = s.y + sn * r * 0.45 + c * r * 0.5 * side;
      _fill.color = const Color(0xFFFFFFFF);
      canvas.drawCircle(Offset(ex, ey), r * 0.38, _fill);
      _fill.color = const Color(0xFF12101E);
      canvas.drawCircle(Offset(ex + lx, ey + ly), r * 0.2, _fill);
    }
  }

  void _drawStick(Canvas canvas) {
    final o = _stickOrigin;
    final k = _stickKnob;
    if (o == null || k == null) return;
    _fill.color = const Color(0x22FFFFFF);
    canvas.drawCircle(Offset(o.x, o.y), _stickRadius, _fill);
    _fill.color = _dragBoost ? const Color(0x99E86AF0) : const Color(0x66FFFFFF);
    canvas.drawCircle(Offset(k.x, k.y), 24, _fill);
  }

  void _drawHud(Canvas canvas, CoilWorld w) {
    final me = w.local;
    // Round timer in the host's top row.
    final left = w.timeLeft.ceil();
    CanvasText.draw(
      canvas,
      '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}',
      Offset(size.x / 2, safePadding.top + 14),
      size: 20,
      align: Alignment.topCenter,
      color: left <= 10 ? const Color(0xFFFF6B6B) : Colors.white,
    );
    // Own stats.
    CanvasText.draw(
      canvas,
      'LENGTH ${me.length.floor()}',
      Offset(16, hudTop),
      size: 18,
      weight: FontWeight.w900,
      color: palette[me.hue],
    );
    CanvasText.draw(
      canvas,
      'Kills ${me.kills} · Score ${w.score}',
      Offset(16, hudTop + 24),
      size: 12,
      color: Colors.white70,
    );

    // Leaderboard (top 5, plus your row if you are lower).
    _rank
      ..clear()
      ..addAll(w.ranking());
    const rowH = 17.0;
    const panelW = 138.0;
    final px = size.x - panelW - 12;
    final rows = math.min(5, _rank.length);
    final myRank = _rank.indexOf(w.localPlayer);
    final extra = myRank >= 5 ? 1 : 0;
    _fill.color = const Color(0x88000000);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(px, hudTop - 4, panelW, (rows + extra) * rowH + 10),
        const Radius.circular(10),
      ),
      _fill,
    );
    for (var i = 0; i < rows + extra; i++) {
      final rank = i < rows ? i : myRank;
      final s = w.serpents[_rank[rank]];
      final y = hudTop + 1 + i * rowH;
      final color = s.id == w.localPlayer ? const Color(0xFFFFD166) : Colors.white70;
      CanvasText.draw(canvas, '${rank + 1}. ${s.name}', Offset(px + 8, y), size: 12, color: color);
      CanvasText.draw(
        canvas,
        '${s.length.floor()}',
        Offset(px + panelW - 8, y),
        size: 12,
        align: Alignment.topRight,
        color: color,
      );
    }

    _drawMinimap(canvas, w);

    // Boost button.
    final b = _boostCenter;
    final canBoost = me.alive && me.length > CoilWorld.minBoostLength;
    _fill.color = me.boosting ? const Color(0xAAE86AF0) : const Color(0x33FFFFFF);
    canvas.drawCircle(b, _boostRadius, _fill);
    _stroke
      ..strokeWidth = 2
      ..color = canBoost ? const Color(0xFFE86AF0) : const Color(0x55FFFFFF);
    canvas.drawCircle(b, _boostRadius, _stroke);
    CanvasText.draw(
      canvas,
      'BOOST',
      b,
      size: 12,
      align: Alignment.center,
      color: canBoost ? Colors.white : Colors.white38,
    );

    if (w.time < 4 && me.alive) {
      CanvasText.draw(
        canvas,
        'Drag to steer · eat orbs · avoid other coils',
        Offset(size.x / 2, size.y * 0.72),
        size: 14,
        align: Alignment.center,
        color: Colors.white70,
      );
    }
    if (_endTimer >= 0 || w.isOver) {
      final text = !me.alive ? 'COILED!' : (w.won ? 'ARENA CHAMPION!' : 'TIME!');
      CanvasText.draw(
        canvas,
        text,
        Offset(size.x / 2, size.y * 0.4),
        size: 34,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: w.won ? const Color(0xFFFFD166) : Colors.white,
      );
    }
  }

  void _drawMinimap(Canvas canvas, CoilWorld w) {
    const mr = 48.0;
    final c = Offset(16 + mr, size.y - safePadding.bottom - 16 - mr);
    _fill.color = const Color(0x99000000);
    canvas.drawCircle(c, mr, _fill);
    _stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x88FF4D7A);
    canvas.drawCircle(c, mr, _stroke);
    const k = mr / CoilWorld.arenaRadius;
    for (final s in w.serpents) {
      if (!s.alive || s.id == w.localPlayer) continue;
      _fill.color = palette[s.hue % palette.length];
      canvas.drawCircle(c + Offset(s.x * k, s.y * k), 2 + s.radius * 0.08, _fill);
    }
    final me = w.local;
    if (me.alive) {
      final p = c + Offset(me.x * k, me.y * k);
      _fill.color = Colors.white;
      canvas.drawCircle(p, 4, _fill);
      _fill.color = palette[me.hue];
      canvas.drawCircle(p, 2.6, _fill);
    }
  }
}
