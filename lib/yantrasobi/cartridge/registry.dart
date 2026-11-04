import 'cartridge.dart';
import 'manifest.dart';

/// Thrown when a cartridge fails manifest validation at registration.
class CartridgeRejected implements Exception {
  CartridgeRejected(this.id, this.problems);

  final String id;
  final List<String> problems;

  @override
  String toString() => 'Cartridge "$id" rejected: ${problems.join('; ')}';
}

/// Holds every bundled cartridge, validated and keyed by id.
class CartridgeRegistry {
  CartridgeRegistry([Iterable<Cartridge> cartridges = const []]) {
    cartridges.forEach(register);
  }

  final Map<String, Cartridge> _byId = {};

  void register(Cartridge cartridge) {
    final m = cartridge.manifest;
    final problems = m.validate();
    if (_byId.containsKey(m.id)) problems.add('duplicate id');
    if (problems.isNotEmpty) throw CartridgeRejected(m.id, problems);
    _byId[m.id] = cartridge;
  }

  List<Cartridge> get all => List.unmodifiable(_byId.values);

  Cartridge? byId(String id) => _byId[id];

  List<Cartridge> search(String query, {CartridgeEngine? engine}) => _byId.values
      .where((c) => engine == null || c.manifest.engine == engine)
      .where((c) => c.manifest.matchesQuery(query))
      .toList();

  int get length => _byId.length;
}
