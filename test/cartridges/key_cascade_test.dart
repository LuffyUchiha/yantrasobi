import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/key_cascade/cascade_world.dart';
import 'package:yantrasobi/cartridges/key_cascade/key_cascade.dart';
import 'package:yantrasobi/yantrasobi/services/audio.dart';

void main() {
  CascadeWorld world({Song song = Songs.twinkle}) => CascadeWorld(song: song, seed: 3);

  /// Taps every key at the moment its bottom edge is one row above the bottom.
  CascadeWorld autoplay(CascadeWorld w, {double tapEarlyRows = 1}) {
    w.press(w.nextTile!.lane);
    for (var i = 0; i < 20000 && !w.isOver; i++) {
      final next = w.nextTile;
      if (next != null && next.beat - w.beat <= tapEarlyRows) {
        w.press(next.lane);
      }
      // Lift fingers from lanes with no hold key in progress.
      for (var lane = 0; lane < w.lanes; lane++) {
        if (!w.tiles.any((t) => t.holding && t.lane == lane)) w.release(lane);
      }
      w.update(1 / 60);
    }
    return w;
  }

  test('manifest is valid', () => expect(KeyCascadeCartridge.kManifest.validate(), isEmpty));

  test('songs map to one key per note with no lane repeated twice in a row', () {
    final w = world(song: Songs.odeToJoy);
    expect(w.tiles.length, Songs.odeToJoy.notes.length);
    for (var i = 1; i < w.tiles.length; i++) {
      expect(w.tiles[i].lane, isNot(w.tiles[i - 1].lane));
      expect(w.tiles[i].beat, greaterThan(w.tiles[i - 1].beat));
    }
  });

  test('nothing scrolls until the first key is tapped', () {
    final w = world();
    w.update(1);
    expect(w.beat, 0);
    w.press((w.nextTile!.lane + 1) % 4); // wrong lane before start is ignored
    expect(w.started, isFalse);
    expect(w.lives, CascadeWorld.startLives);
    w.press(w.nextTile!.lane);
    expect(w.started, isTrue);
    expect(w.hits, 1);
  });

  test('tapping the right lane plays the next note in order', () {
    final w = world();
    final events = <CascadeEvent>[];
    w.press(w.tiles[0].lane);
    events.addAll(w.events);
    w.events.clear();
    w.release(w.tiles[0].lane);
    w.press(w.tiles[1].lane);
    events.addAll(w.events);
    expect(events.where((e) => e.kind == CascadeEventKind.hit).map((e) => e.midi), [
      Songs.twinkle.notes[0].$1,
      Songs.twinkle.notes[1].$1,
    ]);
  });

  test('tapping an empty lane costs a life', () {
    final w = world();
    w.press(w.tiles[0].lane);
    final wrong = (w.nextTile!.lane + 1) % 4;
    w.press(wrong);
    expect(w.lives, CascadeWorld.startLives - 1);
    expect(w.combo, 0);
  });

  test('a key that slips past the bottom is a miss', () {
    final w = world();
    w.press(w.tiles[0].lane);
    w.update(5);
    expect(w.misses, greaterThan(0));
    expect(w.tiles[1].missed, isTrue);
  });

  test('hold keys score by how long they are held', () {
    final w = world();
    final holdIndex = w.tiles.indexWhere((t) => t.isHold);
    expect(holdIndex, greaterThan(0));
    final full = autoplay(world());
    final hold = full.tiles[holdIndex];
    expect(hold.tapped, isTrue);
    expect(hold.heldBeats, closeTo(hold.length, 0.1));
  });

  test('a perfect player finishes the song with three stars', () {
    final w = autoplay(world());
    expect(w.won, isTrue);
    expect(w.stars, 3);
    expect(w.hits, w.tiles.length);
  });

  test('three mistakes end the run', () {
    final w = world();
    w.press(w.tiles[0].lane);
    for (var i = 0; i < 3; i++) {
      w.press((w.nextTile!.lane + 1) % 4);
    }
    expect(w.isOver, isTrue);
    expect(w.won, isFalse);
  });

  test('original tunes are generated deterministically from a pentatonic scale', () {
    final a = Songs.lantern(5), b = Songs.lantern(5);
    expect(a.notes, b.notes);
    const pentatonic = {0, 2, 4, 7, 9};
    for (final (midi, _) in a.notes) {
      expect(pentatonic.contains(midi % 12), isTrue);
    }
  });

  test('later stages scroll faster', () {
    final slow = CascadeWorld(song: Songs.twinkle), fast = CascadeWorld(song: Songs.twinkle, speedScale: 1.3);
    expect(fast.beatsPerSecond, greaterThan(slow.beatsPerSecond));
  });

  test('note synth renders a valid WAV for the whole song range', () {
    for (final (midi, _) in Songs.odeToJoy.notes) {
      final wav = SfxSynth.note(midi);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    }
  });
}
