import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import '../common/sparks.dart';
import 'barrage_world.dart';

class DigitBarrageCartridge extends FlameCartridge<DigitBarrageGame> {
  const DigitBarrageCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'digit-barrage',
    title: 'Digit Barrage',
    tagline: 'Count them down. Split them up. Stay out from under.',
    description:
        'A cannon-cart blaster. Hold and drag to steer your cart along the floor while it '
        'fires a steady stream upward. Every hit knocks one off a bouncing rock\'s number; at '
        'zero it splits into two smaller rocks worth half as much. Clear every rock to win the '
        'level, grab the coins they drop, and spend them on fire rate, damage and coin value.',
    genre: 'Arcade shooter',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFFF6B1A),
    icon: Icons.bubble_chart_rounded,
    tags: ['action', 'shooter', 'arcade', 'upgrades', 'levels'],
    controls: [
      'Hold anywhere to fire; drag left or right to steer the cart',
      'Drive over coins to collect them',
      'Tap an upgrade in the shop to buy it, then START',
    ],
    mechanics: ['continuous fire', 'splitting rocks', 'bounce physics', 'coins', 'upgrade shop', 'levels'],
    goal: 'Blast every rock and all of its splits down to zero. A rock touching the cart loses.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  DigitBarrageGame createGame(FlameCartridgeSession<DigitBarrageGame> session) => DigitBarrageGame(session);
}

/// Rock body colours, picked by the size of the rock's starting number.
const List<Color> kBarrageRockColors = [
  Color(0xFF4FC3F7),
  Color(0xFF7BE36A),
  Color(0xFFFFD54F),
  Color(0xFFFF9F43),
  Color(0xFFFF5C7A),
  Color(0xFFC77DFF),
  Color(0xFF5E8BFF),
];

class DigitBarrageGame extends AsobiFlameGame {
  DigitBarrageGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      barrage = BarrageWorld(
        seed: seed ?? DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
        level: math.max(1, session.context.save.intData('level', 1)),
        upgrades: BarrageUpgrades.fromJson(session.context.save.data['upgrades']),
        wallet: math.max(0, session.context.save.intData('coins')),
      );

  final int? seed;
  final int level;

  /// The rules object (FlameGame already owns `world`).
  final BarrageWorld barrage;
  final Sparks sparks = Sparks(capacity: 360);

  static const Color _accent = Color(0xFFFF6B1A);
  static const Color _gold = Color(0xFFFFD166);
  static const Color _danger = Color(0xFFFF4D6D);

  bool _reported = false;
  double _endDelay = 1.0;
  double _clock = 0;
  double _shake = 0;
  double _lastX = 0;
  bool _held = false;
  int _purchases = 0;

  @override
  int get entityCount => barrage.entityCount + sparks.count;

  @override
  Color backgroundColor() => const Color(0xFF121726);

  // ---------------------------------------------------------------- layout
  double get _arenaTop => hudTop + 34;
  double get _arenaBottom => size.y - safePadding.bottom - 10;
  double get _scale =>
      math.max(0.1, math.min(size.x / BarrageWorld.width, (_arenaBottom - _arenaTop) / BarrageWorld.height));
  Offset get _origin {
    final s = _scale;
    return Offset((size.x - BarrageWorld.width * s) / 2, _arenaBottom - BarrageWorld.height * s);
  }

  Offset _toScreen(double x, double y) {
    final o = _origin;
    final s = _scale;
    return Offset(o.dx + x * s, o.dy + y * s);
  }

  double get _panelWidth => math.min(size.x - 32, 360.0);

  Rect upgradeRect(int i) {
    const h = 74.0;
    final top = size.y * 0.5 - 1.5 * h - 10 + i * (h + 10);
    return Rect.fromLTWH((size.x - _panelWidth) / 2, top, _panelWidth, h);
  }

  Rect get startRect {
    final last = upgradeRect(2);
    final w = math.min(_panelWidth, 260.0);
    return Rect.fromLTWH((size.x - w) / 2, last.bottom + 22, w, 56);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (size.x <= 0 || barrage.isOver) return;
    final p = Offset(position.x, position.y);
    if (barrage.phase == BarragePhase.shop) {
      for (final k in UpgradeKind.values) {
        if (upgradeRect(k.index).contains(p)) {
          _tryBuy(k);
          return;
        }
      }
      if (startRect.contains(p)) {
        barrage.start();
        audio.play(Sfx.whoosh);
        audio.haptic(HapticKind.medium);
      }
      return;
    }
    _held = true;
    _lastX = position.x;
    barrage.setFiring(true);
  }

