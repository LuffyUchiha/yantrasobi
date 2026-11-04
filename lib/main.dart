import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cartridges/catalog.dart';
import 'yantrasobi/app.dart';
import 'yantrasobi/datapacks/data_pack.dart';
import 'yantrasobi/runtime/services.dart';
import 'yantrasobi/services/audio.dart';
import 'yantrasobi/services/save_store.dart';
import 'yantrasobi/services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final store = await PrefsKeyValueStore.open();
  final settings = AsobiSettings(store);
  final registry = buildRegistry();
  final services = AsobiServices(
    registry: registry,
    saves: SaveRepository(store),
    settings: settings,
    audio: SynthAudio(settings),
    packs: DataPackRepository(store, registry),
  );
  await services.warmUp();
  runApp(YantrasobiApp(services: services));
}
