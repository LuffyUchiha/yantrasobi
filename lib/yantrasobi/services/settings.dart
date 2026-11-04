import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'save_store.dart';

/// Console-wide user settings, persisted as one JSON blob.
class AsobiSettings extends ChangeNotifier {
  AsobiSettings(this._store);

  static const String storageKey = 'yantrasobi.settings';

  final KeyValueStore _store;

  bool _sound = true;
  bool _haptics = true;
  bool _showPerf = false;
  bool _reducedEffects = false;

  bool get sound => _sound;
  bool get haptics => _haptics;

  /// Shows the FPS / entity counter overlay inside cartridges.
  bool get showPerf => _showPerf;

  /// Cartridges may lower particle counts / screen shake when set.
  bool get reducedEffects => _reducedEffects;

  set sound(bool v) => _set(() => _sound = v);
  set haptics(bool v) => _set(() => _haptics = v);
  set showPerf(bool v) => _set(() => _showPerf = v);
  set reducedEffects(bool v) => _set(() => _reducedEffects = v);

  void _set(VoidCallback change) {
    change();
    notifyListeners();
    _store.write(storageKey, jsonEncode(toJson()));
  }

  Map<String, Object?> toJson() => {
    'sound': _sound,
    'haptics': _haptics,
    'showPerf': _showPerf,
    'reducedEffects': _reducedEffects,
  };

  Future<void> load() async {
    final raw = await _store.read(storageKey);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        _sound = json['sound'] as bool? ?? _sound;
        _haptics = json['haptics'] as bool? ?? _haptics;
        _showPerf = json['showPerf'] as bool? ?? _showPerf;
        _reducedEffects = json['reducedEffects'] as bool? ?? _reducedEffects;
        notifyListeners();
      }
    } on FormatException {
      // Corrupt settings: keep defaults.
    }
  }
}
