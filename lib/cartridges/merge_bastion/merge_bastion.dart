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
import 'bastion_world.dart';

class MergeBastionCartridge extends FlameCartridge<MergeBastionGame> {
  const MergeBastionCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'merge-bastion',
    title: 'Merge Bastion',
    tagline: 'Summon. Merge. Hold the wall.',
    description:
        'A merge-defense game. Spend coins to summon tier-1 sentries onto a 5x3 grid behind '
        'your wall, then drag identical sentries together to fuse them into stronger tiers. '
        'Every sentry fires on its own at the nearest foe. Hold out for 15 waves, with a '
        'boss every fifth wave.',
    genre: 'Merge defense',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF5BC0EB),
    icon: Icons.fort_rounded,
    tags: ['strategy', 'merge', 'tower-defense', 'hybrid-casual', 'levels'],
    controls: [
      'Tap SUMMON to buy a tier-1 sentry (the price rises each time)',
      'Drag a sentry onto an identical one to merge, onto an empty cell to move, onto another to swap',
    ],
    mechanics: ['merge', 'auto-fire', 'waves', 'bosses', 'economy', 'levels'],
    goal: 'Survive all 15 waves before the wall falls. Each win raises the difficulty level.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  MergeBastionGame createGame(FlameCartridgeSession<MergeBastionGame> session) => MergeBastionGame(session);
}

/// Body colour of each sentry tier (index = tier - 1).
const List<Color> kTierColors = [
  Color(0xFF8FD694), // 1 sprout green
  Color(0xFF4EA8FF), // 2 blue
  Color(0xFFB07CFF), // 3 violet
  Color(0xFFFF9F43), // 4 orange
  Color(0xFFFF5D73), // 5 red
  Color(0xFF2EE6D6), // 6 cyan
  Color(0xFFFFD23F), // 7 gold
  Color(0xFFFFF4F8), // 8 pearl
];

Color tierColor(int tier) => kTierColors[(tier - 1).clamp(0, kTierColors.length - 1)];

