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
import 'dig_world.dart';

class DeepDigCartridge extends FlameCartridge<DeepDigGame> {
  const DeepDigCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'deep-dig',
    title: 'Deep Dig',
    tagline: 'Dig deeper. Hire foremen. Get rich while you nap.',
    description:
        'An idle mining manager. Miners fill crates in stacked shafts, a shared lift hauls the ore '
        'to the surface and a hauler sells it at the warehouse. Tap a station to run one work '
        'cycle, upgrade it for more output, dig deeper shafts for richer ore and hire foremen to '
        'automate everything. Foremen keep earning for up to two hours while you are away.',
    genre: 'Idle mining manager',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFFD4A24C),
    icon: Icons.construction_rounded,
    tags: ['idle', 'incremental', 'management', 'mining', 'casual', 'offline-earnings'],
    controls: [
      'Tap a shaft, the lift or the yard to run one work cycle',
      'Tap UP to upgrade a station, HIRE to automate it with a foreman',
      'Drag up/down to scroll the mine; x1 / x10 / MAX sets how many levels UP buys',
    ],
    mechanics: [
      'production chain',
      'tap to work',
      'exponential upgrades',
      'managers',
      'offline earnings',
      'contracts',
    ],
    goal:
        'Fulfil the contract: earn \$1M (then \$10M, \$100M, ...) in cash. Progress is saved; exit any time.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  DeepDigGame createGame(FlameCartridgeSession<DeepDigGame> session) => DeepDigGame(session);
}

/// How many levels an UP button buys.
enum BuyMode { x1, x10, max }

/// Ore colour of each shaft depth.
const List<Color> kOreColors = [
  Color(0xFFD9824A), // copper
  Color(0xFFC9D1DB), // silver
  Color(0xFFFFC53D), // gold
  Color(0xFF3DDC84), // emerald
  Color(0xFFFF4F6D), // ruby
  Color(0xFF4F8DFF), // sapphire
  Color(0xFFB57BFF), // amethyst
  Color(0xFF7DF3FF), // crystal
  Color(0xFFFF9EE0), // rose quartz
  Color(0xFFFFFFFF), // diamond
];

Color oreColor(int depth) => kOreColors[depth % kOreColors.length];

class DeepDigGame extends AsobiFlameGame {
  DeepDigGame(super.session, {this.clock}) : mine = DigWorld.fromJson(_stateOf(session)) {
    final raw = _stateOf(session);
    final savedAt = raw?['savedAt'];
    if (savedAt is num) {
      final away = _now.difference(DateTime.fromMillisecondsSinceEpoch(savedAt.toInt()));
      if (away > Duration.zero) {
        final r = mine.applyOffline(away);
        if (r.cash > 0) {
          welcome = r;
          _welcomeTime = 9;
        }
      }
    }
    _lastSales = mine.sales;
    _save();
  }

  /// Wall clock used for offline earnings (injectable for tests).
  final DateTime Function()? clock;

  /// The rules object (FlameGame already owns `world`).
  final DigWorld mine;
  final Sparks sparks = Sparks(capacity: 240);

  BuyMode buyMode = BuyMode.x1;

  /// Offline earnings shown in the "Welcome back" banner (null = hidden).
  OfflineReport? welcome;
  double _welcomeTime = 0;

  double scroll = 0;
  double _scrollVel = 0;
  Offset? _downPos;
  double _dragDist = 0;
  bool _dragging = false;

  double _clock = 0;
  double _saveTimer = 0;
  int _lastSales = 0;
  bool _reported = false;
  double _endDelay = 1.4;
  DateTime? _pausedAt;
  final List<_Floater> _floaters = [];
  final Map<int, double> _flash = {};

  static const double saveInterval = 10;

  DateTime get _now => (clock ?? DateTime.now)();

  static Map<String, Object?>? _stateOf(CartridgeSession session) {
    final raw = session.context.save.data['state'];
    if (raw is! Map) return null;
    try {
      return Map<String, Object?>.from(raw);
    } on Object {
      return null;
    }
  }

  bool get showingWelcome => welcome != null;

  @override
  int get entityCount => mine.entityCount + sparks.count + _floaters.length;

  @override
  Color backgroundColor() => const Color(0xFF17120E);

  // ------------------------------------------------------------- saving
  void _save() {
    session.context.save.data['state'] = {...mine.toJson(), 'savedAt': _now.millisecondsSinceEpoch};
    session.context.commitSave();
    _saveTimer = 0;
  }

  @override
  void pauseEngine() {
    _save();
    _pausedAt ??= _now;
    super.pauseEngine();
  }

  @override
  void resumeEngine() {
    super.resumeEngine();
    final since = _pausedAt;
    _pausedAt = null;
    if (since == null || _reported) return;
    final r = mine.applyOffline(_now.difference(since));
    if (r.cash > 0 && r.seconds >= 30) {
      welcome = r;
      _welcomeTime = 9;
    }
    _save();
  }

  // ------------------------------------------------------------- layout
  static const double _colL = 10;
  static const double _colR = 58;
  static const double _surfaceH = 214;
  static const double _groundY = 122;
  static const double _shaftH = 124;
  static const double _tunnelTop = 24;
  static const double _floorOff = 84;
  static const double _unlockH = 104;

  double get _barBottom => size.y - safePadding.bottom - 10;
  double get _barTop => _barBottom - 40;
  double get viewTop => hudTop + 70;
  double get viewBottom => _barTop - 8;
  Rect get viewRect => Rect.fromLTRB(0, viewTop, size.x, viewBottom);
  double get _contentH => _surfaceH + mine.shaftCount * _shaftH + _unlockH;
  double get maxScroll => math.max(0, _contentH - (viewBottom - viewTop));

