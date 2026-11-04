import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';

import '../cartridge/cartridge.dart';
import '../services/audio.dart';

/// Base class for Flame-powered cartridges.
///
/// Input is delivered as a single primary pointer in game (= widget-local)
/// coordinates, which keeps one-thumb portrait games simple and makes the
/// same game code easy to drive from tests.
abstract class AsobiFlameGame extends FlameGame {
  AsobiFlameGame(this.session);

  final CartridgeSession session;

  CartridgeContext get ctx => session.context;
  AsobiAudio get audio => session.context.audio;

  /// Number of live simulated entities, for the perf overlay.
  int get entityCount => 0;

  /// Device safe-area insets (status bar, gesture bar), set by the adapter so
  /// HUDs can avoid the host's pause button and system UI.
  EdgeInsets safePadding = EdgeInsets.zero;

  /// Height reserved at the top for the host's pause button row.
  double get hudTop => safePadding.top + 64;

  void onPointerDown(Vector2 position) {}
  void onPointerMove(Vector2 position, Vector2 delta) {}
  void onPointerUp(Vector2 position) {}

  /// Ends the current run and hands the result to the host.
  void finish(RunResult result) => session.end(result);

  @override
  Color backgroundColor() => const Color(0xFF0E0F1A);
}

/// Adapter that runs an [AsobiFlameGame] inside the Yantrasobi lifecycle.
///
/// * pause/resume map onto `pauseEngine` / `resumeEngine`;
/// * restart builds a brand-new game instance under a new widget key, so the
///   previous `GameWidget` unmounts and Flame disposes the old component tree;
/// * dispose drops the last game reference.
class FlameCartridgeSession<G extends AsobiFlameGame> extends CartridgeSession {
  FlameCartridgeSession(super.context, this._factory);

  final G Function(FlameCartridgeSession<G> session) _factory;

  G? _game;
  Key _gameKey = UniqueKey();
  int? _primaryPointer;

  G get game => _game ?? (throw StateError('Session not started'));

  @override
  int get entityCount => _game?.entityCount ?? 0;

  @override
  void onStart() => _game = _factory(this);

  @override
  void onPause() => _game?.pauseEngine();

  @override
  void onResume() => _game?.resumeEngine();

  @override
  void onRestart() {
    _primaryPointer = null;
    _game = _factory(this);
    _gameKey = UniqueKey();
  }

  @override
  void onEnd(RunResult result) => _game?.pauseEngine();

  @override
  void onDispose() {
    _game?.pauseEngine();
    _game = null;
  }

  @override
  Widget buildView(BuildContext context) {
    final g = game..safePadding = MediaQuery.paddingOf(context);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (!isRunning || _primaryPointer != null) return;
        _primaryPointer = e.pointer;
        g.onPointerDown(Vector2(e.localPosition.dx, e.localPosition.dy));
      },
      onPointerMove: (e) {
        if (!isRunning || e.pointer != _primaryPointer) return;
        g.onPointerMove(Vector2(e.localPosition.dx, e.localPosition.dy), Vector2(e.delta.dx, e.delta.dy));
      },
      onPointerUp: (e) {
        if (e.pointer != _primaryPointer) return;
        _primaryPointer = null;
        if (isRunning) g.onPointerUp(Vector2(e.localPosition.dx, e.localPosition.dy));
      },
      onPointerCancel: (e) {
        if (e.pointer != _primaryPointer) return;
        _primaryPointer = null;
        if (isRunning) g.onPointerUp(Vector2(e.localPosition.dx, e.localPosition.dy));
      },
      child: GameWidget<G>(key: _gameKey, game: g),
    );
  }
}

/// Convenience cartridge base for Flame games.
abstract class FlameCartridge<G extends AsobiFlameGame> extends Cartridge {
  const FlameCartridge();

  G createGame(FlameCartridgeSession<G> session);

  @override
  CartridgeSession createSession(CartridgeContext context) => FlameCartridgeSession<G>(context, createGame);
}