class MergeBastionGame extends AsobiFlameGame {
  MergeBastionGame(super.session, {this.seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      bastion = BastionWorld(
        seed: seed ?? DateTime.now().microsecondsSinceEpoch,
        level: math.max(1, session.context.save.intData('level', 1)),
      );

  final int? seed;
  final int level;

  /// The rules object (FlameGame already owns `world`).
  final BastionWorld bastion;
  final Sparks sparks = Sparks();

  final List<_Bolt> _bolts = [];
  final List<_Floater> _floaters = [];
  int? _dragFrom;
  Offset? _dragPos;
  double _buttonPulse = 0;
  double _wallFlash = 0;
  double _shake = 0;
  double _shotSfxCooldown = 0;
  double _clock = 0;
  double _endDelay = 1.2;
  bool _reported = false;

  int? get dragFrom => _dragFrom;

  @override
  int get entityCount => bastion.entityCount + sparks.count + _bolts.length;

  @override
  Color backgroundColor() => const Color(0xFF101826);

  // ---------------------------------------------------------------- layout
  Rect get summonButtonRect {
    final w = math.min(260.0, size.x - 48);
    const h = 58.0;
    return Rect.fromLTWH((size.x - w) / 2, size.y - safePadding.bottom - 16 - h, w, h);
  }

  double get _boardTop => hudTop + 54;
  double get _boardBottom => summonButtonRect.top - 14;

  /// Pixels per board unit.
  double get unit => math.max(
    1,
    math.min((size.x - 24) / BastionWorld.cols, (_boardBottom - _boardTop) / BastionWorld.boardHeight),
  );

  Offset get _origin {
    final u = unit;
    final w = BastionWorld.cols * u;
    final h = BastionWorld.boardHeight * u;
    return Offset((size.x - w) / 2, _boardTop + math.max(0, (_boardBottom - _boardTop - h) / 2));
  }

  Offset toScreen(double x, double y) {
    final o = _origin;
    final u = unit;
    return Offset(o.dx + x * u, o.dy + y * u);
  }

  Offset cellCenterOnScreen(int cell) =>
      toScreen(BastionWorld.cellCenterX(cell), BastionWorld.cellCenterY(cell));

  Rect _cellRect(int cell) {
    final u = unit;
    return Rect.fromCenter(center: cellCenterOnScreen(cell), width: u, height: u).deflate(u * 0.06);
  }

  int _cellAtScreen(Offset p) {
    final o = _origin;
    final u = unit;
    return BastionWorld.cellAt((p.dx - o.dx) / u, (p.dy - o.dy) / u);
  }

  // ---------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    if (bastion.isOver || !hasLayout) return;
    final p = Offset(position.x, position.y);
    if (summonButtonRect.contains(p)) {
      _trySummon();
      return;
    }
    final cell = _cellAtScreen(p);
    if (cell >= 0 && bastion.unitAt(cell) != null) {
      _dragFrom = cell;
      _dragPos = p;
      audio.haptic(HapticKind.selection);
    }
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    if (_dragFrom == null) return;
    _dragPos = Offset(position.x, position.y);
  }

  @override
  void onPointerUp(Vector2 position) {
    final from = _dragFrom;
    _dragFrom = null;
    _dragPos = null;
    if (from == null || bastion.isOver) return;
    final to = _cellAtScreen(Offset(position.x, position.y));
    if (to < 0 || to == from) return;
    final outcome = bastion.dragUnit(from, to);
    final c = cellCenterOnScreen(to);
    switch (outcome) {
      case DragOutcome.merged:
        final tier = bastion.unitAt(to)!.tier;
        audio.play(Sfx.merge);
        audio.haptic(HapticKind.medium);
        sparks.burst(
          c.dx,
          c.dy,
          ctx.settings.reducedEffects ? 6 : 18 + tier * 2,
          tierColor(tier),
          speed: 180,
        );
        _floaters.add(_Floater('TIER $tier', c, tierColor(tier)));
      case DragOutcome.moved:
      case DragOutcome.swapped:
        audio.play(Sfx.tap);
        audio.haptic(HapticKind.selection);
      case DragOutcome.invalid:
        audio.play(Sfx.thud);
    }
  }

  void _trySummon() {
    final cell = bastion.summon();
    if (cell == null) {
      audio.play(Sfx.thud);
      audio.haptic(HapticKind.light);
      return;
    }
    _buttonPulse = 0.2;
    audio.play(Sfx.pop);
    audio.haptic(HapticKind.light);
    final c = cellCenterOnScreen(cell);
    sparks.burst(c.dx, c.dy, ctx.settings.reducedEffects ? 4 : 10, tierColor(1), speed: 120, life: 0.4);
  }

  /// Predicted outcome of dropping the dragged unit on [to], for highlighting.
  DragOutcome _preview(int from, int to) {
    if (to < 0 || to == from) return DragOutcome.invalid;
    final a = bastion.unitAt(from);
    final b = bastion.unitAt(to);
    if (a == null) return DragOutcome.invalid;
    if (b == null) return DragOutcome.moved;
    if (a.tier == b.tier) return a.tier >= BastionWorld.maxTier ? DragOutcome.invalid : DragOutcome.merged;
    return DragOutcome.swapped;
  }

  // ---------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    bastion.update(dt);
    final reduced = ctx.settings.reducedEffects;
    final laidOut = hasLayout;
    for (final e in bastion.events) {
      final at = laidOut ? toScreen(e.x, e.y) : Offset.zero;
      switch (e.kind) {
        case BastionEventKind.shot:
          if (laidOut && _bolts.length < 80) _bolts.add(_Bolt(at, toScreen(e.x2, e.y2), e.tier));
          if (_shotSfxCooldown <= 0) {
            audio.play(Sfx.whoosh);
            _shotSfxCooldown = 0.18;
          }
        case BastionEventKind.kill:
          final boss = e.enemy == EnemyKind.boss;
          audio.play(boss ? Sfx.win : Sfx.pop);
          sparks.burst(at.dx, at.dy, reduced ? 4 : (boss ? 50 : 12), _enemyColor(e.enemy!), speed: 200);
          if (boss && !reduced) _shake = 0.4;
        case BastionEventKind.wallHit:
          audio.play(Sfx.hit);
          audio.haptic(HapticKind.heavy);
          _wallFlash = 0.35;
          if (!reduced) _shake = math.max(_shake, 0.25);
          sparks.burst(at.dx, at.dy, reduced ? 4 : 16, const Color(0xFFFFB38A), speed: 160);
        case BastionEventKind.waveStart:
          audio.play(Sfx.whoosh);
        case BastionEventKind.waveClear:
          audio.play(Sfx.powerup);
          audio.play(Sfx.coin);
        case BastionEventKind.won:
          audio.play(Sfx.win);
          sparks.burst(at.dx, at.dy, reduced ? 12 : 70, const Color(0xFFFFD23F), speed: 320);
        case BastionEventKind.lost:
          audio.play(Sfx.lose);
          audio.haptic(HapticKind.heavy);
      }
    }
    sparks.update(dt);
    for (final b in _bolts) {
      b.life -= dt;
    }
    _bolts.removeWhere((b) => b.life <= 0);
    for (final f in _floaters) {
      f.t += dt / 0.9;
    }
    _floaters.removeWhere((f) => f.t >= 1);
    if (_shotSfxCooldown > 0) _shotSfxCooldown -= dt;
    if (_buttonPulse > 0) _buttonPulse -= dt;
    if (_wallFlash > 0) _wallFlash -= dt;
    if (_shake > 0) _shake -= dt;
    if (bastion.isOver && !_reported) {
      _dragFrom = null;
      _dragPos = null;
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _report() {
    _reported = true;
    final won = bastion.won;
    if (won) {
      session.context.save.data['level'] = level + 1;
      session.context.commitSave();
    }
    finish(
      RunResult(
        score: bastion.score,
        won: won,
        headline: won
            ? 'All ${bastion.finalWave} waves held! Level ${level + 1} unlocked.'
            : 'The wall fell on wave ${bastion.wave} of ${bastion.finalWave}.',
        details: {
          'Level': '$level',
          'Waves': '${bastion.wavesCleared}/${bastion.finalWave}',
          'Kills': '${bastion.kills}',
          'Merges': '${bastion.merges}',
          'Best tier': '${_bestTier()}',
          'Wall': '${bastion.wallHp}/${BastionWorld.maxWallHp}',
        },
      ),
    );
  }

  int _bestTier() => bastion.grid.fold(0, (m, u) => math.max(m, u?.tier ?? 0));

  static Color _enemyColor(EnemyKind k) => switch (k) {
    EnemyKind.grunt => const Color(0xFFE85D75),
    EnemyKind.runner => const Color(0xFFFFB347),
    EnemyKind.brute => const Color(0xFF9AA5B8),
    EnemyKind.boss => const Color(0xFFD6336C),
  };

  // ---------------------------------------------------------------- render
  final Paint _paint = Paint();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    canvas.save();
    if (_shake > 0) {
      final m = _shake * 10;
      canvas.translate(math.sin(_clock * 83) * m, math.cos(_clock * 71) * m);
    }
    _drawLane(canvas);
    _drawEnemies(canvas);
    _drawWall(canvas);
    _drawGrid(canvas);
    _drawBolts(canvas);
    sparks.render(canvas);
    canvas.restore();
    _drawFloaters(canvas);
    _drawDragged(canvas);
    _drawButton(canvas);
    _drawHud(canvas);
  }

  void _drawLane(Canvas canvas) {
    final u = unit;
    final tl = toScreen(0, 0);
    final lane = Rect.fromLTWH(
      tl.dx - u * 0.2,
      tl.dy,
      BastionWorld.cols * u + u * 0.4,
      BastionWorld.wallY * u,
    );
    canvas.drawRRect(
      RRect.fromRectAndCorners(lane, topLeft: const Radius.circular(14), topRight: const Radius.circular(14)),
      _paint..color = const Color(0xFF1B2A3A),
    );
    // Scrolling dashes hint at the march direction.
    _paint.color = const Color(0xFF223548);
    final offset = (_clock * 0.4 % 1) * u;
    for (var c = 1; c < BastionWorld.cols; c++) {
      final x = tl.dx + c * u;
      for (var y = lane.top - u + offset; y < lane.bottom; y += u) {
        final top = math.max(y, lane.top);
        final bottom = math.min(y + u * 0.45, lane.bottom);
        if (bottom > top) canvas.drawRect(Rect.fromLTRB(x - 1, top, x + 1, bottom), _paint);
      }
    }
    // Range line: the reach of the front row.
    final reachY = BastionWorld.gridTop + 0.5 - BastionWorld.range;
    if (reachY > 0) {
      final y = toScreen(0, reachY).dy;
      _paint.color = const Color(0x225BC0EB);
      canvas.drawRect(Rect.fromLTRB(lane.left, y, lane.right, y + 2), _paint);
    }
  }

  void _drawEnemies(Canvas canvas) {
    final u = unit;
    for (final e in bastion.enemies) {
      if (!e.alive) continue;
      final c = toScreen(e.x, e.y);
      final r = e.radius * u;
      _paint.color = e.flash > 0 ? Colors.white : _enemyColor(e.kind);
      switch (e.kind) {
        case EnemyKind.grunt:
          canvas.drawCircle(c, r, _paint);
        case EnemyKind.runner:
          canvas.drawPath(
            Path()
              ..moveTo(c.dx, c.dy + r * 1.2)
              ..lineTo(c.dx + r, c.dy - r)
              ..lineTo(c.dx - r, c.dy - r)
              ..close(),
            _paint,
          );
        case EnemyKind.brute:
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCircle(center: c, radius: r), Radius.circular(r * 0.3)),
            _paint,
          );
        case EnemyKind.boss:
          canvas.drawPath(_poly(c, 8, r, math.pi / 8), _paint);
          _paint.color = const Color(0xFFFFD23F);
          canvas.drawPath(_star(c - Offset(0, r * 1.05), 5, r * 0.32, r * 0.14), _paint);
      }
      // Eyes looking down at the wall.
      _paint.color = const Color(0xFF14152A);
      canvas.drawCircle(c + Offset(-r * 0.32, r * 0.2), r * 0.16, _paint);
      canvas.drawCircle(c + Offset(r * 0.32, r * 0.2), r * 0.16, _paint);
      if (e.hp < e.maxHp || e.kind == EnemyKind.boss) {
        drawBar(
          canvas,
          Rect.fromCenter(center: c - Offset(0, r + 7), width: math.max(r * 2, 20), height: 4),
          e.hp / e.maxHp,
          const Color(0xFFFF4D6D),
        );
      }
    }
  }

  void _drawWall(Canvas canvas) {
    final u = unit;
    final tl = toScreen(-0.2, BastionWorld.wallY);
    final rect = Rect.fromLTWH(tl.dx, tl.dy, (BastionWorld.cols + 0.4) * u, BastionWorld.wallThickness * u);
    final hpT = bastion.wallHp / BastionWorld.maxWallHp;
    final base = Color.lerp(const Color(0xFF7A3B3B), const Color(0xFF8A9BB0), hpT)!;
    _paint.color = _wallFlash > 0 ? Color.lerp(base, const Color(0xFFFF6B6B), _wallFlash / 0.35)! : base;
    canvas.drawRect(rect, _paint);
    // Brick seams and crenellations.
    _paint.color = const Color(0x55000000);
    final brick = u * 0.5;
    for (var x = rect.left + brick; x < rect.right; x += brick) {
      canvas.drawRect(Rect.fromLTWH(x, rect.top, 1.5, rect.height), _paint);
    }
    canvas.drawRect(Rect.fromLTWH(rect.left, rect.center.dy, rect.width, 1.5), _paint);
    _paint.color = base;
    for (var x = rect.left; x < rect.right - brick * 0.5; x += brick * 2) {
      canvas.drawRect(
        Rect.fromLTRB(x, rect.top - u * 0.14, math.min(x + brick, rect.right), rect.top),
        _paint,
      );
    }
  }

  void _drawGrid(Canvas canvas) {
    final u = unit;
    final from = _dragFrom;
    final hover = from != null && _dragPos != null ? _cellAtScreen(_dragPos!) : -1;
    final preview = from != null ? _preview(from, hover) : DragOutcome.invalid;
    for (var cell = 0; cell < BastionWorld.cellCount; cell++) {
      final r = _cellRect(cell);
      final rr = RRect.fromRectAndRadius(r, Radius.circular(u * 0.14));
      _paint.color = BastionWorld.rowOf(cell) == 0 ? const Color(0xFF243447) : const Color(0xFF1D2B3B);
      canvas.drawRRect(rr, _paint);
      if (cell == hover && preview != DragOutcome.invalid) {
        _paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = switch (preview) {
            DragOutcome.merged => const Color(0xFF7CFFB2),
            DragOutcome.swapped => const Color(0xFFFFC857),
            _ => const Color(0xFFE6F1FF),
          };
        canvas.drawRRect(rr, _paint);
        _paint.style = PaintingStyle.fill;
      }
      final unitHere = bastion.unitAt(cell);
      if (unitHere == null) continue;
      if (cell == from) {
        drawSentry(canvas, unitHere.tier, r.center, u * 0.36, alpha: 0.25);
        continue;
      }
      final pop = unitHere.age < 1 ? 1 + 0.25 * math.sin(unitHere.age * math.pi) : 1.0;
      final kick = unitHere.recoil > 0 ? unitHere.recoil * u * 0.25 : 0.0;
      drawSentry(canvas, unitHere.tier, r.center + Offset(0, kick), u * 0.36 * pop);
      // Mergeable partner hint while dragging.
      if (from != null && cell != from && bastion.unitAt(from)?.tier == unitHere.tier) {
        _paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF7CFFB2).withValues(alpha: 0.4 + 0.3 * math.sin(_clock * 10));
        canvas.drawRRect(rr.deflate(3), _paint);
        _paint.style = PaintingStyle.fill;
      }
    }
  }

  void _drawBolts(Canvas canvas) {
    for (final b in _bolts) {
      final t = (b.life / _Bolt.duration).clamp(0.0, 1.0);
      final color = tierColor(b.tier).withValues(alpha: t);
      if (b.tier.isOdd) {
        // Archer: a streak.
        _paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 + b.tier * 0.4
          ..strokeCap = StrokeCap.round
          ..color = color;
        final head = Offset.lerp(b.from, b.to, 1 - t * 0.6)!;
        final tail = Offset.lerp(b.from, b.to, math.max(0, 0.75 - t * 0.6))!;
        canvas.drawLine(tail, head, _paint);
        _paint.style = PaintingStyle.fill;
      } else {
        // Mage: an orb.
        _paint.color = color;
        canvas.drawCircle(Offset.lerp(b.from, b.to, 1 - t * 0.7)!, 2.5 + b.tier * 0.5, _paint);
      }
    }
  }

  void _drawFloaters(Canvas canvas) {
    for (final f in _floaters) {
      CanvasText.draw(
        canvas,
        f.text,
        f.at - Offset(0, 30 * f.t + 18),
        size: 14,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: f.color.withValues(alpha: ((1 - f.t) * 10).round() / 10),
      );
    }
  }

  void _drawDragged(Canvas canvas) {
    final from = _dragFrom;
    final p = _dragPos;
    if (from == null || p == null) return;
    final unitHere = bastion.unitAt(from);
    if (unitHere == null) return;
    // Lift the sentry a little above the finger so it stays visible.
    drawSentry(canvas, unitHere.tier, p - Offset(0, unit * 0.35), unit * 0.42, shadow: true);
  }

  void _drawButton(Canvas canvas) {
    final r = summonButtonRect;
    final enabled = bastion.canSummon;
    final grow = _buttonPulse > 0 ? 1 + _buttonPulse * 0.25 : 1.0;
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: r.center, width: r.width * grow, height: r.height * grow),
      Radius.circular(r.height / 2),
    );
    canvas.drawRRect(rr.shift(const Offset(0, 4)), _paint..color = const Color(0x66000000));
    canvas.drawRRect(rr, _paint..color = enabled ? const Color(0xFF5BC0EB) : const Color(0xFF2C3A4C));
    final full = !bastion.hasEmptyCell;
    CanvasText.draw(
      canvas,
      full ? 'GRID FULL' : 'SUMMON',
      r.center - const Offset(0, 9),
      size: 18,
      align: Alignment.center,
      weight: FontWeight.w900,
      color: enabled ? const Color(0xFF0B1A2A) : Colors.white38,
    );
    CanvasText.draw(
      canvas,
      '\$${bastion.summonCost}',
      r.center + const Offset(0, 12),
      size: 14,
      align: Alignment.center,
      weight: FontWeight.w800,
      color: enabled
          ? const Color(0xFF3B2A00)
          : (bastion.coins < bastion.summonCost ? const Color(0xFFFF8A8A) : Colors.white38),
    );
  }

  void _drawHud(Canvas canvas) {
    final w = bastion;
    final boss = BastionWorld.isBossWave(w.displayWave);
    CanvasText.draw(
      canvas,
      'WAVE ${math.min(w.displayWave, w.finalWave)}/${w.finalWave}',
      Offset(16, hudTop),
      size: 18,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '\$${w.coins}',
      Offset(size.x - 16, hudTop),
      size: 20,
      align: Alignment.topRight,
      weight: FontWeight.w900,
      color: const Color(0xFFFFD23F),
    );
    CanvasText.draw(
      canvas,
      'LV $level · ${w.score}',
      Offset(size.x / 2, hudTop + 3),
      size: 13,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
    final bar = Rect.fromLTWH(16, hudTop + 30, size.x - 32, 10);
    final hpT = w.wallHp / BastionWorld.maxWallHp;
    drawBar(canvas, bar, hpT, Color.lerp(const Color(0xFFFF4D6D), const Color(0xFF7CFFB2), hpT)!);
    CanvasText.draw(
      canvas,
      'WALL ${w.wallHp}',
      Offset(bar.left + 6, bar.center.dy),
      size: 9,
      align: Alignment.centerLeft,
      weight: FontWeight.w900,
    );
    final laneMid = toScreen(BastionWorld.cols / 2, BastionWorld.wallY * 0.42);
    if (w.phase == BastionPhase.breakTime) {
      CanvasText.draw(
        canvas,
        boss ? 'BOSS WAVE ${w.displayWave}' : 'WAVE ${w.displayWave}',
        laneMid,
        size: 28,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: boss ? const Color(0xFFFF5D73) : Colors.white,
      );
      CanvasText.draw(
        canvas,
        'in ${w.breakTimer.ceil()}…',
        laneMid + const Offset(0, 26),
        size: 15,
        align: Alignment.center,
        color: Colors.white70,
      );
    }
    if (!w.isOver && w.wave <= 2 && w.merges == 0) {
      CanvasText.draw(
        canvas,
        'Summon sentries · drag twins together to merge',
        Offset(size.x / 2, summonButtonRect.top - 4),
        size: 12,
        align: Alignment.bottomCenter,
        color: Colors.white70,
        maxWidth: size.x - 24,
      );
    }
    if (w.isOver) {
      CanvasText.draw(
        canvas,
        w.won ? 'BASTION HOLDS!' : 'THE WALL FELL',
        laneMid,
        size: 32,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: w.won ? const Color(0xFFFFD23F) : const Color(0xFFFF4D6D),
      );
    }
  }
}

