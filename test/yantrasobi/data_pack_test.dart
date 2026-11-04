import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/brickfall/brickfall.dart';
import 'package:yantrasobi/cartridges/brickfall/levels.dart';
import 'package:yantrasobi/cartridges/catalog.dart';
import 'package:yantrasobi/yantrasobi/app.dart';
import 'package:yantrasobi/yantrasobi/datapacks/data_pack.dart';
import 'package:yantrasobi/yantrasobi/runtime/services.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';

Map<String, Object?> envelope({String cartridge = 'brickfall', Object? payload, Object schema = 1}) => {
  'format': kDataPackFormat,
  'schema': schema,
  'id': 'test.pack',
  'cartridge': cartridge,
  'title': 'Test Pack',
  'version': '1.0.0',
  'payload':
      payload ??
      {
        'levels': [
          {
            'name': 'Tiny',
            'rows': ['1111111111', '..........'],
          },
        ],
      },
};

void main() {
  group('envelope', () {
    test('parses a valid pack', () {
      final p = DataPack.parse(jsonEncode(envelope()));
      expect(p.id, 'test.pack');
      expect(p.cartridgeId, 'brickfall');
      expect(p.payload['levels'], isA<List>());
    });

    test('rejects bad JSON, wrong format, future schema, bad id and missing payload', () {
      expect(() => DataPack.parse('{nope'), throwsA(isA<DataPackError>()));
      expect(() => DataPack.parse('[1]'), throwsA(isA<DataPackError>()));
      expect(
        () => DataPack.parse(jsonEncode({...envelope(), 'format': 'other'})),
        throwsA(isA<DataPackError>()),
      );
      expect(() => DataPack.parse(jsonEncode(envelope(schema: 99))), throwsA(isA<DataPackError>()));
      expect(
        () => DataPack.parse(jsonEncode({...envelope(), 'id': 'Bad ID!'})),
        throwsA(isA<DataPackError>()),
      );
      expect(
        () => DataPack.parse(jsonEncode({...envelope(), 'payload': 'code()'})),
        throwsA(isA<DataPackError>()),
      );
    });

    test('rejects oversized packs', () {
      final huge = 'x' * (kDataPackMaxChars + 1);
      expect(() => DataPack.parse(huge), throwsA(isA<DataPackError>()));
    });
  });

  group('repository', () {
    test('installs, persists, reloads and removes packs', () async {
      final store = MemoryKeyValueStore();
      final repo = DataPackRepository(store, buildRegistry());
      await repo.install(jsonEncode(envelope()));
      expect(repo.packsFor('brickfall'), hasLength(1));
      final again = DataPackRepository(store, buildRegistry());
      await again.load();
      expect(again.installed.single.title, 'Test Pack');
      await again.remove('test.pack');
      expect(again.installed, isEmpty);
    });

    test('rejects unknown cartridges and cartridges that do not accept packs', () async {
      final repo = DataPackRepository(MemoryKeyValueStore(), buildRegistry());
      expect(() => repo.install(jsonEncode(envelope(cartridge: 'nope'))), throwsA(isA<DataPackError>()));
      expect(() => repo.install(jsonEncode(envelope(cartridge: 'tube-sort'))), throwsA(isA<DataPackError>()));
    });

    test('reinstalling the same id replaces the old pack', () async {
      final repo = DataPackRepository(MemoryKeyValueStore(), buildRegistry());
      await repo.install(jsonEncode(envelope()));
      await repo.install(jsonEncode({...envelope(), 'title': 'Renamed'}));
      expect(repo.installed.single.title, 'Renamed');
    });
  });

  group('brickfall packs', () {
    test('validator catches bad rows, unknown bricks and unbreakable levels', () {
      List<String> v(List<String> rows) => validateBrickPack({
        'levels': [
          {'name': 'L', 'rows': rows},
        ],
      });
      expect(v(['1111111111']), isEmpty);
      expect(v(['111']), isNotEmpty);
      expect(v(['111111111Z']), isNotEmpty);
      expect(v(['##########']), isNotEmpty);
      expect(validateBrickPack({'levels': []}), isNotEmpty);
    });

    test('the bundled sample pack is valid', () async {
      final raw = File('assets/datapacks/brickfall_neon_nights.json').readAsStringSync();
      final repo = DataPackRepository(MemoryKeyValueStore(), buildRegistry());
      final pack = await repo.install(raw);
      expect(brickPackLevels([pack.payload]), hasLength(3));
    });

    test('pack levels play after the built-in levels, then generated levels resume', () {
      final pack = brickPackLevels([envelope()['payload']! as Map<String, Object?>]);
      final first = kAuthoredLevels.length + 1;
      final w = BrickfallGame.worldFor(1, first, pack);
      expect(w.rows, 2);
      final after = BrickfallGame.worldFor(1, first + 1, pack);
      final plain = BrickfallGame.worldFor(1, first, const []);
      expect(after.rows, plain.rows);
    });
  });

  testWidgets('settings → data packs → install sample → listed', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final services = AsobiServices.inMemory(buildRegistry());
    await services.warmUp();
    await tester.pumpWidget(YantrasobiApp(services: services));
    await tester.tap(find.byKey(const Key('library.settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.packs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('packs.sample.${DataPacksScreenKeys.sample}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('packs.item.brickfall.neon-nights')), findsOneWidget);
    expect(services.packs.packsFor('brickfall'), hasLength(1));
  });
}

abstract final class DataPacksScreenKeys {
  static const String sample = 'assets/datapacks/brickfall_neon_nights.json';
}
