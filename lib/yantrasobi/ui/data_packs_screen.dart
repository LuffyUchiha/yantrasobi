import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../datapacks/data_pack.dart';
import '../runtime/services.dart';

/// Lists installed data packs and installs new ones from pasted JSON or the
/// bundled samples. Packs are data only; nothing here executes code.
class DataPacksScreen extends StatefulWidget {
  const DataPacksScreen({super.key});

  static const List<String> bundledSamples = ['assets/datapacks/brickfall_neon_nights.json'];

  @override
  State<DataPacksScreen> createState() => _DataPacksScreenState();
}

class _DataPacksScreenState extends State<DataPacksScreen> {
  String? _message;
  bool _error = false;

  Future<void> _install(String raw) async {
    final services = AsobiScope.of(context);
    try {
      final pack = await services.packs.install(raw);
      final cart = services.registry.byId(pack.cartridgeId)!.manifest.title;
      setState(() {
        _error = false;
        _message = 'Installed "${pack.title}" for $cart.';
      });
    } on DataPackError catch (e) {
      setState(() {
        _error = true;
        _message = e.problems.join('\n');
      });
    }
  }

  Future<void> _installSample(String asset) async {
    final raw = await rootBundle.loadString(asset);
    if (mounted) await _install(raw);
  }

  Future<void> _paste() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste data pack JSON'),
        content: SizedBox(
          width: 400,
          child: TextField(
            key: const Key('packs.input'),
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(hintText: '{"format": "yantrasobi.datapack", ...}'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            key: const Key('packs.installPasted'),
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw != null && raw.trim().isNotEmpty && mounted) await _install(raw);
  }

  @override
  Widget build(BuildContext context) {
    final services = AsobiScope.of(context);
    final packs = services.packs.installed;
    return Scaffold(
      appBar: AppBar(title: const Text('Data packs')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Data packs add content such as levels to cartridges you already have. They are plain JSON '
            'checked by the console and the target cartridge. Packs never contain code; game code '
            'only ships inside app updates.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('packs.paste'),
                onPressed: _paste,
                icon: const Icon(Icons.content_paste_rounded),
                label: const Text('Paste JSON'),
              ),
              for (final asset in DataPacksScreen.bundledSamples)
                OutlinedButton.icon(
                  key: Key('packs.sample.$asset'),
                  onPressed: () => _installSample(asset),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Install sample: Neon Nights'),
                ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(
              _message!,
              key: const Key('packs.message'),
              style: TextStyle(color: _error ? Colors.redAccent : Colors.greenAccent),
            ),
          ],
          const SizedBox(height: 20),
          Text('INSTALLED (${packs.length})', style: const TextStyle(fontSize: 12, letterSpacing: 1.4)),
          if (packs.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No packs installed.')),
          for (final p in packs)
            Card(
              child: ListTile(
                key: Key('packs.item.${p.id}'),
                title: Text(p.title),
                subtitle: Text(
                  '${services.registry.byId(p.cartridgeId)?.manifest.title ?? p.cartridgeId} · v${p.version}'
                  '${p.author.isEmpty ? '' : ' · ${p.author}'}',
                ),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    await services.packs.remove(p.id);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
