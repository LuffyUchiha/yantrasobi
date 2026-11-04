import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/catalog.dart';
import 'package:yantrasobi/yantrasobi/adapters/scene_adapter.dart';
import 'package:yantrasobi/yantrasobi/app.dart';
import 'package:yantrasobi/yantrasobi/runtime/services.dart';

void main() {
  // No GPU in the test VM: 3D cartridges run their canvas fallback renderer.
  setUpAll(() => SceneSupport.gpuAllowed = false);

  Future<AsobiServices> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final services = AsobiServices.inMemory(buildRegistry());
    await services.warmUp();
    await tester.pumpWidget(YantrasobiApp(services: services));
    await tester.pump();
    return services;
  }

  testWidgets('library lists every bundled cartridge and search filters', (tester) async {
    await boot(tester);
    for (final c in bundledCartridges()) {
      await tester.scrollUntilVisible(
        find.byKey(Key('library.tile.${c.manifest.id}')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.byKey(Key('library.tile.${c.manifest.id}')), findsOneWidget);
    }
    await tester.enterText(find.byKey(const Key('library.search')), 'zzzz-no-match');
    await tester.pump();
    expect(find.byKey(const Key('library.empty')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('library.search')), 'arrow');
    await tester.pump();
    expect(find.byKey(const Key('library.tile.arrow-survivor')), findsOneWidget);
  });

  for (final cartridge in bundledCartridges()) {
    final id = cartridge.manifest.id;
    testWidgets('$id: launch → pause → resume → restart → exit', (tester) async {
      final services = await boot(tester);
      await tester.scrollUntilVisible(
        find.byKey(Key('library.tile.$id')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.byKey(Key('library.tile.$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('library.tile.$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('detail.play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(services.saves.peek(id)!.plays, 1);

      // Pause via button, resume, then restart from pause menu.
      await tester.tap(find.byKey(const Key('host.pause')));
      await tester.pump();
      expect(find.byKey(const Key('host.pauseMenu')), findsOneWidget);
      await tester.tap(find.byKey(const Key('host.resume')));
      await tester.pump();
      expect(find.byKey(const Key('host.pauseMenu')), findsNothing);

      // Android back while running pauses instead of leaving.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('host.pauseMenu')), findsOneWidget);
      await tester.tap(find.byKey(const Key('host.restart')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(services.saves.peek(id)!.plays, 2);

      // Drag across the game surface (touch input path).
      await tester.dragFrom(const Offset(180, 500), const Offset(60, -80));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('host.pause')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('host.exit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail.play')), findsOneWidget);
    });
  }
}
