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
  String _playerName = '';
  String _relayUrl = kDefaultRelayUrl;

  /// Relay baked in at build time: `--dart-define=YANTRASOBI_RELAY=wss://host`.
  static const String kDefaultRelayUrl = String.fromEnvironment('YANTRASOBI_RELAY');

  bool get sound => _sound;
  bool get haptics => _haptics;

  /// Shows the FPS / entity counter overlay inside cartridges.
  bool get showPerf => _showPerf;

  /// Cartridges may lower particle counts / screen shake when set.
  bool get reducedEffects => _reducedEffects;

  /// Name shown to friends in a party (empty until the player picks one).
  String get playerName => _playerName;

  /// Party relay address, e.g. `wss://party.example.com` or `ws://192.168.1.20:8787`.
  String get relayUrl => _relayUrl;

  set playerName(String v) => _set(() => _playerName = v.trim());
  set relayUrl(String v) => _set(() => _relayUrl = v.trim());

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
    'playerName': _playerName,
    'relayUrl': _relayUrl,
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
        _playerName = json['playerName'] as String? ?? _playerName;
        final relay = json['relayUrl'] as String?;
        if (relay != null && relay.isNotEmpty) _relayUrl = relay;
        notifyListeners();
      }
    } on FormatException {
      // Corrupt settings: keep defaults.
    }
  }
}
