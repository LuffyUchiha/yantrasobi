import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/events.dart';
import 'package:flutter/material.dart' show Alignment, Colors, Icons;

import '../../yantrasobi/adapters/canvas_kit.dart';
import '../../yantrasobi/adapters/flame_adapter.dart';
import '../../yantrasobi/cartridge/cartridge.dart';
import '../../yantrasobi/cartridge/manifest.dart';
import '../../yantrasobi/services/audio.dart';
import 'cascade_world.dart';

class KeyCascadeCartridge extends FlameCartridge<KeyCascadeGame> {
  const KeyCascadeCartridge();

  static const CartridgeManifest kManifest = CartridgeManifest(
    id: 'key-cascade',
    title: 'Key Cascade',
    tagline: 'Tap the falling keys. Play the tune.',
    description:
        'A rhythm tapping game. Dark keys fall down four lanes: tap each one in order and it plays '
        'the next note of the song. Hold the long keys until they pass. Tapping an empty lane or '
        'letting a key slip by costs a life. Songs include public-domain classics and original '
        'generated tunes, and each cleared stage plays faster.',
    genre: 'Rhythm tiles',
    engine: CartridgeEngine.flame2d,
    version: '1.0.0',
    accent: Color(0xFF8E7DFF),
    icon: Icons.piano_rounded,
    tags: ['music', 'rhythm', 'tap', 'tiles'],
    controls: ['Tap the lowest dark key', 'Hold long keys until they finish'],
    mechanics: ['ordered tapping', 'hold notes', 'synthesized melody', 'speed stages'],
    goal: 'Finish the song with at least one life left; accuracy earns up to 3 stars.',
  );

  @override
  CartridgeManifest get manifest => kManifest;

  @override
  KeyCascadeGame createGame(FlameCartridgeSession<KeyCascadeGame> session) => KeyCascadeGame(session);
}

class KeyCascadeGame extends AsobiFlameGame with MultiTouchTapDetector {
  KeyCascadeGame(super.session, {int? seed})
    : level = math.max(1, session.context.save.intData('level', 1)),
      _seed = seed ?? 1 {
    final songs = Songs.forLevel(level);
    final song = songs[(level - 1) % songs.length];
    final speed = 1 + ((level - 1) ~/ songs.length) * 0.15;
    stage = CascadeWorld(song: song, seed: _seed + level, speedScale: speed);
  }

  final int level;
  final int _seed;
  late final CascadeWorld stage;
  final Map<int, int> _pointerLane = {};
  final List<(int, double)> _flashes = [];
  bool _reported = false;
  double _endDelay = 1.0;
  double _missFlash = 0;

  @override
  int get entityCount => stage.entityCount;

  double get _top => hudTop + 20;
  double get _rowH => (size.y - _top) / CascadeWorld.visibleRows;
  double get _laneW => size.x / stage.lanes;

  int laneAt(double x) => (x / _laneW).floor().clamp(0, stage.lanes - 1);

  void pressLane(int lane) {
    stage.press(lane);
  }

  @override
  void onTapDown(int pointerId, TapDownInfo info) {
    final p = info.eventPosition.widget;
    if (p.y < hudTop) return;
    final lane = laneAt(p.x);
    _pointerLane[pointerId] = lane;
    pressLane(lane);
  }

  @override
  void onTapUp(int pointerId, TapUpInfo info) => _lift(pointerId);

  @override
  void onTapCancel(int pointerId) => _lift(pointerId);

  void _lift(int pointerId) {
    final lane = _pointerLane.remove(pointerId);
    if (lane != null && !_pointerLane.containsValue(lane)) stage.release(lane);
  }

  @override
  void update(double dt) {
    super.update(dt);
    stage.update(dt);
    if (_missFlash > 0) _missFlash -= dt;
    _flashes.removeWhere((f) => stage.beat - f.$2 > 0.5);
    _drain();
    if (stage.isOver && !_reported) {
      _endDelay -= dt;
      if (_endDelay <= 0) {
        _reported = true;
        if (stage.won) {
          ctx.save.data['level'] = level + 1;
          ctx.commitSave();
        }
        finish(
          RunResult(
            score: stage.score,
            won: stage.won,
            headline: stage.won
                ? '${stage.stars} star${stage.stars == 1 ? '' : 's'}: "${stage.song.title}"'
                : 'The tune stopped at key ${stage.hits + stage.misses} of ${stage.tiles.length}.',
            details: {
              'Accuracy': '${(stage.accuracy * 100).round()}%',
              'Best combo': '${stage.bestCombo}',
              'Stage': '$level',
            },
          ),
        );
      }
    }
  }

