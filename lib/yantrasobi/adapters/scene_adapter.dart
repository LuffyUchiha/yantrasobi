import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../cartridge/cartridge.dart';
import '../services/audio.dart';
import 'projector.dart';

/// Global switches for the 3D path.
abstract final class SceneSupport {
  /// When false, 3D cartridges skip Flutter GPU entirely and use their canvas
  /// fallback. Tests set this to false (no GPU in the test VM).
  static bool gpuAllowed = true;

  /// How long to wait for `Scene.initializeStaticResources` before falling
  /// back to the canvas renderer.
  static Duration initTimeout = const Duration(seconds: 6);

  static Future<bool>? _init;

  /// Initialises flutter_scene once per process. Resolves to whether GPU
  /// rendering is usable.
  static Future<bool> ensureInitialized() {
    if (!gpuAllowed) return Future.value(false);
    return _init ??= Scene.initializeStaticResources()
        .then((_) => true)
        .timeout(initTimeout, onTimeout: () => false)
        .catchError((Object e) {
          debugPrint('Yantrasobi: Flutter GPU unavailable, using canvas fallback ($e)');
          return false;
        });
  }
}

/// Camera placement shared by the GPU and fallback paths.
class SceneCameraSpec {
  const SceneCameraSpec({required this.eye, required this.target, this.fovY = 0.9});
  final vm.Vector3 eye;
  final vm.Vector3 target;
  final double fovY;

  Projector projector(Size size) => Projector(eye: eye, target: target, size: size, fovY: fovY);
}

/// A 3D cartridge's game object. Rules live in a pure-Dart world; this class
/// mirrors that world into a flutter_scene graph (GPU path) or paints it in
/// 2.5D (fallback path), and draws the HUD in both.
abstract class SceneGame {
  SceneGame(this.session);

  final CartridgeSession session;
  AsobiAudio get audio => session.context.audio;

  SceneCameraSpec camera(Size size);

  /// Advances the rules. Only called while the session is running.
  void update(double dt);

  /// Build the retained scene graph once static resources are ready.
  void buildScene(Scene scene);

  /// Push this frame's world state into the scene graph.
  void syncScene();

  /// 2.5D canvas renderer used when Flutter GPU is unavailable.
  void paintFallback(Canvas canvas, Size size, Projector projector);

  /// HUD drawn above either renderer (score, labels anchored to 3D objects).
  void paintHud(Canvas canvas, Size size, Projector projector, EdgeInsets safe);

  void pointerDown(Offset p, Size size) {}
  void pointerMove(Offset p, Size size) {}
  void pointerUp(Offset p, Size size) {}

  int get entityCount => 0;

  /// True once the GPU renderer is live (for HUD/debug text).
  bool gpuActive = false;

  void finish(RunResult result) => session.end(result);

  void dispose() {}
}

/// Lifecycle adapter for flutter_scene cartridges.
class SceneCartridgeSession<G extends SceneGame> extends CartridgeSession {
  SceneCartridgeSession(super.context, this._factory);

  final G Function(SceneCartridgeSession<G> session) _factory;
  G? _game;
  Key _key = UniqueKey();

  G get game => _game ?? (throw StateError('Session not started'));

  @override
  int get entityCount => _game?.entityCount ?? 0;

  @override
  void onStart() => _game = _factory(this);

  @override
  void onRestart() {
    _game?.dispose();
    _game = _factory(this);
    _key = UniqueKey();
  }

  @override
  void onDispose() {
    _game?.dispose();
    _game = null;
  }

  @override
  Widget buildView(BuildContext context) => _SceneGameView(key: _key, session: this, game: game);
}

abstract class SceneCartridge<G extends SceneGame> extends Cartridge {
  const SceneCartridge();

  G createGame(SceneCartridgeSession<G> session);

  @override
  CartridgeSession createSession(CartridgeContext context) => SceneCartridgeSession<G>(context, createGame);
}

class _SceneGameView extends StatefulWidget {
  const _SceneGameView({super.key, required this.session, required this.game});

  final CartridgeSession session;
  final SceneGame game;

  @override
  State<_SceneGameView> createState() => _SceneGameViewState();
}

enum _Mode { loading, gpu, fallback }

class _SceneGameViewState extends State<_SceneGameView> with SingleTickerProviderStateMixin {
  _Mode _mode = _Mode.loading;
  Scene? _scene;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  Size _size = Size.zero;
  int? _pointer;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    SceneSupport.ensureInitialized().then((ok) {
      if (!mounted) return;
      if (ok) {
        try {
          final scene = Scene();
          widget.game.buildScene(scene);
          widget.game.gpuActive = true;
          setState(() {
            _scene = scene;
            _mode = _Mode.gpu;
          });
          return;
        } catch (e) {
          debugPrint('Yantrasobi: scene build failed, using fallback ($e)');
        }
      }
      setState(() => _mode = _Mode.fallback);
    });
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt > 0.1) dt = 0.1;
    if (widget.session.isRunning && _mode != _Mode.loading && _size != Size.zero) {
      widget.game.update(dt);
      if (_mode == _Mode.gpu) widget.game.syncScene();
    }
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    _scene?.removeAll();
    _scene = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        final layers = <Widget>[];
        if (_mode == _Mode.gpu && _scene != null) {
          layers.add(
            SceneView(
              _scene!,
              cameraBuilder: (_) {
                final c = widget.game.camera(_size);
                return PerspectiveCamera(position: c.eye, target: c.target, fovRadiansY: c.fovY);
              },
            ),
          );
        } else if (_mode == _Mode.fallback) {
          layers.add(CustomPaint(size: _size, painter: _FallbackPainter(widget.game, _frame)));
        }
        layers.add(CustomPaint(size: _size, painter: _HudPainter(widget.game, _frame, safe)));
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (!widget.session.isRunning || _pointer != null) return;
            _pointer = e.pointer;
            widget.game.pointerDown(e.localPosition, _size);
          },
          onPointerMove: (e) {
            if (e.pointer != _pointer || !widget.session.isRunning) return;
            widget.game.pointerMove(e.localPosition, _size);
          },
          onPointerUp: (e) {
            if (e.pointer != _pointer) return;
            _pointer = null;
            widget.game.pointerUp(e.localPosition, _size);
          },
          onPointerCancel: (e) {
            if (e.pointer != _pointer) return;
            _pointer = null;
            widget.game.pointerUp(e.localPosition, _size);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_mode == _Mode.loading) const ColoredBox(color: Color(0xFF0B0C15)),
              ...layers,
            ],
          ),
        );
      },
    );
  }
}

class _FallbackPainter extends CustomPainter {
  _FallbackPainter(this.game, Listenable repaint) : super(repaint: repaint);
  final SceneGame game;

  @override
  void paint(Canvas canvas, Size size) => game.paintFallback(canvas, size, game.camera(size).projector(size));

  @override
  bool shouldRepaint(_FallbackPainter old) => old.game != game;
}

class _HudPainter extends CustomPainter {
  _HudPainter(this.game, Listenable repaint, this.safe) : super(repaint: repaint);
  final SceneGame game;
  final EdgeInsets safe;

  @override
  void paint(Canvas canvas, Size size) =>
      game.paintHud(canvas, size, game.camera(size).projector(size), safe);

  @override
  bool shouldRepaint(_HudPainter old) => old.game != game || old.safe != safe;
}
