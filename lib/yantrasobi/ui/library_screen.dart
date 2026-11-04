import 'package:flutter/material.dart';

import '../cartridge/cartridge.dart';
import '../cartridge/manifest.dart';
import '../runtime/services.dart';
import 'cover_art.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

/// The console's home: searchable grid of bundled cartridges.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _query = TextEditingController();
  CartridgeEngine? _engine;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AsobiScope.of(context);
    final results = services.registry.search(_query.text, engine: _engine);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yantrasobi', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
        actions: [
          IconButton(
            key: const Key('library.settings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const Key('library.search'),
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search cartridges, genres, mechanics…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(_query.clear),
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _chip('All', null),
                _chip('2D · Flame', CartridgeEngine.flame2d),
                _chip('3D · Scene', CartridgeEngine.scene3d),
                _chip('UI · Widgets', CartridgeEngine.widgets),
              ],
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? const Center(key: Key('library.empty'), child: Text('No cartridges match your search.'))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: results.length,
                    itemBuilder: (context, i) => _CartridgeTile(cartridge: results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, CartridgeEngine? engine) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: ChoiceChip(
      label: Text(label),
      selected: _engine == engine,
      onSelected: (_) => setState(() => _engine = engine),
    ),
  );
}

class _CartridgeTile extends StatelessWidget {
  const _CartridgeTile({required this.cartridge});

  final Cartridge cartridge;

  @override
  Widget build(BuildContext context) {
    final m = cartridge.manifest;
    final save = AsobiScope.of(context).saves.peek(m.id);
    return Card(
      key: Key('library.tile.${m.id}'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => CartridgeDetailScreen(cartridge: cartridge))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Hero(
                tag: 'cover.${m.id}',
                child: CartridgeCover(manifest: m),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${m.genre} · ${m.engineBadge}'
                    '${save != null && save.bestScore > 0 ? ' · best ${save.bestScore}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