  double _shaftY(int i) => _surfaceH + i * _shaftH;

  /// Content y of the elevator cage floor for each stop (0 = surface).
  double _stopY(int stop) => stop == 0 ? _groundY : _shaftY(stop - 1) + _floorOff;

  double _cageFloor(double pos) {
    final k = pos.floor().clamp(0, mine.shaftCount);
    if (k >= mine.shaftCount) return _stopY(mine.shaftCount);
    final f = pos - k;
    return _stopY(k) + (_stopY(k + 1) - _stopY(k)) * f;
  }

  Rect _toScreen(Rect content) => content.shift(Offset(0, viewTop - scroll));

  Rect _upgradeContent(int id) {
    if (id == DigWorld.elevatorId) return Rect.fromLTWH(_colR + 8, _surfaceH - 40, _panelW / 2 - 3, 32);
    if (id == DigWorld.haulerId) {
      return Rect.fromLTWH(_haulPanelL, _surfaceH - 40, _panelW / 2 - 3, 32);
    }
    final y = _shaftY(id) + _floorOff + 6;
    return Rect.fromLTWH(_colR + 8, y, (size.x - _colR - 24) * 0.56, 30);
  }

  Rect _managerContent(int id) {
    if (id == DigWorld.elevatorId) {
      return Rect.fromLTWH(_colR + 8 + _panelW / 2 + 3, _surfaceH - 40, _panelW / 2 - 3, 32);
    }
    if (id == DigWorld.haulerId) {
      return Rect.fromLTWH(_haulPanelL + _panelW / 2 + 3, _surfaceH - 40, _panelW / 2 - 3, 32);
    }
    final up = _upgradeContent(id);
    return Rect.fromLTRB(up.right + 8, up.top, size.x - 10, up.bottom);
  }

  double get _panelW => (size.x - _colR - 8 - 10 - 8) / 2;
  double get _haulPanelL => _colR + 8 + _panelW + 8;

  Rect _stationContent(int id) {
    if (id == DigWorld.elevatorId) {
      return Rect.fromLTRB(_colL - 6, 0, _colR + 4, _stopY(mine.shaftCount) + 8);
    }
    if (id == DigWorld.haulerId) return Rect.fromLTRB(_colR + 6, 10, size.x - 6, _groundY + 6);
    final y = _shaftY(id);
    return Rect.fromLTRB(_colR + 4, y + 2, size.x - 6, y + _floorOff + 2);
  }

  Rect get _unlockContent {
    final y = _shaftY(mine.shaftCount);
    return Rect.fromCenter(center: Offset(size.x / 2 + 20, y + _unlockH / 2), width: 240, height: 46);
  }

  /// On-screen rect of station [id]'s UP button.
  Rect upgradeButtonRect(int id) => _toScreen(_upgradeContent(id));

  /// On-screen rect of station [id]'s HIRE button.
  Rect managerButtonRect(int id) => _toScreen(_managerContent(id));

  /// On-screen tap area of station [id] (shaft tunnel, lift column, yard).
  Rect stationRect(int id) => _toScreen(_stationContent(id));

  /// On-screen rect of the "dig a new shaft" button.
  Rect get unlockButtonRect => _toScreen(_unlockContent);

  /// On-screen rect of a buy-mode toggle segment.
  Rect buyToggleRect(BuyMode m) {
    const w = 62.0;
    final left = size.x - 12 - w * 3;
    return Rect.fromLTWH(left + m.index * w, _barTop, w, _barBottom - _barTop);
  }

  int _buyCount(int id) => switch (buyMode) {
    BuyMode.x1 => 1,
    BuyMode.x10 => 10,
    BuyMode.max => math.max(1, mine.affordableLevels(id)),
  };

  void _clampScroll() => scroll = scroll.clamp(0.0, maxScroll);

  // -------------------------------------------------------------- input
  @override
  void onPointerDown(Vector2 position) {
    _downPos = Offset(position.x, position.y);
    _dragDist = 0;
    _dragging = false;
    _scrollVel = 0;
  }

  @override
  void onPointerMove(Vector2 position, Vector2 delta) {
    final down = _downPos;
    if (down == null) return;
    _dragDist += delta.length;
    if (!_dragging && _dragDist > 10 && viewRect.contains(down)) _dragging = true;
    if (_dragging) {
      scroll -= delta.y;
      _clampScroll();
      _scrollVel = (-delta.y * 60).clamp(-3000.0, 3000.0);
    }
  }

  @override
  void onPointerUp(Vector2 position) {
    final down = _downPos;
    _downPos = null;
    if (down == null) return;
    if (!_dragging) {
      _scrollVel = 0;
      tapAt(down);
    }
    _dragging = false;
  }