  void _tryBuy(UpgradeKind k) {
    if (!barrage.buy(k)) {
      audio.play(Sfx.thud);
      audio.haptic(HapticKind.light);
      return;
    }
    _purchases++;
    final save = session.context.save;
    save.data['upgrades'] = barrage.upgrades.toJson();
    save.data['coins'] = barrage.wallet;
    session.context.commitSave();
    audio.play(Sfx.powerup);
    audio.haptic(HapticKind.medium);
    final r = upgradeRect(k.index);
    sparks.burst(r.right - 50, r.center.dy, ctx.settings.reducedEffects ? 4 : 16, _gold, speed: 180);
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (!_held || barrage.phase != BarragePhase.playing) return;
    barrage.moveCartBy((position.x - _lastX) / _scale);
    _lastX = position.x;
  }

  @override
  void onPointerUp(Vector2 position) {
    _held = false;
    barrage.setFiring(false);
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    barrage.update(dt);
    final reduced = ctx.settings.reducedEffects;
    final s = _scale;
    for (final e in barrage.events) {
      final p = _toScreen(e.x, e.y);
      switch (e.kind) {
        case BarrageEventKind.shot:
        case BarrageEventKind.hit:
          break;
        case BarrageEventKind.split:
          audio.play(Sfx.pop);
          audio.haptic(HapticKind.light);
          sparks.burst(p.dx, p.dy, reduced ? 5 : 18, _rockColor(e.value * 2), speed: 220 * s);
        case BarrageEventKind.pop:
          audio.play(Sfx.pop);
          sparks.burst(p.dx, p.dy, reduced ? 4 : 12, _rockColor(e.value), speed: 180 * s);
        case BarrageEventKind.coin:
          audio.play(Sfx.coin);
          sparks.burst(p.dx, p.dy, reduced ? 2 : 6, _gold, speed: 120 * s, life: 0.35);
        case BarrageEventKind.lost:
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
          if (!reduced) _shake = 0.4;
          final c = _toScreen(barrage.cartX, BarrageWorld.floorY - 15);
          sparks.burst(c.dx, c.dy, reduced ? 10 : 40, _danger, speed: 260);
        case BarrageEventKind.won:
          audio.play(Sfx.win);
          sparks.burst(size.x / 2, size.y * 0.4, reduced ? 12 : 60, _gold, speed: 320);
      }
    }
    sparks.update(dt);
    if (_shake > 0) _shake -= dt;
    if (barrage.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _report() {
    _reported = true;
    final won = barrage.won;
    final save = session.context.save;
    save.data['coins'] = barrage.wallet + barrage.coinsRun;
    save.data['upgrades'] = barrage.upgrades.toJson();
    if (won) save.data['level'] = level + 1;
    session.context.commitSave();
    finish(
      RunResult(
        score: barrage.score,
        won: won,
        headline: won ? 'Level $level cleared! Level ${level + 1} unlocked.' : 'Crushed on level $level.',
        details: {
          'Level': '$level',
          'Damage dealt': '${barrage.damageDealt}',
          'Coins': '${barrage.coinsRun}',
          'Rocks split': '${barrage.splits}',
          'Cleared': '${(barrage.progress * 100).round()}%',
          'Time': '${barrage.time.toStringAsFixed(0)}s',
        },
      ),
    );
  }

  // ---------------------------------------------------------------- render
  final Paint _paint = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  static Color _rockColor(int value) {
    var i = 0;
    var v = math.max(1, value);
    while (v > 3) {
      v >>= 1;
      i++;
    }
    return kBarrageRockColors[i % kBarrageRockColors.length];
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 12;
      canvas.translate(math.sin(_clock * 83) * m, math.cos(_clock * 71) * m);
    }
    _drawArena(canvas);
    _drawCoins(canvas);
    _drawBullets(canvas);
    _drawRocks(canvas);
    _drawCart(canvas);
    canvas.restore();
    sparks.render(canvas);
    _drawHud(canvas);
    if (barrage.phase == BarragePhase.shop) _drawShop(canvas);
  }

  void _drawArena(Canvas canvas) {
    final s = _scale;
    final tl = _toScreen(0, 0);
    final arena = Rect.fromLTWH(tl.dx, tl.dy, BarrageWorld.width * s, BarrageWorld.height * s);
    _paint.color = const Color(0xFF182036);
    canvas.drawRRect(RRect.fromRectAndRadius(arena, Radius.circular(14 * s)), _paint);
    // Faint horizontal bands for depth.
    _paint.color = const Color(0x0DFFFFFF);
    for (var i = 1; i < 8; i++) {
      final y = tl.dy + arena.height * i / 8;
      canvas.drawRect(Rect.fromLTWH(arena.left, y, arena.width, 1), _paint);
    }
    final floor = _toScreen(0, BarrageWorld.floorY);
    _paint.color = const Color(0xFF2B3452);
    canvas.drawRect(Rect.fromLTRB(arena.left, floor.dy, arena.right, arena.bottom), _paint);
    _paint.color = _accent.withValues(alpha: 0.6);
    canvas.drawRect(Rect.fromLTWH(arena.left, floor.dy - 1.5, arena.width, 3), _paint);
  }

  void _drawRocks(Canvas canvas) {
    final s = _scale;
    for (final r in barrage.rocks) {
      final c = _toScreen(r.x, r.y);
      final rad = r.r * s;
      final color = _rockColor(r.value);
      _paint.color = const Color(0x55000000);
      canvas.drawCircle(c + Offset(0, rad * 0.12), rad, _paint);
      _paint.color = Color.lerp(color, const Color(0xFF000000), 0.35)!;
      canvas.drawCircle(c, rad, _paint);
      _paint.color = color;
      canvas.drawCircle(c - Offset(rad * 0.06, rad * 0.08), rad * 0.86, _paint);
      _paint.color = const Color(0x40FFFFFF);
      canvas.drawCircle(c - Offset(rad * 0.35, rad * 0.38), rad * 0.24, _paint);
      // Chips around the edge so rocks read as rocks, not balls.
      _paint.color = Color.lerp(color, const Color(0xFF000000), 0.2)!;
      for (var i = 0; i < 4; i++) {
        final a = r.id * 1.7 + i * math.pi / 2;
        canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * rad * 0.62, rad * 0.11, _paint);
      }
      if (r.flash > 0) {
        _paint.color = const Color(0x88FFFFFF);
        canvas.drawCircle(c, rad, _paint);
      }
      CanvasText.draw(
        canvas,
        '${r.hp}',
        c,
        size: math.max(12, rad * (r.hp >= 100 ? 0.72 : 0.95)),
        align: Alignment.center,
        weight: FontWeight.w900,
      );
    }
  }

