import 'package:flutter/material.dart';

import '../cartridge/cartridge.dart';
import '../cartridge/manifest.dart';
import '../runtime/cartridge_host.dart';
import '../runtime/services.dart';
import '../services/audio.dart';
import '../services/save_store.dart';
import 'cover_art.dart';

/// Cartridge details: description, goal, controls, stats, play and save reset.
class CartridgeDetailScreen extends StatefulWidget {
  const CartridgeDetailScreen({super.key, required this.cartridge});

  final Cartridge cartridge;

  @override
  State<CartridgeDetailScreen> createState() => _CartridgeDetailScreenState();
}

class _CartridgeDetailScreenState extends State<CartridgeDetailScreen> {
  Future<void> _play() async {
    final services = AsobiScope.of(context);
    services.audio.play(Sfx.tap);
    await services.saves.load(widget.cartridge.manifest.id);
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => CartridgeHostScreen(cartridge: widget.cartridge)));
    if (mounted) setState(() {}); // refresh stats
  }

  Future<void> _resetSave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset save?'),
        content: Text('All progress and stats for ${widget.cartridge.manifest.title} will be erased.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('detail.confirmReset'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AsobiScope.of(context).saves.reset(widget.cartridge.manifest.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.cartridge.manifest;
    final save = AsobiScope.of(context).saves.peek(m.id) ?? CartridgeSave();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(m.title),
        actions: [
          IconButton(
            key: const Key('detail.reset'),
            tooltip: 'Reset save',
            icon: const Icon(Icons.restart_alt_rounded),
            onPressed: _resetSave,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Hero(
                tag: 'cover.${m.id}',
                child: CartridgeCover(manifest: m, iconSize: 72),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(m.tagline, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill(m.genre),
              _pill(m.engine == CartridgeEngine.scene3d ? '3D · flutter_scene' : '2D · Flame'),
              _pill('v${m.version}'),
              if (m.maturity != CartridgeMaturity.complete) _pill(m.maturity.name),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('detail.play'),
            style: FilledButton.styleFrom(
              backgroundColor: m.accent,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: _play,
            icon: const Icon(Icons.play_arrow_rounded, size: 30),
            label: const Text('PLAY', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _stat('Best', '${save.bestScore}'),
              _stat('Last', '${save.lastScore}'),
              _stat('Plays', '${save.plays}'),
              _stat('Wins', '${save.wins}'),
            ],
          ),
          _section('Goal', Text(m.goal)),
          _section('About', Text(m.description)),
          _section(
            'Controls',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final c in m.controls) Text('• $c')],
            ),
          ),
          if (m.mechanics.isNotEmpty)
            _section('Mechanics', Wrap(spacing: 6, runSpacing: 6, children: m.mechanics.map(_pill).toList())),
        ],
      ),
    );
  }

  Widget _pill(String text) => Chip(label: Text(text), visualDensity: VisualDensity.compact);

  Widget _stat(String label, String value) => Expanded(
    child: Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white60)),
      ],
    ),
  );

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(fontSize: 12, letterSpacing: 1.4, color: Colors.white54),
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );
}