  /// Events from presses arrive outside update(); drain them every frame.
  void _drain() {
    for (final e in stage.events) {
      switch (e.kind) {
        case CascadeEventKind.hit:
          audio.playNote(e.midi);
          _flashes.add((e.lane, stage.beat));
        case CascadeEventKind.holdComplete:
          audio.play(Sfx.pop);
        case CascadeEventKind.miss:
          audio.play(Sfx.thud);
          audio.haptic(HapticKind.heavy);
          _missFlash = 0.35;
        case CascadeEventKind.songEnd:
          audio.play(Sfx.win);
      }
    }
    stage.events.clear();
  }

  final Paint _p = Paint();

  @override
  Color backgroundColor() => const Color(0xFFF4F1FF);

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    _drain();
    final rowH = _rowH, laneW = _laneW, bottom = size.y;
    for (var l = 1; l < stage.lanes; l++) {
      canvas.drawLine(
        Offset(l * laneW, _top),
        Offset(l * laneW, bottom),
        _p..color = const Color(0x22000000),
      );
    }
    for (final (lane, _) in _flashes) {
      canvas.drawRect(
        Rect.fromLTWH(lane * laneW, _top, laneW, bottom - _top),
        _p..color = const Color(0x228E7DFF),
      );
    }
    for (final t in stage.tiles) {
      final yBottom = bottom - (t.beat - stage.beat) * rowH;
      final h = t.length * rowH;
      final rect = Rect.fromLTWH(t.lane * laneW + 2, yBottom - h + 2, laneW - 4, h - 4);
      if (rect.bottom < _top || rect.top > bottom) continue;
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(8));
      if (t.missed) {
        canvas.drawRRect(rr, _p..color = const Color(0xFFFF6B6B));
      } else if (t.tapped && !t.holding) {
        canvas.drawRRect(rr, _p..color = const Color(0x33000000));
      } else {
        canvas.drawRRect(rr, _p..color = const Color(0xFF1D1B33));
        if (t.isHold) {
          final fill = (t.heldBeats / t.length).clamp(0.0, 1.0);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(rect.left, rect.bottom - rect.height * fill, rect.width, rect.height * fill),
              const Radius.circular(8),
            ),
            _p..color = const Color(0xFF8E7DFF),
          );
          canvas.drawCircle(Offset(rect.center.dx, rect.bottom - 24), 8, _p..color = Colors.white70);
        }
        if (!stage.started && t.index == 0) {
          CanvasText.draw(
            canvas,
            'START',
            rect.center,
            size: 18,
            align: Alignment.center,
            color: Colors.white,
            weight: FontWeight.w900,
          );
        }
      }
    }
    if (_missFlash > 0) {
      canvas.drawRect(
        Offset.zero & Size(size.x, size.y),
        _p..color = const Color(0xFFFF3B5C).withValues(alpha: _missFlash),
      );
    }
    _drawHud(canvas);
  }

  void _drawHud(Canvas canvas) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, _top), _p..color = const Color(0xFF1D1B33));
    final top = safePadding.top + 14;
    CanvasText.draw(
      canvas,
      '${stage.score}',
      Offset(size.x / 2, top),
      size: 26,
      align: Alignment.topCenter,
      weight: FontWeight.w900,
    );
    CanvasText.draw(
      canvas,
      stage.song.title,
      Offset(size.x / 2, top + 34),
      size: 11,
      align: Alignment.topCenter,
      color: Colors.white60,
    );
    for (var i = 0; i < CascadeWorld.startLives; i++) {
      canvas.drawCircle(
        Offset(size.x - 22 - i * 20.0, top + 14),
        7,
        _p..color = i < stage.lives ? const Color(0xFFFF6B9A) : const Color(0x33FFFFFF),
      );
    }
    final progress = stage.tiles.isEmpty ? 0.0 : (stage.hits + stage.misses) / stage.tiles.length;
    drawBar(canvas, Rect.fromLTWH(16, _top - 10, size.x - 32, 5), progress, const Color(0xFF8E7DFF));
    if (stage.combo >= 5) {
      CanvasText.draw(
        canvas,
        '${stage.combo} combo',
        Offset(size.x / 2, _top + 30),
        size: 18,
        align: Alignment.center,
        color: const Color(0xFF8E7DFF),
        weight: FontWeight.w900,
      );
    }
  }
}
