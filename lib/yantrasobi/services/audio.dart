import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'settings.dart';

/// Shared sound-effect vocabulary. Every sound is synthesised procedurally at
/// startup, so the console ships no third-party audio assets.
enum Sfx { tap, hit, coin, powerup, win, lose, pop, whoosh, merge, thud }

/// Sound + haptics facade handed to every cartridge.
abstract class AsobiAudio {
  void play(Sfx sfx);

  /// Plays a short synthesized piano-like note (MIDI number, 60 = middle C).
  void playNote(int midi) {}
  void haptic([HapticKind kind = HapticKind.light]);
  void dispose() {}
}

enum HapticKind { light, medium, heavy, selection }

/// Does nothing. Used by tests and headless tooling.
class SilentAudio implements AsobiAudio {
  final List<Sfx> played = [];

  final List<int> notes = [];

  @override
  void play(Sfx sfx) => played.add(sfx);

  @override
  void playNote(int midi) => notes.add(midi);

  @override
  void haptic([HapticKind kind = HapticKind.light]) {}

  @override
  void dispose() {}
}

/// Synthesises short 8-bit-style effects into 16-bit PCM WAV bytes.
class SfxSynth {
  static const int sampleRate = 22050;

  static Uint8List render(Sfx sfx) {
    switch (sfx) {
      case Sfx.tap:
        return _tone(const [880], 0.05, wave: _square, volume: 0.25);
      case Sfx.hit:
        return _tone(const [220, 110], 0.10, wave: _noiseSquare, volume: 0.35);
      case Sfx.coin:
        return _tone(const [988, 1319], 0.12, wave: _square, volume: 0.25);
      case Sfx.powerup:
        return _tone(const [523, 659, 784, 1047], 0.32, wave: _square, volume: 0.25);
      case Sfx.win:
        return _tone(const [523, 659, 784, 1047, 1319], 0.6, wave: _triangle, volume: 0.4);
      case Sfx.lose:
        return _tone(const [392, 330, 262, 196], 0.6, wave: _triangle, volume: 0.4);
      case Sfx.pop:
        return _tone(const [660, 990], 0.06, wave: _sine, volume: 0.35);
      case Sfx.whoosh:
        return _tone(const [300, 600], 0.15, wave: _noise, volume: 0.15);
      case Sfx.merge:
        return _tone(const [440, 880], 0.14, wave: _sine, volume: 0.35);
      case Sfx.thud:
        return _tone(const [90, 60], 0.12, wave: _sine, volume: 0.5);
    }
  }

  static double _sine(double phase, math.Random r) => math.sin(phase * 2 * math.pi);
  static double _square(double phase, math.Random r) => (phase % 1) < 0.5 ? 1 : -1;
  static double _triangle(double phase, math.Random r) {
    final p = phase % 1;
    return p < 0.5 ? 4 * p - 1 : 3 - 4 * p;
  }

  static double _noise(double phase, math.Random r) => r.nextDouble() * 2 - 1;
  static double _noiseSquare(double phase, math.Random r) => 0.6 * _square(phase, r) + 0.4 * _noise(phase, r);

  /// Plays [freqs] as consecutive steps over [seconds] with a linear decay.
  static Uint8List _tone(
    List<double> freqs,
    double seconds, {
    required double Function(double phase, math.Random r) wave,
    double volume = 0.3,
  }) {
    final rng = math.Random(7);
    final n = (seconds * sampleRate).round();
    final pcm = Int16List(n);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final step = math.min(freqs.length - 1, (t * freqs.length).floor());
      phase += freqs[step] / sampleRate;
      final attack = math.min(1.0, i / (0.005 * sampleRate));
      final env = attack * (1 - t);
      pcm[i] = (wave(phase, rng) * env * volume * 32767).round().clamp(-32768, 32767);
    }
    return wav(pcm);
  }

  /// A soft plucked note for MIDI number [midi] (sine + overtone, fast decay).
  static Uint8List note(int midi, {double seconds = 0.45}) {
    final freq = 440 * math.pow(2, (midi - 69) / 12).toDouble();
    final n = (seconds * sampleRate).round();
    final pcm = Int16List(n);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final env = math.min(1.0, i / (0.004 * sampleRate)) * math.exp(-t * 6);
      final v = math.sin(2 * math.pi * freq * t) * 0.7 + math.sin(4 * math.pi * freq * t) * 0.2;
      pcm[i] = (v * env * 0.4 * 32767).round().clamp(-32768, 32767);
    }
    return wav(pcm);
  }

  /// Wraps mono 16-bit PCM samples in a RIFF/WAVE container.
  static Uint8List wav(Int16List pcm) {
    final dataBytes = pcm.lengthInBytes;
    final b = ByteData(44 + dataBytes);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      b.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

/// audioplayers-backed implementation with a small round-robin player pool.
class SynthAudio implements AsobiAudio {
  SynthAudio(this.settings);

  final AsobiSettings settings;
  final Map<Sfx, Uint8List> _bank = {};
  final List<AudioPlayer> _pool = [];
  final Map<Sfx, int> _lastPlayedMs = {};
  final Stopwatch _clock = Stopwatch()..start();
  int _next = 0;
  bool _broken = false;

  static const int poolSize = 4;

  AudioPlayer _player() {
    if (_pool.length < poolSize) {
      final p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
      _pool.add(p);
      return p;
    }
    _next = (_next + 1) % _pool.length;
    return _pool[_next];
  }

  @override
  void play(Sfx sfx) {
    if (!settings.sound || _broken) return;
    final now = _clock.elapsedMilliseconds;
    if (now - (_lastPlayedMs[sfx] ?? -1000) < 45) return; // de-spam
    _lastPlayedMs[sfx] = now;
    final bytes = _bank.putIfAbsent(sfx, () => SfxSynth.render(sfx));
    try {
      final p = _player();
      p.stop().then((_) => p.play(BytesSource(bytes, mimeType: 'audio/wav'))).catchError((Object e) {
        debugPrint('Yantrasobi audio disabled: $e');
        _broken = true;
      });
    } catch (e) {
      debugPrint('Yantrasobi audio disabled: $e');
      _broken = true;
    }
  }

  final Map<int, Uint8List> _notes = {};

  @override
  void playNote(int midi) {
    if (!settings.sound || _broken) return;
    final bytes = _notes.putIfAbsent(midi, () => SfxSynth.note(midi));
    try {
      final p = _player();
      p.stop().then((_) => p.play(BytesSource(bytes, mimeType: 'audio/wav'))).catchError((Object e) {
        debugPrint('Yantrasobi audio disabled: $e');
        _broken = true;
      });
    } catch (e) {
      _broken = true;
    }
  }

  @override
  void haptic([HapticKind kind = HapticKind.light]) {
    if (!settings.haptics) return;
    switch (kind) {
      case HapticKind.light:
        HapticFeedback.lightImpact();
      case HapticKind.medium:
        HapticFeedback.mediumImpact();
      case HapticKind.heavy:
        HapticFeedback.heavyImpact();
      case HapticKind.selection:
        HapticFeedback.selectionClick();
    }
  }

  @override
  void dispose() {
    for (final p in _pool) {
      p.dispose();
    }
    _pool.clear();
  }
}
