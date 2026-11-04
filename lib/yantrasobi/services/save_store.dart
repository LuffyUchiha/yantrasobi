import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Minimal async key/value persistence used by Yantrasobi.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// In-memory store for tests and for platforms without persistence.
class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// shared_preferences-backed store (Android SharedPreferences, web localStorage).
class PrefsKeyValueStore implements KeyValueStore {
  PrefsKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<PrefsKeyValueStore> open() async => PrefsKeyValueStore(await SharedPreferences.getInstance());

  @override
  Future<String?> read(String key) async => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> delete(String key) => _prefs.remove(key);
}

/// Current on-disk schema version for [CartridgeSave].
const int kSaveSchemaVersion = 1;

/// Per-cartridge persistent progress.
///
/// Common stats (best score, plays, wins) are tracked by the host; anything
/// game-specific lives in [data], which must stay JSON-encodable.
class CartridgeSave {
  CartridgeSave({
    this.bestScore = 0,
    this.plays = 0,
    this.wins = 0,
    this.lastScore = 0,
    Map<String, Object?>? data,
  }) : data = data ?? <String, Object?>{};

  int bestScore;
  int plays;
  int wins;
  int lastScore;
  final Map<String, Object?> data;

  int intData(String key, [int fallback = 0]) {
    final v = data[key];
    return v is num ? v.toInt() : fallback;
  }

  Map<String, Object?> toJson() => {
    'v': kSaveSchemaVersion,
    'bestScore': bestScore,
    'plays': plays,
    'wins': wins,
    'lastScore': lastScore,
    'data': data,
  };

  /// Decodes a save, tolerating corrupt or unknown-version payloads by
  /// returning a fresh save rather than crashing the console.
  factory CartridgeSave.fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return CartridgeSave();
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return CartridgeSave();
      final v = json['v'];
      if (v is! int || v > kSaveSchemaVersion) return CartridgeSave();
      int n(String k) => (json[k] as num?)?.toInt() ?? 0;
      final data = json['data'];
      return CartridgeSave(
        bestScore: n('bestScore'),
        plays: n('plays'),
        wins: n('wins'),
        lastScore: n('lastScore'),
        data: data is Map<String, dynamic> ? Map<String, Object?>.of(data) : null,
      );
    } on FormatException {
      return CartridgeSave();
    }
  }
}

/// Loads and stores [CartridgeSave]s keyed by cartridge id.
class SaveRepository {
  SaveRepository(this.store);

  final KeyValueStore store;
  final Map<String, CartridgeSave> _cache = {};

  static String keyFor(String cartridgeId) => 'yantrasobi.save.$cartridgeId';

  Future<CartridgeSave> load(String cartridgeId) async {
    final cached = _cache[cartridgeId];
    if (cached != null) return cached;
    final save = CartridgeSave.fromJsonString(await store.read(keyFor(cartridgeId)));
    _cache[cartridgeId] = save;
    return save;
  }

  /// Synchronous access to an already-loaded save (null if never loaded).
  CartridgeSave? peek(String cartridgeId) => _cache[cartridgeId];

  Future<void> persist(String cartridgeId, CartridgeSave save) async {
    _cache[cartridgeId] = save;
    await store.write(keyFor(cartridgeId), jsonEncode(save.toJson()));
  }

  Future<void> reset(String cartridgeId) async {
    _cache[cartridgeId] = CartridgeSave();
    await store.delete(keyFor(cartridgeId));
  }
}
