import 'package:flutter/widgets.dart';

import '../cartridge/registry.dart';
import '../datapacks/data_pack.dart';
import '../services/audio.dart';
import '../services/save_store.dart';
import '../services/settings.dart';

/// Console-wide services, created once at boot.
class AsobiServices {
  AsobiServices({
    required this.registry,
    required this.saves,
    required this.settings,
    required this.audio,
    DataPackRepository? packs,
  }) : packs = packs ?? DataPackRepository(MemoryKeyValueStore(), registry);

  final CartridgeRegistry registry;
  final SaveRepository saves;
  final AsobiSettings settings;
  final AsobiAudio audio;

  /// Installed declarative data packs (JSON only, never code).
  final DataPackRepository packs;

  /// In-memory services for tests.
  factory AsobiServices.inMemory(CartridgeRegistry registry, {AsobiAudio? audio}) {
    final store = MemoryKeyValueStore();
    return AsobiServices(
      registry: registry,
      saves: SaveRepository(store),
      settings: AsobiSettings(store),
      audio: audio ?? SilentAudio(),
      packs: DataPackRepository(store, registry),
    );
  }

  /// Loads every save so the library can show stats synchronously.
  Future<void> warmUp() async {
    await settings.load();
    await packs.load();
    for (final c in registry.all) {
      await saves.load(c.manifest.id);
    }
  }
}

/// Makes [AsobiServices] available to the widget tree.
class AsobiScope extends InheritedWidget {
  const AsobiScope({super.key, required this.services, required super.child});

  final AsobiServices services;

  static AsobiServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AsobiScope>();
    assert(scope != null, 'No AsobiScope above this context');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AsobiScope oldWidget) => services != oldWidget.services;
}
