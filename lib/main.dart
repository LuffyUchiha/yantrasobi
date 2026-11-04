import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cartridges/catalog.dart';
import 'yantrasobi/app.dart';
import 'yantrasobi/runtime/services.dart';
import 'yantrasobi/services/audio.dart';
import 'yantrasobi/services/save_store.dart';
import 'yantrasobi/services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final store = await PrefsKeyValueStore.open();
  final settings = AsobiSettings(store);
  final services = AsobiServices(
    registry: buildRegistry(),
    saves: SaveRepository(store),
    settings: settings,
    audio: SynthAudio(settings),
  );
  await services.warmUp();
  runApp(YantrasobiApp(services: services));
}
