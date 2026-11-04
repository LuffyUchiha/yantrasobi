import 'package:flutter/widgets.dart';

/// Version of the cartridge contract implemented by Yantrasobi.
///
/// A cartridge declares the API version it was written against in its
/// [CartridgeManifest]. The registry refuses to mount cartridges whose API
/// version is newer than the host, or older than [kMinSupportedCartridgeApi].
const int kCartridgeApiVersion = 1;

/// Oldest cartridge API version this host can still run.
const int kMinSupportedCartridgeApi = 1;

/// Which rendering adapter a cartridge runs on.
enum CartridgeEngine {
  /// Flame 2D game loop (`FlameCartridgeSession`).
  flame2d,

  /// flutter_scene 3D renderer (`SceneCartridgeSession`).
  scene3d,

  /// Plain Flutter widgets.
  widgets,
}

/// Implementation completeness, mirrored in CARTRIDGES.md.
enum CartridgeMaturity { complete, partial, experimental }

/// Static, declarative description of a cartridge.
///
/// The manifest is pure data: it can be serialised to/from JSON so that a
/// future downloadable *data pack* can describe levels and art for an
/// already-bundled cartridge. Executable Dart code is never downloaded; every
/// cartridge's code is compiled into the app at build time.
@immutable
class CartridgeManifest {
  const CartridgeManifest({
    required this.id,
    required this.title,
    required this.tagline,
    required this.description,
    required this.genre,
    required this.engine,
    required this.version,
    required this.accent,
    required this.icon,
    this.apiVersion = kCartridgeApiVersion,
    this.tags = const [],
    this.controls = const [],
    this.mechanics = const [],
    this.goal = '',
    this.maturity = CartridgeMaturity.complete,
  });

  /// Stable, unique id, lowercase with dashes. Used as the save-slot key.
  final String id;
  final String title;
  final String tagline;
  final String description;
  final String genre;
  final CartridgeEngine engine;

  /// Semantic version of the cartridge itself (`major.minor.patch`).
  final String version;

  /// Cartridge contract version (see [kCartridgeApiVersion]).
  final int apiVersion;
  final Color accent;
  final IconData icon;
  final List<String> tags;
  final List<String> controls;
  final List<String> mechanics;
  final String goal;
  final CartridgeMaturity maturity;

  static final RegExp _idPattern = RegExp(r'^[a-z][a-z0-9-]{1,40}$');
  static final RegExp _semver = RegExp(r'^\d+\.\d+\.\d+$');

  /// Returns a list of human-readable validation problems (empty if valid).
  List<String> validate() {
    final problems = <String>[];
    if (!_idPattern.hasMatch(id)) problems.add('invalid id "$id"');
    if (title.trim().isEmpty) problems.add('empty title');
    if (!_semver.hasMatch(version)) problems.add('version "$version" is not semver');
    if (apiVersion > kCartridgeApiVersion) {
      problems.add('requires cartridge API $apiVersion > host $kCartridgeApiVersion');
    }
    if (apiVersion < kMinSupportedCartridgeApi) {
      problems.add('cartridge API $apiVersion is no longer supported');
    }
    if (goal.trim().isEmpty) problems.add('missing goal text');
    if (controls.isEmpty) problems.add('missing control hints');
    return problems;
  }

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = [title, tagline, genre, engine.name, ...tags, ...mechanics].join(' ').toLowerCase();
    return q.split(RegExp(r'\s+')).every(haystack.contains);
  }

  /// Serialisable view used by data packs, tests and debugging tools.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'tagline': tagline,
    'description': description,
    'genre': genre,
    'engine': engine.name,
    'version': version,
    'apiVersion': apiVersion,
    'accent': accent.toARGB32(),
    'tags': tags,
    'controls': controls,
    'mechanics': mechanics,
    'goal': goal,
    'maturity': maturity.name,
  };
}