  /// Handles a tap (pointer down + up without a drag) at screen point [p].
  void tapAt(Offset p) {
    if (size.x <= 0 || _reported) return;
    if (welcome != null) {
      welcome = null;
      audio.play(Sfx.coin);
      return;
    }
    for (final m in BuyMode.values) {
      if (buyToggleRect(m).contains(p)) {
        buyMode = m;
        audio.play(Sfx.tap);
        audio.haptic(HapticKind.selection);
        return;
      }
    }
    if (!viewRect.contains(p)) return;
    final ids = [DigWorld.elevatorId, DigWorld.haulerId, for (var i = 0; i < mine.shaftCount; i++) i];
    for (final id in ids) {
      final up = upgradeButtonRect(id);
      if (up.contains(p)) {
        final n = mine.upgrade(id, _buyCount(id));
        if (n > 0) {
          audio.play(Sfx.powerup);
          audio.haptic(HapticKind.light);
          _burst(up.center, const Color(0xFF8CF5A0), 10);
        } else {
          _fail(id);
        }
        return;
      }
      final mg = managerButtonRect(id);
      if (mg.contains(p)) {
        if (mine.managerOf(id)) return;
        if (mine.hireManager(id)) {
          audio.play(Sfx.merge);
          audio.haptic(HapticKind.medium);
          _burst(mg.center, const Color(0xFFFFD166), 18);
        } else {
          _fail(id);
        }
        return;
      }
    }
    if (mine.canDigDeeper && unlockButtonRect.contains(p)) {
      if (mine.unlockShaft()) {
        audio.play(Sfx.whoosh);
        audio.haptic(HapticKind.heavy);
        _burst(unlockButtonRect.center, oreColor(mine.shaftCount - 1), 30);
        _save();
      } else {
        _flash[-99] = 0.4;
        audio.play(Sfx.thud);
      }
      return;
    }
    for (final id in ids) {
      if (!stationRect(id).contains(p)) continue;
      if (mine.managerOf(id)) return;
      if (mine.tapStation(id)) {
        audio.play(Sfx.tap);
        audio.haptic(HapticKind.selection);
      } else if (!mine.isWorking(id)) {
        audio.play(Sfx.thud);
      }
      return;
    }
  }

  void _fail(int id) {
    _flash[id] = 0.4;
    audio.play(Sfx.thud);
    audio.haptic(HapticKind.light);
  }

  void _burst(Offset at, Color color, int n) {
    final reduced = ctx.settings.reducedEffects;
    sparks.burst(at.dx, at.dy, reduced ? math.max(2, n ~/ 4) : n, color, speed: 160, life: 0.45);
  }

