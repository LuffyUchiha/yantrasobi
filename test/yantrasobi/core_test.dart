import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/catalog.dart';
import 'package:yantrasobi/yantrasobi/cartridge/cartridge.dart';
import 'package:yantrasobi/yantrasobi/cartridge/manifest.dart';
import 'package:yantrasobi/yantrasobi/cartridge/registry.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';
import 'package:yantrasobi/yantrasobi/services/save_store.dart';
import 'package:yantrasobi/yantrasobi/services/settings.dart';

CartridgeManifest _manifest({String id = 'demo', String version = '1.0.0', int api = kCartridgeApiVersion}) =>
    CartridgeManifest(
      id: id,
      title: 'Demo',
      tagline: 't',
      description: 'd',
      genre: 'Test',
      engine: CartridgeEngine.widgets,
      version: version,
      apiVersion: api,
      accent: const Color(0xFF00FF00),
      icon: Icons.abc,
      controls: const ['tap'],
      goal: 'win',
      tags: const ['puzzle', 'cute'],
    );

class _FakeSession extends CartridgeSession {
  _FakeSession(super.context);
  final List<String> calls = [];
  @override
  Widget buildView(BuildContext context) => const SizedBox();
  @override
  void onStart() => calls.add('start');
  @override
  void onPause() => calls.add('pause');
  @override
  void onResume() => calls.add('resume');
  @override
  void onRestart() => calls.add('restart');
  @override
  void onEnd(RunResult r) => calls.add('end');
  @override
  void onDispose() => calls.add('dispose');
}

class _FakeCartridge extends Cartridge {
  _FakeCartridge(this.manifest);
  @override
  final CartridgeManifest manifest;
  @override
  CartridgeSession createSession(CartridgeContext context) => _FakeSession(context);
}

CartridgeContext _ctx() {
  final store = MemoryKeyValueStore();
  return CartridgeContext(
    manifest: _manifest(),
    save: CartridgeSave(),
    audio: SilentAudio(),
    settings: AsobiSettings(store),
  );
}

void main() {
  group('manifest', () {
    test('valid manifest has no problems', () => expect(_manifest().validate(), isEmpty));
    test('rejects bad id, version and future API', () {
      expect(_manifest(id: 'Bad Id').validate(), isNotEmpty);
      expect(_manifest(version: '1.0').validate(), isNotEmpty);
      expect(_manifest(api: kCartridgeApiVersion + 1).validate(), isNotEmpty);
    });
    test('search matches title, tags and engine; all words must match', () {
      final m = _manifest();
      expect(m.matchesQuery(''), isTrue);
      expect(m.matchesQuery('PUZ'), isTrue);
      expect(m.matchesQuery('cute widgets'), isTrue);
      expect(m.matchesQuery('cute racing'), isFalse);
    });
    test('toJson round-trips through JSON encoding', () {
      final json = jsonDecode(jsonEncode(_manifest().toJson())) as Map<String, dynamic>;
      expect(json['id'], 'demo');
      expect(json['apiVersion'], kCartridgeApiVersion);
    });
  });

  group('registry', () {
    test('rejects duplicates and invalid manifests', () {
      final r = CartridgeRegistry([_FakeCartridge(_manifest())]);
      expect(() => r.register(_FakeCartridge(_manifest())), throwsA(isA<CartridgeRejected>()));
      expect(() => r.register(_FakeCartridge(_manifest(id: 'x y'))), throwsA(isA<CartridgeRejected>()));
      expect(r.length, 1);
    });
    test('bundled catalog registers cleanly with unique ids', () {
      final r = buildRegistry();
      expect(r.length, bundledCartridges().length);
      expect(r.length, greaterThan(0));
    });
  });

  group('session lifecycle', () {
    test('start → pause → resume → end → restart → dispose', () {
      final s = _FakeSession(_ctx());
      expect(s.state, SessionState.created);
      s.start();
      expect(s.state, SessionState.running);
      s.pause();
      expect(s.state, SessionState.paused);
      s.pause(); // idempotent
      s.resume();
      expect(s.isRunning, isTrue);
      s.end(const RunResult(score: 5, won: true));
      expect(s.state, SessionState.ended);
      expect(s.result!.score, 5);
      s.end(const RunResult(score: 9)); // ignored once ended
      expect(s.result!.score, 5);
      s.restart();
      expect(s.state, SessionState.running);
      expect(s.result, isNull);
      expect(s.runs, 2);
      s.dispose();
      expect(s.state, SessionState.disposed);
      expect(s.calls, ['start', 'pause', 'resume', 'end', 'restart', 'dispose']);
    });
    test('cannot start twice or restart before start', () {
      final s = _FakeSession(_ctx());
      expect(s.restart, throwsStateError);
      s.start();
      expect(s.start, throwsStateError);
    });
  });

  group('saves', () {
    test('persist and reload through the store', () async {
      final store = MemoryKeyValueStore();
      final repo = SaveRepository(store);
      final save = await repo.load('demo');
      save
        ..bestScore = 42
        ..plays = 3
        ..data['level'] = 7;
      await repo.persist('demo', save);
      final fresh = await SaveRepository(store).load('demo');
      expect(fresh.bestScore, 42);
      expect(fresh.plays, 3);
      expect(fresh.intData('level'), 7);
    });
    test('corrupt or future-version saves fall back to a fresh save', () {
      expect(CartridgeSave.fromJsonString('{not json').bestScore, 0);
      expect(CartridgeSave.fromJsonString('{"v": 999, "bestScore": 5}').bestScore, 0);
      expect(CartridgeSave.fromJsonString('[1,2]').plays, 0);
    });
    test('reset clears progress', () async {
      final repo = SaveRepository(MemoryKeyValueStore());
      final s = await repo.load('a');
      s.bestScore = 10;
      await repo.persist('a', s);
      await repo.reset('a');
      expect((await repo.load('a')).bestScore, 0);
    });
  });

  group('settings', () {
    test('persist and reload', () async {
      final store = MemoryKeyValueStore();
      final s = AsobiSettings(store)
        ..sound = false
        ..showPerf = true;
      await Future<void>.delayed(Duration.zero);
      final t = AsobiSettings(store);
      await t.load();
      expect(t.sound, isFalse);
      expect(t.showPerf, isTrue);
      expect(s.haptics, isTrue);
    });
  });

  group('audio synth', () {
    test('every effect renders a valid mono 16-bit WAV', () {
      for (final sfx in Sfx.values) {
        final bytes = SfxSynth.render(sfx);
        expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
        expect(bytes.length, greaterThan(44 + 100));
      }
    });
  });
}
