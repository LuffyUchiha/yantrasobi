import 'dart:async';

import 'package:asobi_party/asobi_party.dart';
import 'package:flutter/material.dart';

import '../cartridge/cartridge.dart';
import '../cartridge/manifest.dart';
import '../runtime/cartridge_host.dart';
import '../runtime/services.dart';
import 'cover_art.dart';
import 'detail_screen.dart';
import 'party_sheet.dart';
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
  StreamSubscription<PartyMatch>? _matchSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _matchSub ??= AsobiScope.of(context).party.matches.listen(_launchMatch);
  }

  @override
  void dispose() {
    _matchSub?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Every phone in the party lands here when the host presses START.
  Future<void> _launchMatch(PartyMatch match) async {
    if (!mounted) return;
    final services = AsobiScope.of(context);
    final cartridge = services.registry.byId(match.gameId);
    if (cartridge == null) return;
    await services.saves.load(match.gameId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CartridgeHostScreen(cartridge: cartridge, match: match),
      ),
    );
    if (mounted) setState(() {});
  }

  void _openTile(Cartridge cartridge) {
    final party = AsobiScope.of(context).party;
    final c = party.controller;
    if (party.active && c != null && c.isHost && c.phase == PartyPhase.lobby) {
      c.select(cartridge.manifest.id);
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => CartridgeDetailScreen(cartridge: cartridge)));
  }

  @override
  Widget build(BuildContext context) {
    final services = AsobiScope.of(context);
    return ListenableBuilder(listenable: services.party, builder: (context, _) => _build(context, services));
  }

  Widget _build(BuildContext context, AsobiServices services) {
    final party = services.party;
    final inParty = party.active;
    final eligible = party.eligibleIds;
    final results = [
      for (final c in services.registry.search(_query.text, engine: _engine))
        if (!inParty || eligible.contains(c.manifest.id)) c,
    ];
    return Scaffold(
      bottomNavigationBar: inParty
          ? PartyLobbyBar(party: party, titleOf: (id) => services.registry.byId(id)?.manifest.title ?? id)
          : null,
      appBar: AppBar(
        title: const Text('Yantrasobi', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
        actions: [
          IconButton(
            key: const Key('library.party'),
            tooltip: 'Play together',
            icon: Icon(inParty ? Icons.groups_rounded : Icons.group_add_rounded),
            color: inParty ? const Color(0xFF9AA6FF) : null,
            onPressed: () => showPartySheet(context),
          ),
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
          if (inParty) PartyBanner(party: party, gameCount: eligible.length),
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
                ? Center(
                    key: const Key('library.empty'),
                    child: Text(
                      inParty && eligible.isEmpty
                          ? 'Waiting for friends to join…'
                          : 'No cartridges match your search.',
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: results.length,
                    itemBuilder: (context, i) => _CartridgeTile(
                      cartridge: results[i],
                      selected: inParty && party.controller?.selectedGameId == results[i].manifest.id,
                      onTap: () => _openTile(results[i]),
                    ),
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
  const _CartridgeTile({required this.cartridge, required this.onTap, this.selected = false});

  final Cartridge cartridge;
  final VoidCallback onTap;

  /// Picked for the party.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final m = cartridge.manifest;
    final save = AsobiScope.of(context).saves.peek(m.id);
    return Card(
      key: Key('library.tile.${m.id}'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: selected ? BorderSide(color: m.accent, width: 3) : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
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
                    '${m.genre} · ${m.engineBadge}${m.playerCap > 1 ? ' · 1-${m.playerCap}P' : ''}'
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