  void _drawBullets(Canvas canvas) {
    final s = _scale;
    _paint.color = const Color(0xFFFFF1A8);
    final w = 5 * s, h = 14 * s;
    for (final b in barrage.bullets) {
      final p = _toScreen(b.x, b.y);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: w, height: h), Radius.circular(w / 2)),
        _paint,
      );
    }
  }

  void _drawCoins(Canvas canvas) {
    final s = _scale;
    final rad = BarrageWorld.coinRadius * s;
    for (final c in barrage.coins) {
      if (c.landed && c.life < 2 && (_clock * 8).floor().isEven) continue;
      final p = _toScreen(c.x, c.y);
      _paint.color = const Color(0xFFB8860B);
      canvas.drawCircle(p, rad, _paint);
      _paint.color = _gold;
      canvas.drawCircle(p, rad * 0.78, _paint);
      _stroke
        ..strokeWidth = math.max(1, rad * 0.16)
        ..color = const Color(0xFFB8860B);
      canvas.drawCircle(p, rad * 0.42, _stroke);
    }
  }

  void _drawCart(Canvas canvas) {
    final s = _scale;
    final x = barrage.cartX;
    final body = Rect.fromLTRB(
      _toScreen(x - BarrageWorld.cartHalfWidth, 0).dx,
      _toScreen(0, BarrageWorld.floorY - BarrageWorld.cartHeight * 0.7).dy,
      _toScreen(x + BarrageWorld.cartHalfWidth, 0).dx,
      _toScreen(0, BarrageWorld.floorY - 6).dy,
    );
    final lost = barrage.phase == BarragePhase.lost;
    // Barrel.
    final barrelTop = _toScreen(x, BarrageWorld.floorY - BarrageWorld.cartHeight - 6);
    final recoil = barrage.firing ? math.sin(_clock * 60).abs() * 2 * s : 0.0;
    _paint.color = const Color(0xFF9AA6C7);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(barrelTop.dx - 6 * s, barrelTop.dy + recoil, barrelTop.dx + 6 * s, body.top + 4),
        Radius.circular(3 * s),
      ),
      _paint,
    );
    _paint.color = lost ? _danger : _accent;
    canvas.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(8 * s)), _paint);
    _paint.color = const Color(0x33FFFFFF);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(body.left + 4 * s, body.top + 3 * s, body.width - 8 * s, 4 * s),
        Radius.circular(2 * s),
      ),
      _paint,
    );
    // Wheels.
    final wy = _toScreen(0, BarrageWorld.floorY - 7).dy;
    for (final dx in const [-15.0, 15.0]) {
      final wc = Offset(_toScreen(x + dx, 0).dx, wy);
      _paint.color = const Color(0xFF20263A);
      canvas.drawCircle(wc, 7 * s, _paint);
      _paint.color = const Color(0xFF9AA6C7);
      canvas.drawCircle(wc, 3 * s, _paint);
    }
    if (barrage.firing && barrage.phase == BarragePhase.playing) {
      _paint.color = const Color(0x99FFF1A8);
      canvas.drawCircle(barrelTop, (4 + math.sin(_clock * 50).abs() * 3) * s, _paint);
    }
  }

  void _drawHud(Canvas canvas) {
    CanvasText.draw(canvas, 'LEVEL $level', Offset(16, hudTop), size: 18, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      '${barrage.score}',
      Offset(size.x - 16, hudTop),
      size: 22,
      align: Alignment.topRight,
      color: _gold,
      weight: FontWeight.w900,
    );
    final barW = math.min(140.0, size.x * 0.32);
    final bar = Rect.fromLTWH((size.x - barW) / 2, hudTop + 6, barW, 10);
    drawBar(canvas, bar, barrage.progress, _accent);
    CanvasText.draw(
      canvas,
      'coins ${barrage.wallet + barrage.coinsRun}',
      Offset(size.x / 2, bar.bottom + 4),
      size: 12,
      align: Alignment.topCenter,
      color: Colors.white70,
    );
    if (barrage.phase == BarragePhase.playing && !barrage.firing && barrage.damageDealt == 0) {
      CanvasText.draw(
        canvas,
        'Hold to fire · drag to steer',
        Offset(size.x / 2, size.y * 0.45),
        size: 16,
        align: Alignment.center,
        color: Colors.white70,
      );
    }
    if (barrage.isOver) {
      CanvasText.draw(
        canvas,
        barrage.won ? 'LEVEL CLEAR!' : 'CRUSHED',
        Offset(size.x / 2, size.y * 0.4),
        size: 36,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: barrage.won ? _gold : _danger,
      );
    }
  }

  static const List<String> _upgradeNames = ['FIRE RATE', 'DAMAGE', 'COIN VALUE'];

  String _upgradeEffect(UpgradeKind k) {
    final u = barrage.upgrades;
    return switch (k) {
      UpgradeKind.fireRate => '${u.shotsPerSecond.toStringAsFixed(1)} shots/s',
      UpgradeKind.damage => '${u.damage} per hit',
      UpgradeKind.coinValue => '${u.coinValue} per coin',
    };
  }

  void _drawShop(Canvas canvas) {
    _paint.color = const Color(0xD90B0E18);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
    final top = upgradeRect(0).top;
    CanvasText.draw(
      canvas,
      'LEVEL $level',
      Offset(size.x / 2, top - 70),
      size: 30,
      align: Alignment.bottomCenter,
      weight: FontWeight.w900,
      color: _accent,
    );
    CanvasText.draw(
      canvas,
      'WORKSHOP · ${barrage.wallet} coins',
      Offset(size.x / 2, top - 22),
      size: 17,
      align: Alignment.bottomCenter,
      weight: FontWeight.w800,
      color: _gold,
    );
    for (final k in UpgradeKind.values) {
      final r = upgradeRect(k.index);
      final u = barrage.upgrades;
      final maxed = u.isMaxed(k);
      final can = barrage.canBuy(k);
      _paint.color = const Color(0xFF1E2640);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(16)), _paint);
      _stroke
        ..strokeWidth = 2
        ..color = can ? _accent : const Color(0xFF34405F);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(16)), _stroke);
      CanvasText.draw(
        canvas,
        _upgradeNames[k.index],
        Offset(r.left + 16, r.top + 14),
        size: 17,
        weight: FontWeight.w900,
      );
      CanvasText.draw(
        canvas,
        'Lv ${u.level(k)} · ${_upgradeEffect(k)}',
        Offset(r.left + 16, r.top + 40),
        size: 13,
        color: Colors.white70,
      );
      final pill = Rect.fromLTWH(r.right - 104, r.center.dy - 20, 92, 40);
      _paint.color = maxed ? const Color(0xFF34405F) : (can ? _gold : const Color(0xFF3A3424));
      canvas.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(20)), _paint);
      CanvasText.draw(
        canvas,
        maxed ? 'MAX' : '${u.cost(k)}',
        pill.center,
        size: 17,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: can ? const Color(0xFF2A1D00) : Colors.white38,
      );
    }
    final sr = startRect;
    final pulse = 0.5 + 0.5 * math.sin(_clock * 4);
    _paint.color = Color.lerp(_accent, const Color(0xFFFF9A5C), pulse)!;
    canvas.drawRRect(RRect.fromRectAndRadius(sr, const Radius.circular(28)), _paint);
    CanvasText.draw(
      canvas,
      _purchases > 0 ? 'START  ·  upgraded' : 'START',
      sr.center,
      size: 20,
      align: Alignment.center,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '${barrage.rocks.length + barrage.pendingCount} rocks · ${barrage.levelHp} total to blast',
      Offset(size.x / 2, sr.bottom + 14),
      size: 13,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
  }
}