  // ------------------------------------------------------------- update
  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    mine.update(dt);
    sparks.update(dt);
    if (mine.sales != _lastSales) {
      _lastSales = mine.sales;
      audio.play(Sfx.coin);
      _floaters.add(_Floater('+${formatCash(mine.lastSale)}', Offset(size.x - 62, _groundY - 84)));
      if (size.x > 0) {
        final w = _toScreen(Rect.fromLTWH(size.x - 62, _groundY - 50, 1, 1)).topLeft;
        if (viewRect.contains(w)) _burst(w, const Color(0xFFFFD166), 8);
      }
    }
    for (final f in _floaters) {
      f.t += dt;
    }
    _floaters.removeWhere((f) => f.t > 1.4);
    for (final k in _flash.keys.toList()) {
      final v = _flash[k]! - dt;
      if (v <= 0) {
        _flash.remove(k);
      } else {
        _flash[k] = v;
      }
    }
    if (welcome != null) {
      _welcomeTime -= dt;
      if (_welcomeTime <= 0) welcome = null;
    }
    if (_downPos == null && _scrollVel.abs() > 4) {
      scroll += _scrollVel * dt;
      _scrollVel *= math.exp(-dt * 5);
      _clampScroll();
    }
    _saveTimer += dt;
    if (_saveTimer >= saveInterval && !_reported) _save();
    if (mine.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) _report();
    }
  }

  void _report() {
    _reported = true;
    final c = mine.contract;
    final score = mine.score;
    final earned = mine.contractEarned;
    final idle = mine.idleIncomePerSecond;
    mine.advanceContract();
    _save();
    audio.play(Sfx.win);
    finish(
      RunResult(
        score: score,
        won: true,
        headline: 'Contract $c fulfilled! Contract ${c + 1} pays out at ${formatCash(mine.contractTarget)}.',
        details: {
          'Contract': '$c',
          'Cash earned': formatCash(earned),
          'Shafts': '${mine.shaftCount}',
          'Idle income': '${formatCash(idle)}/s',
          'Next target': formatCash(mine.contractTarget),
        },
      ),
    );
  }

  // ------------------------------------------------------------- render
  final Paint _p = Paint();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (size.x <= 0 || size.y <= 0) return;
    _clampScroll();
    canvas.save();
    canvas.clipRect(viewRect);
    canvas.translate(0, viewTop - scroll);
    final visTop = scroll - 20;
    final visBottom = scroll + (viewBottom - viewTop) + 20;
    if (visTop < _surfaceH) _drawSurface(canvas);
    for (var i = 0; i < mine.shaftCount; i++) {
      final y = _shaftY(i);
      if (y + _shaftH < visTop || y > visBottom) continue;
      _drawShaft(canvas, i);
    }
    _drawUnlockRow(canvas);
    _drawShaftColumn(canvas);
    _drawElevatorCage(canvas);
    for (final f in _floaters) {
      final a = (1 - f.t / 1.4).clamp(0.0, 1.0);
      CanvasText.draw(
        canvas,
        f.text,
        f.at.translate(0, -f.t * 30),
        size: 15,
        align: Alignment.center,
        color: const Color(0xFFFFD166).withValues(alpha: a),
        weight: FontWeight.w900,
      );
    }
    canvas.restore();
    sparks.render(canvas);
    _drawHud(canvas);
    _drawBottomBar(canvas);
    if (mine.isOver) _drawContractDone(canvas);
    if (welcome != null) _drawWelcome(canvas, welcome!);
  }

  void _fill(Canvas canvas, Rect r, Color c, [double radius = 0]) {
    _p
      ..style = PaintingStyle.fill
      ..color = c;
    if (radius > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)), _p);
    } else {
      canvas.drawRect(r, _p);
    }
  }

  void _line(Canvas canvas, Offset a, Offset b, Color c, double w) {
    _p
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = c;
    canvas.drawLine(a, b, _p);
    _p.style = PaintingStyle.fill;
  }

  Color _rockColor(int depth) {
    final t = (depth / (DigWorld.maxShafts - 1)).clamp(0.0, 1.0);
    return Color.lerp(const Color(0xFF6B4A33), const Color(0xFF2E2238), t)!;
  }

  void _drawSurface(Canvas canvas) {
    final w = size.x;
    // Sky.
    final sky = Rect.fromLTWH(0, 0, w, _groundY);
    canvas.drawRect(
      sky,
      Paint()
        ..shader = Gradient.linear(Offset.zero, const Offset(0, _groundY), const [
          Color(0xFF2A4B7C),
          Color(0xFFE89A5E),
        ]),
    );
    _fill(canvas, Rect.fromCircle(center: Offset(w * 0.55, 46), radius: 16), const Color(0xFFFFE29A));
    // Far hills.
    final hills = Path()..moveTo(0, _groundY);
    for (var x = 0.0; x <= w; x += 20) {
      hills.lineTo(x, _groundY - 18 - 10 * math.sin(x / 47) - 6 * math.sin(x / 13));
    }
    hills
      ..lineTo(w, _groundY)
      ..close();
    _p.color = const Color(0xFF5E4A6E);
    canvas.drawPath(hills, _p);
    // Ground strip + panel dirt.
    _fill(canvas, Rect.fromLTWH(0, _groundY, w, 8), const Color(0xFF6E8B3D));
    _fill(canvas, Rect.fromLTWH(0, _groundY + 8, w, _surfaceH - _groundY - 8), const Color(0xFF7A5638));

    // Headframe over the lift column.
    const cx = (_colL + _colR) / 2;
    const top = 20.0;
    const frame = Color(0xFF3B2A20);
    _line(canvas, const Offset(_colL - 4, _groundY), const Offset(cx, top), frame, 4);
    _line(canvas, const Offset(_colR + 4, _groundY), const Offset(cx, top), frame, 4);
    _line(canvas, const Offset(_colL + 4, _groundY - 40), const Offset(_colR - 4, _groundY - 40), frame, 3);
    _p
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF9AA4B2);
    canvas.drawCircle(const Offset(cx, top), 9, _p);
    _p.style = PaintingStyle.fill;
    canvas.save();
    canvas.translate(cx, top);
    canvas.rotate(_clock * (mine.isWorking(DigWorld.elevatorId) ? 4 : 0));
    _line(canvas, const Offset(-8, 0), const Offset(8, 0), const Color(0xFF9AA4B2), 2);
    canvas.restore();

    // Surface bin with the lifted ore.
    const bin = Rect.fromLTWH(_colR + 8, _groundY - 22, 40, 22);
    final stockT = (mine.surfaceStock / math.max(1, mine.haulerCapacity * 2)).clamp(0.0, 1.0);
    if (stockT > 0) {
      final pile = Path()
        ..moveTo(bin.left + 3, bin.top + 4)
        ..quadraticBezierTo(bin.center.dx, bin.top + 4 - 18 * stockT, bin.right - 3, bin.top + 4)
        ..close();
      _p.color = oreColor(0);
      canvas.drawPath(pile, _p);
    }
    _fill(canvas, bin, const Color(0xFF8B6B4A), 3);
    _line(canvas, bin.topLeft.translate(0, 8), bin.topRight.translate(0, 8), const Color(0xFF5A4030), 2);
    CanvasText.draw(
      canvas,
      shortNumber(mine.surfaceStock),
      bin.center.translate(0, 4),
      size: 10,
      align: Alignment.center,
    );

    // Warehouse.
    final wh = Rect.fromLTWH(w - 100, _groundY - 62, 88, 62);
    final roof = Path()
      ..moveTo(wh.left - 6, wh.top)
      ..lineTo(wh.center.dx, wh.top - 22)
      ..lineTo(wh.right + 6, wh.top)
      ..close();
    _p.color = const Color(0xFF8E3B2E);
    canvas.drawPath(roof, _p);
    _fill(canvas, wh, const Color(0xFFD9C3A0));
    _fill(canvas, Rect.fromLTWH(wh.left + 10, wh.bottom - 32, 30, 32), const Color(0xFF5C4033));
    _fill(canvas, Rect.fromLTWH(wh.right - 34, wh.top + 10, 22, 16), const Color(0xFF8FC4E8));
    CanvasText.draw(
      canvas,
      'WAREHOUSE',
      Offset(wh.center.dx, wh.top + 2),
      size: 9,
      align: Alignment.topCenter,
      color: const Color(0xFF3B2A20),
    );

    // Hauler with a cart walking between bin and warehouse.
    final x0 = bin.right + 20;
    final x1 = wh.left - 4;
    final hx = x0 + (x1 - x0) * mine.haulerPos;
    final out = mine.haulerPhase == TripPhase.out;
    final moving = mine.haulerPhase != TripPhase.idle;
    final cartX = out ? hx + 16 : hx - 16;
    final cart = Rect.fromLTWH(cartX - 11, _groundY - 16, 22, 11);
    if (mine.haulerLoad > 0) {
      _fill(canvas, Rect.fromLTWH(cart.left + 2, cart.top - 5, 18, 7), oreColor(0), 4);
    }
    _fill(canvas, cart, const Color(0xFF6D7B8C), 2);
    _fill(
      canvas,
      Rect.fromCircle(center: Offset(cartX - 6, _groundY - 3), radius: 3),
      const Color(0xFF222222),
    );
    _fill(
      canvas,
      Rect.fromCircle(center: Offset(cartX + 6, _groundY - 3), radius: 3),
      const Color(0xFF222222),
    );
    _drawWorker(
      canvas,
      Offset(hx, _groundY),
      walk: moving ? _clock * 10 : 0,
      facingRight: out || !moving,
      shirt: const Color(0xFF3D8BD9),
    );
    if (!mine.haulerManager && !moving && mine.surfaceStock > 0) {
      _tapHint(canvas, Offset(hx, _groundY - 40));
    }

    // Station panels.
    _drawPanel(
      canvas,
      DigWorld.elevatorId,
      Rect.fromLTWH(_colR + 8, _groundY + 12, _panelW, _surfaceH - _groundY - 16),
      'LIFT  Lv ${mine.elevatorLevel}',
      'cap ${shortNumber(mine.elevatorCapacity)} · ${mine.elevatorSpeed.toStringAsFixed(1)} rows/s',
    );
    _drawPanel(
      canvas,
      DigWorld.haulerId,
      Rect.fromLTWH(_haulPanelL, _groundY + 12, _panelW, _surfaceH - _groundY - 16),
      'HAULER  Lv ${mine.haulerLevel}',
      'cap ${shortNumber(mine.haulerCapacity)} · ${mine.haulerWalk.toStringAsFixed(1)}s walk',
    );
  }

  void _drawPanel(Canvas canvas, int id, Rect r, String title, String stats) {
    _fill(canvas, r, const Color(0x55000000), 10);
    CanvasText.draw(canvas, title, Offset(r.left + 8, r.top + 4), size: 12, weight: FontWeight.w900);
    CanvasText.draw(
      canvas,
      stats,
      Offset(r.left + 8, r.top + 20),
      size: 10,
      color: Colors.white70,
      weight: FontWeight.w600,
    );
    _drawUpgradeButton(canvas, id, _upgradeContent(id), compact: true);
    _drawManagerButton(canvas, id, _managerContent(id), compact: true);
  }

  void _drawUpgradeButton(Canvas canvas, int id, Rect r, {bool compact = false}) {
    final atMax = mine.levelOf(id) >= DigWorld.maxLevel;
    final n = _buyCount(id);
    final cost = mine.upgradeCost(id, n);
    final ok = !atMax && cost <= mine.cash;
    final flash = _flash[id];
    _fill(canvas, r, ok ? const Color(0xFF2FA85A) : const Color(0xFF3A3530), 9);
    if (flash != null) {
      _p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFF4D6D).withValues(alpha: (flash / 0.4).clamp(0.0, 1.0));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(9)), _p);
      _p.style = PaintingStyle.fill;
    }
    final label = atMax
        ? 'MAX LV'
        : compact
        ? 'UP ${formatCash(cost)}'
        : 'UP x$n · ${formatCash(cost)}';
    CanvasText.draw(
      canvas,
      label,
      r.center,
      size: compact ? 11 : 13,
      align: Alignment.center,
      weight: FontWeight.w800,
      color: ok ? Colors.white : Colors.white54,
    );
  }

  void _drawManagerButton(Canvas canvas, int id, Rect r, {bool compact = false}) {
    if (mine.managerOf(id)) {
      _fill(canvas, r, const Color(0xFF3B2F5C), 9);
      _drawForeman(canvas, Offset(r.left + 14, r.bottom - 3), scale: 0.8);
      CanvasText.draw(
        canvas,
        'AUTO',
        r.center.translate(8, 0),
        size: compact ? 11 : 12,
        align: Alignment.center,
        weight: FontWeight.w800,
        color: const Color(0xFFFFD166),
      );
      return;
    }
    final cost = mine.managerCost(id);
    final ok = cost <= mine.cash;
    _fill(canvas, r, ok ? const Color(0xFFB8860B) : const Color(0xFF3A3530), 9);
    CanvasText.draw(
      canvas,
      'HIRE ${formatCash(cost)}',
      r.center,
      size: compact ? 11 : 12,
      align: Alignment.center,
      weight: FontWeight.w800,
      color: ok ? Colors.white : Colors.white54,
      maxWidth: r.width - 4,
    );
  }

  void _drawShaftColumn(Canvas canvas) {
    final bottom = _stopY(mine.shaftCount) + 10;
    _fill(canvas, Rect.fromLTRB(_colL, _groundY, _colR, bottom), const Color(0xFF1E1712));
    for (final x in [_colL + 3, _colR - 3]) {
      _line(canvas, Offset(x, _groundY), Offset(x, bottom), const Color(0xFF4A3A2E), 2);
    }
  }

  void _drawElevatorCage(Canvas canvas) {
    const cx = (_colL + _colR) / 2;
    final floor = _cageFloor(mine.elevatorPos);
    final cage = Rect.fromLTRB(_colL + 6, floor - 34, _colR - 6, floor);
    _line(canvas, const Offset(cx, 20), Offset(cx, cage.top), const Color(0xFFB0B8C4), 1.5);
    _fill(canvas, cage, const Color(0xFF8C96A3), 3);
    _fill(canvas, cage.deflate(3), const Color(0xFF2B2F36), 2);
    final t = (mine.elevatorLoad / mine.elevatorCapacity).clamp(0.0, 1.0);
    if (t > 0) {
      final h = (cage.height - 8) * t;
      _fill(
        canvas,
        Rect.fromLTRB(cage.left + 4, cage.bottom - 4 - h, cage.right - 4, cage.bottom - 4),
        oreColor(0),
      );
    }
    final flash = _flash[DigWorld.elevatorId];
    if (flash != null) {
      _p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFF4D6D).withValues(alpha: (flash / 0.4).clamp(0.0, 1.0));
      canvas.drawRect(cage, _p);
      _p.style = PaintingStyle.fill;
    }
    if (mine.elevatorManager) {
      _drawForeman(canvas, Offset(cx, cage.bottom - 4), scale: 0.6);
    } else if (!mine.isWorking(DigWorld.elevatorId) && mine.shafts.any((s) => s.crate > 0.5)) {
      _tapHint(canvas, Offset(cx, cage.top - 14));
    }
  }

  void _drawShaft(Canvas canvas, int i) {
    final w = size.x;
    final y = _shaftY(i);
    final s = mine.shafts[i];
    final ore = oreColor(i);
    _fill(canvas, Rect.fromLTWH(0, y, w, _shaftH), _rockColor(i));
    // Rock speckles.
    for (var k = 0; k < 7; k++) {
      final sx = _colR + 10 + ((k * 73 + i * 41) % math.max(1.0, w - _colR - 20)).toDouble();
      final sy = y + 6 + ((k * 37 + i * 19) % 14);
      _fill(canvas, Rect.fromCircle(center: Offset(sx, sy), radius: 2), const Color(0x22FFFFFF));
    }
    // Tunnel.
    final tunnel = Rect.fromLTRB(_colR, y + _tunnelTop, w - 8, y + _floorOff);
    _fill(canvas, tunnel, const Color(0xFF261C16));
    _fill(
      canvas,
      Rect.fromLTRB(tunnel.left, tunnel.bottom - 4, tunnel.right, tunnel.bottom),
      const Color(0xFF4A3628),
    );
    // Support beams.
    for (var bx = tunnel.left + 60; bx < tunnel.right - 40; bx += 90) {
      _line(canvas, Offset(bx, tunnel.top), Offset(bx, tunnel.bottom), const Color(0xFF5A3F28), 3);
    }
    _line(canvas, tunnel.topLeft, tunnel.topRight, const Color(0xFF5A3F28), 3);
    // Lamp.
    _fill(
      canvas,
      Rect.fromCircle(center: Offset(tunnel.center.dx, tunnel.top + 6), radius: 3),
      const Color(0xFFFFE29A),
    );
    // Rock face with ore.
    final face = Path()..moveTo(tunnel.right, tunnel.top);
    for (var k = 0; k <= 6; k++) {
      final fy = tunnel.top + (tunnel.height) * k / 6;
      face.lineTo(tunnel.right - 14 - (k.isEven ? 0 : 7), fy);
    }
    face
      ..lineTo(tunnel.right, tunnel.bottom)
      ..close();
    _p.color = _rockColor(i);
    canvas.drawPath(face, _p);
    for (var k = 0; k < 4; k++) {
      _fill(
        canvas,
        Rect.fromCircle(
          center: Offset(tunnel.right - 6 - (k % 2) * 5, tunnel.top + 10 + k * 13),
          radius: 3.2,
        ),
        ore,
      );
    }
    // Crate by the lift.
    final crate = Rect.fromLTWH(_colR + 6, tunnel.bottom - 26, 36, 22);
    final storage = mine.shaftStorage(i);
    final fillT = storage > 0 ? (s.crate / storage).clamp(0.0, 1.0) : 0.0;
    _fill(canvas, crate, const Color(0xFF9C7448), 2);
    if (fillT > 0) {
      final h = (crate.height - 4) * fillT;
      _fill(
        canvas,
        Rect.fromLTRB(crate.left + 3, crate.bottom - 2 - h, crate.right - 3, crate.bottom - 2),
        ore,
        2,
      );
    }
    _line(canvas, crate.topLeft, crate.bottomRight, const Color(0x55000000), 1.5);
    CanvasText.draw(
      canvas,
      '${shortNumber(s.crate)}/${shortNumber(storage)}',
      Offset(crate.center.dx, crate.top - 2),
      size: 9,
      align: Alignment.bottomCenter,
      color: fillT >= 0.999 ? const Color(0xFFFF8A8A) : Colors.white70,
    );
    // Miner.
    final startX = crate.right + 30;
    final faceX = tunnel.right - 30;
    final p = mine.shaftProgress(i);
    double mx;
    var walk = 0.0;
    var right = true;
    var swing = 0.0;
    var carry = false;
    if (!s.working) {
      mx = startX;
    } else if (p < 0.35) {
      mx = startX + (faceX - startX) * (p / 0.35);
      walk = _clock * 10;
    } else if (p < 0.7) {
      mx = faceX;
      swing = math.sin(_clock * 14);
    } else {
      mx = faceX - (faceX - startX) * ((p - 0.7) / 0.3);
      walk = _clock * 10;
      right = false;
      carry = true;
    }
    if (s.manager) _drawForeman(canvas, Offset(crate.right + 12, tunnel.bottom - 3));
    _drawWorker(
      canvas,
      Offset(mx, tunnel.bottom - 3),
      walk: walk,
      facingRight: right,
      shirt: const Color(0xFFE07A2E),
      pick: s.working && !carry,
      swing: swing,
      sack: carry ? ore : null,
    );
    if (s.working && p >= 0.35 && p < 0.7 && ((_clock * 7).floor() % 2 == 0)) {
      _fill(canvas, Rect.fromCircle(center: Offset(faceX + 14, tunnel.bottom - 22), radius: 2), ore);
    }
    // Labels.
    CanvasText.draw(
      canvas,
      'SHAFT ${i + 1}  ·  Lv ${s.level}',
      Offset(_colR + 8, y + 4),
      size: 12,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      '+${shortNumber(mine.shaftRate(i))}/s',
      Offset(w - 12, y + 5),
      size: 11,
      align: Alignment.topRight,
      color: ore,
    );
    if (!s.manager && !s.working) _tapHint(canvas, Offset(startX, tunnel.top + 14));
    _drawUpgradeButton(canvas, i, _upgradeContent(i));
    _drawManagerButton(canvas, i, _managerContent(i), compact: size.x < 360);
  }

  void _drawUnlockRow(Canvas canvas) {
    final y = _shaftY(mine.shaftCount);
    final w = size.x;
    _fill(canvas, Rect.fromLTWH(0, y, w, _unlockH), const Color(0xFF120E0B));
    for (var k = 0; k < 10; k++) {
      final sx = 20 + ((k * 97) % math.max(1.0, w - 40)).toDouble();
      _fill(
        canvas,
        Rect.fromCircle(center: Offset(sx, y + 14 + (k * 29) % 70), radius: 2.5),
        const Color(0x18FFFFFF),
      );
    }
    if (!mine.canDigDeeper) {
      CanvasText.draw(
        canvas,
        'BEDROCK · the mine is fully dug',
        Offset(w / 2, y + _unlockH / 2),
        size: 13,
        align: Alignment.center,
        color: Colors.white54,
      );
      return;
    }
    final r = _unlockContent;
    final ok = mine.unlockCost <= mine.cash;
    _fill(canvas, r, ok ? oreColor(mine.shaftCount) : const Color(0xFF3A3530), 14);
    final flash = _flash[-99];
    if (flash != null) {
      _p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFF4D6D).withValues(alpha: (flash / 0.4).clamp(0.0, 1.0));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(14)), _p);
      _p.style = PaintingStyle.fill;
    }
    CanvasText.draw(
      canvas,
      'DIG SHAFT ${mine.shaftCount + 1}  ·  ${formatCash(mine.unlockCost)}',
      r.center,
      size: 14,
      align: Alignment.center,
      weight: FontWeight.w900,
      color: ok ? const Color(0xFF1B1410) : Colors.white54,
    );
    CanvasText.draw(
      canvas,
      'richer ore: ${shortNumber(DigWorld.shaftRateAt(mine.shaftCount, 1))}/s at Lv 1',
      Offset(r.center.dx, r.bottom + 6),
      size: 10,
      align: Alignment.topCenter,
      color: Colors.white54,
    );
  }

  void _tapHint(Canvas canvas, Offset at) {
    final a = 0.55 + 0.45 * math.sin(_clock * 6);
    CanvasText.draw(
      canvas,
      'TAP',
      at,
      size: 11,
      align: Alignment.center,
      weight: FontWeight.w900,
      color: const Color(0xFFFFD166).withValues(alpha: a),
    );
  }

  /// A little miner: helmet with lamp, shirt, swinging legs.
  void _drawWorker(
    Canvas canvas,
    Offset feet, {
    double walk = 0,
    bool facingRight = true,
    Color shirt = const Color(0xFFE07A2E),
    bool pick = false,
    double swing = 0,
    Color? sack,
  }) {
    final dir = facingRight ? 1.0 : -1.0;
    final legA = math.sin(walk) * 4;
    final hip = feet.translate(0, -10);
    _line(canvas, hip, feet.translate(legA, 0), const Color(0xFF3A3F55), 3);
    _line(canvas, hip, feet.translate(-legA, 0), const Color(0xFF3A3F55), 3);
    final body = Rect.fromCenter(center: feet.translate(0, -15), width: 10, height: 12);
    if (sack != null) {
      _fill(
        canvas,
        Rect.fromCircle(center: body.center.translate(-dir * 7, -2), radius: 6),
        const Color(0xFF8A6A45),
      );
      _fill(canvas, Rect.fromCircle(center: body.center.translate(-dir * 7, -6), radius: 2.5), sack);
    }
    _fill(canvas, body, shirt, 3);
    final head = feet.translate(0, -25);
    _fill(canvas, Rect.fromCircle(center: head, radius: 4.5), const Color(0xFFF1C27D));
    // Helmet + lamp.
    canvas.drawArc(
      Rect.fromCircle(center: head.translate(0, -1), radius: 5.5),
      math.pi,
      math.pi,
      true,
      _p..color = const Color(0xFFFFC107),
    );
    _fill(
      canvas,
      Rect.fromCircle(center: head.translate(dir * 4.5, -3), radius: 1.6),
      const Color(0xFFFFFFE0),
    );
    if (pick) {
      final hand = body.center.translate(dir * 5, -1);
      final ang = -math.pi / 3 + swing * 0.9;
      final tip = hand + Offset(math.cos(ang) * dir, math.sin(ang)) * 12;
      _line(canvas, hand, tip, const Color(0xFF8B5A2B), 2);
      _line(canvas, tip.translate(-dir * 4, -2), tip.translate(dir * 4, 2), const Color(0xFFB0B8C4), 2.5);
    }
  }

  /// A foreman (manager): suit, tie and a clipboard.
  void _drawForeman(Canvas canvas, Offset feet, {double scale = 1}) {
    canvas.save();
    canvas.translate(feet.dx, feet.dy);
    canvas.scale(scale);
    _line(canvas, const Offset(-2, -10), const Offset(-2, 0), const Color(0xFF22222C), 3);
    _line(canvas, const Offset(2, -10), const Offset(2, 0), const Color(0xFF22222C), 3);
    _fill(
      canvas,
      Rect.fromCenter(center: const Offset(0, -15), width: 11, height: 12),
      const Color(0xFF34344A),
      3,
    );
    _line(canvas, const Offset(0, -20), const Offset(0, -13), const Color(0xFFE63946), 2);
    _fill(canvas, Rect.fromCircle(center: const Offset(0, -25), radius: 4.5), const Color(0xFFE0AC69));
    _fill(canvas, const Rect.fromLTWH(-6, -31, 12, 3), const Color(0xFF22222C), 1);
    _fill(canvas, const Rect.fromLTWH(5, -18, 6, 8), const Color(0xFFF5F0E6), 1);
    canvas.restore();
  }

  void _drawHud(Canvas canvas) {
    final w = size.x;
    _fill(canvas, Rect.fromLTWH(0, hudTop - 6, w, viewTop - hudTop + 4), const Color(0xFF17120E));
    CanvasText.draw(
      canvas,
      formatCash(mine.cash),
      Offset(16, hudTop - 4),
      size: 26,
      weight: FontWeight.w900,
      color: const Color(0xFFFFD166),
    );
    CanvasText.draw(
      canvas,
      '+${formatCash(mine.incomePerSecond)}/s',
      Offset(w - 16, hudTop - 2),
      size: 15,
      align: Alignment.topRight,
      color: const Color(0xFF8CF5A0),
      weight: FontWeight.w800,
    );
    CanvasText.draw(
      canvas,
      'idle ${formatCash(mine.idleIncomePerSecond)}/s',
      Offset(w - 16, hudTop + 17),
      size: 11,
      align: Alignment.topRight,
      color: Colors.white60,
    );
    CanvasText.draw(
      canvas,
      'CONTRACT ${mine.contract}  ·  ${formatCash(mine.contractEarned)} / ${formatCash(mine.contractTarget)}',
      Offset(16, hudTop + 32),
      size: 11,
      color: Colors.white70,
      weight: FontWeight.w700,
    );
    drawBar(
      canvas,
      Rect.fromLTWH(16, hudTop + 50, w - 32, 9),
      mine.contractProgress,
      const Color(0xFFD4A24C),
    );
  }

  void _drawBottomBar(Canvas canvas) {
    final w = size.x;
    _fill(canvas, Rect.fromLTRB(0, _barTop - 6, w, size.y), const Color(0xFF17120E));
    final hint = mine.totalEarned < 40
        ? 'Tap shaft, lift, then yard to sell ore'
        : mine.cash >= mine.unlockCost && mine.canDigDeeper
        ? 'A deeper shaft is affordable: scroll down'
        : 'Drag to scroll the mine';
    CanvasText.draw(
      canvas,
      hint,
      Offset(12, (_barTop + _barBottom) / 2),
      size: 11,
      align: Alignment.centerLeft,
      color: Colors.white60,
      maxWidth: buyToggleRect(BuyMode.x1).left - 18,
    );
    for (final m in BuyMode.values) {
      final r = buyToggleRect(m).deflate(2);
      final on = m == buyMode;
      _fill(canvas, r, on ? const Color(0xFFD4A24C) : const Color(0xFF3A3530), 10);
      CanvasText.draw(
        canvas,
        switch (m) {
          BuyMode.x1 => 'x1',
          BuyMode.x10 => 'x10',
          BuyMode.max => 'MAX',
        },
        r.center,
        size: 14,
        align: Alignment.center,
        weight: FontWeight.w900,
        color: on ? const Color(0xFF1B1410) : Colors.white70,
      );
    }
  }

  void _drawContractDone(Canvas canvas) {
    final c = Offset(size.x / 2, size.y * 0.42);
    _fill(canvas, Rect.fromCenter(center: c, width: size.x - 40, height: 90), const Color(0xDD17120E), 18);
    CanvasText.draw(
      canvas,
      'CONTRACT COMPLETE!',
      c.translate(0, -12),
      size: 26,
      align: Alignment.center,
      weight: FontWeight.w900,
      color: const Color(0xFFFFD166),
    );
    CanvasText.draw(
      canvas,
      '${formatCash(mine.contractEarned)} delivered',
      c.translate(0, 20),
      size: 14,
      align: Alignment.center,
      color: Colors.white70,
    );
  }

  void _drawWelcome(Canvas canvas, OfflineReport r) {
    _fill(canvas, Rect.fromLTWH(0, 0, size.x, size.y), const Color(0x99000000));
    final c = Offset(size.x / 2, size.y * 0.45);
    final card = Rect.fromCenter(center: c, width: math.min(320, size.x - 32), height: 180);
    _fill(canvas, card, const Color(0xFF2A2019), 20);
    _p
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFD4A24C);
    canvas.drawRRect(RRect.fromRectAndRadius(card, const Radius.circular(20)), _p);
    _p.style = PaintingStyle.fill;
    CanvasText.draw(
      canvas,
      'WELCOME BACK',
      Offset(c.dx, card.top + 18),
      size: 20,
      align: Alignment.topCenter,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      'Your foremen kept digging for ${_duration(r.seconds)}${r.capped ? ' (2h max)' : ''}',
      Offset(c.dx, card.top + 50),
      size: 12,
      align: Alignment.topCenter,
      color: Colors.white70,
      maxWidth: card.width - 24,
    );
    CanvasText.draw(
      canvas,
      '+${formatCash(r.cash)}',
      Offset(c.dx, card.top + 92),
      size: 32,
      align: Alignment.topCenter,
      weight: FontWeight.w900,
      color: const Color(0xFFFFD166),
    );
    CanvasText.draw(
      canvas,
      'tap to continue',
      Offset(c.dx, card.bottom - 14),
      size: 11,
      align: Alignment.bottomCenter,
      color: Colors.white54,
    );
  }

  static String _duration(double seconds) {
    final s = seconds.round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m ${(s % 60).toString().padLeft(2, '0')}s';
    return '${s}s';
  }
}

class _Floater {
  _Floater(this.text, this.at);
  final String text;
  final Offset at;
  double t = 0;
}
