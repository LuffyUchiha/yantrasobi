import 'dart:convert';

import '../cartridge/cartridge.dart';
import '../cartridge/registry.dart';
import '../services/save_store.dart';

/// Declarative content packs for already-installed cartridges.
///
/// A data pack is **pure JSON data** (levels, tuning, palettes) addressed to
/// one bundled cartridge. It can never contain or load executable code: the
/// host only parses JSON, checks it against the pack envelope, and hands the
/// `payload` map to the target cartridge's own validator. Cartridges decide
/// how (and whether) to use the data. This is the boundary that lets packs be
/// downloaded or pasted from untrusted sources safely.
///
/// Envelope (schema 1):
/// ```json
/// {
///   "format": "yantrasobi.datapack",
///   "schema": 1,
///   "id": "brickfall.neon-nights",
///   "cartridge": "brickfall",
///   "title": "Neon Nights",
///   "version": "1.0.0",
///   "author": "optional",
///   "payload": { ...cartridge specific... }
/// }
/// ```
const String kDataPackFormat = 'yantrasobi.datapack';
const int kDataPackSchema = 1;

/// Largest accepted pack, in UTF-16 code units of the raw JSON.
const int kDataPackMaxChars = 256 * 1024;

class DataPackError implements Exception {
  DataPackError(this.problems);
  final List<String> problems;
  @override
  String toString() => 'Invalid data pack: ${problems.join('; ')}';
}

/// Implemented by cartridges that accept data packs.
abstract interface class DataPackConsumer {
  /// Human description of what packs for this cartridge contain.
  String get dataPackDescription;

  /// Validates a pack payload; returns problems (empty = valid).
  List<String> validatePackPayload(Map<String, Object?> payload);
}

class DataPack {
  const DataPack({
    required this.id,
    required this.cartridgeId,
    required this.title,
    required this.version,
    required this.payload,
    this.author = '',
  });

  final String id;
  final String cartridgeId;
  final String title;
  final String version;
  final String author;
  final Map<String, Object?> payload;

  static final RegExp _id = RegExp(r'^[a-z0-9][a-z0-9.\-]{2,63}$');
  static final RegExp _semver = RegExp(r'^\d+\.\d+\.\d+$');

  Map<String, Object?> toJson() => {
    'format': kDataPackFormat,
    'schema': kDataPackSchema,
    'id': id,
    'cartridge': cartridgeId,
    'title': title,
    'version': version,
    if (author.isNotEmpty) 'author': author,
    'payload': payload,
  };

  /// Parses and validates the envelope (not the payload).
  static DataPack parse(String raw) {
    if (raw.length > kDataPackMaxChars) {
      throw DataPackError(['pack is larger than ${kDataPackMaxChars ~/ 1024} KB']);
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException catch (e) {
      throw DataPackError(['not valid JSON (${e.message})']);
    }
    if (json is! Map<String, dynamic>) throw DataPackError(['top level must be a JSON object']);
    final Map<String, dynamic> map = json;
    final problems = <String>[];
    String str(String k) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      problems.add('missing "$k"');
      return '';
    }

    if (json['format'] != kDataPackFormat) problems.add('"format" must be "$kDataPackFormat"');
    final schema = json['schema'];
    if (schema is! int || schema < 1) {
      problems.add('"schema" must be a positive integer');
    } else if (schema > kDataPackSchema) {
      problems.add('pack schema $schema is newer than supported ($kDataPackSchema)');
    }
    final id = str('id');
    if (id.isNotEmpty && !_id.hasMatch(id)) {
      problems.add('"id" must be lowercase letters, digits, dots, dashes');
    }
    final cartridge = str('cartridge');
    final title = str('title');
    final version = str('version');
    if (version.isNotEmpty && !_semver.hasMatch(version)) problems.add('"version" must be semver');
    final payload = json['payload'];
    if (payload is! Map<String, dynamic>) problems.add('"payload" must be a JSON object');
    if (problems.isNotEmpty) throw DataPackError(problems);
    final author = json['author'];
    return DataPack(
      id: id,
      cartridgeId: cartridge,
      title: title,
      version: version,
      author: author is String ? author : '',
      payload: Map<String, Object?>.of(payload as Map<String, dynamic>),
    );
  }
}

/// Installed packs, persisted as one JSON list.
class DataPackRepository {
  DataPackRepository(this._store, this._registry);

  static const String storageKey = 'yantrasobi.datapacks';

  final KeyValueStore _store;
  final CartridgeRegistry _registry;
  final List<DataPack> _packs = [];

  List<DataPack> get installed => List.unmodifiable(_packs);

  List<DataPack> packsFor(String cartridgeId) => _packs.where((p) => p.cartridgeId == cartridgeId).toList();

  Future<void> load() async {
    _packs.clear();
    final raw = await _store.read(storageKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list) {
        try {
          final pack = DataPack.parse(jsonEncode(item));
          if (_validateAgainstCartridge(pack).isEmpty) _packs.add(pack);
        } on DataPackError {
          // Drop packs that no longer validate (e.g. cartridge removed).
        }
      }
    } on FormatException {
      // Corrupt storage: start empty.
    }
  }

  List<String> _validateAgainstCartridge(DataPack pack) {
    final Cartridge? cartridge = _registry.byId(pack.cartridgeId);
    if (cartridge == null) return ['no installed cartridge "${pack.cartridgeId}"'];
    if (cartridge is! DataPackConsumer) return ['"${cartridge.manifest.title}" does not accept data packs'];
    return (cartridge as DataPackConsumer).validatePackPayload(pack.payload);
  }

  /// Validates and installs [raw] JSON, replacing a pack with the same id.
  Future<DataPack> install(String raw) async {
    final pack = DataPack.parse(raw);
    final problems = _validateAgainstCartridge(pack);
    if (problems.isNotEmpty) throw DataPackError(problems);
    _packs
      ..removeWhere((p) => p.id == pack.id)
      ..add(pack);
    await _persist();
    return pack;
  }

  Future<void> remove(String id) async {
    _packs.removeWhere((p) => p.id == id);
    await _persist();
  }

  Future<void> _persist() => _store.write(storageKey, jsonEncode([for (final p in _packs) p.toJson()]));
}
