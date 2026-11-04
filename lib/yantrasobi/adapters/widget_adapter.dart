import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../cartridge/cartridge.dart';

/// Lifecycle adapter for cartridges built from plain Flutter widgets (menus,
/// card games, text adventures). The cartridge supplies a builder; the
/// session rebuilds it with a fresh key on restart so all widget state resets.
class WidgetCartridgeSession extends CartridgeSession {
  WidgetCartridgeSession(super.context, this._builder);

  final Widget Function(BuildContext context, WidgetCartridgeSession session) _builder;
  Key _key = UniqueKey();

  /// Incremented on every restart; widgets can use it to reset local state.
  int generation = 0;

  final ValueNotifier<bool> _paused = ValueNotifier(false);

  /// True while the host shows the pause menu. Timers inside the cartridge
  /// should stop while this is true.
  ValueListenable<bool> get paused => _paused;

  int _entities = 0;
  @override
  int get entityCount => _entities;

  /// Lets the cartridge report how many live objects it manages.
  set entityCount(int value) => _entities = value;

  @override
  void onPause() => _paused.value = true;

  @override
  void onResume() => _paused.value = false;

  @override
  void onEnd(RunResult result) => _paused.value = true;

  @override
  void onRestart() {
    generation++;
    _key = UniqueKey();
    _paused.value = false;
  }

  @override
  void onDispose() => _paused.dispose();

  @override
  Widget buildView(BuildContext context) =>
      KeyedSubtree(key: _key, child: Builder(builder: (context) => _builder(context, this)));
}

abstract class WidgetCartridge extends Cartridge {
  const WidgetCartridge();

  Widget buildGame(BuildContext context, WidgetCartridgeSession session);

  @override
  CartridgeSession createSession(CartridgeContext context) => WidgetCartridgeSession(context, buildGame);
}