class _Bolt {
  _Bolt(this.from, this.to, this.tier);
  static const double duration = 0.14;
  final Offset from;
  final Offset to;
  final int tier;
  double life = duration;
}

class _Floater {
  _Floater(this.text, this.at, this.color);
  final String text;
  final Offset at;
  final Color color;
  double t = 0;
}

Path _poly(Offset c, int n, double r, double rot) {
  final p = Path();
  for (var i = 0; i < n; i++) {
    final a = rot + i * math.pi * 2 / n;
    final pt = c + Offset(math.cos(a), math.sin(a)) * r;
    if (i == 0) {
      p.moveTo(pt.dx, pt.dy);
    } else {
      p.lineTo(pt.dx, pt.dy);
    }
  }
  return p..close();
}

Path _star(Offset c, int points, double outer, double inner) {
  final p = Path();
  for (var i = 0; i < points * 2; i++) {
    final a = -math.pi / 2 + i * math.pi / points;
    final pt = c + Offset(math.cos(a), math.sin(a)) * (i.isEven ? outer : inner);
    if (i == 0) {
      p.moveTo(pt.dx, pt.dy);
    } else {
      p.lineTo(pt.dx, pt.dy);
    }
  }
  return p..close();
}

/// Draws a sentry of [tier] centred at [c] with radius [r]: the silhouette
/// gains a corner per tier (circle, triangle, square, ... stars), the colour
/// follows [kTierColors] and the tier number sits in the middle.
void drawSentry(Canvas canvas, int tier, Offset c, double r, {double alpha = 1, bool shadow = false}) {
  final color = tierColor(tier).withValues(alpha: alpha);
  final paint = Paint()..color = const Color(0x55000000).withValues(alpha: 0.33 * alpha);
  if (shadow) canvas.drawCircle(c + Offset(0, r * 0.5), r * 1.05, paint);
  final Path shape = switch (tier) {
    1 => Path()..addOval(Rect.fromCircle(center: c, radius: r * 0.85)),
    2 => _poly(c + Offset(0, r * 0.12), 3, r * 1.05, -math.pi / 2),
    3 => _poly(c, 4, r * 1.05, math.pi / 4),
    4 => _poly(c, 5, r, -math.pi / 2),
    5 => _poly(c, 6, r, 0),
    6 => _star(c, 5, r * 1.1, r * 0.55),
    7 => _star(c, 6, r * 1.1, r * 0.62),
    _ => _star(c, 8, r * 1.12, r * 0.72),
  };
  canvas.drawPath(shape.shift(Offset(0, r * 0.1)), paint);
  paint.color = color;
  canvas.drawPath(shape, paint);
  // Archers (odd tiers) wear a bow arc; mages (even tiers) a glowing core.
  paint
    ..color = const Color(0xFF0B1A2A).withValues(alpha: 0.55 * alpha)
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, r * 0.1);
  if (tier.isOdd) {
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.62), math.pi * 1.15, math.pi * 0.7, false, paint);
  } else {
    canvas.drawCircle(c, r * 0.5, paint);
  }
  paint.style = PaintingStyle.fill;
  if (tier >= 5) {
    paint.color = const Color(0xFFFFFFFF).withValues(alpha: 0.35 * alpha);
    canvas.drawCircle(c - Offset(r * 0.3, r * 0.35), r * 0.14, paint);
  }
  CanvasText.draw(
    canvas,
    '$tier',
    c,
    size: math.max(10, r * 0.75).roundToDouble(),
    align: Alignment.center,
    weight: FontWeight.w900,
    color: const Color(0xFF0B1A2A).withValues(alpha: alpha),
  );
}
