import 'package:flutter/material.dart';

import '../cartridge/manifest.dart';
import '../runtime/services.dart';
import 'data_packs_screen.dart';

/// Console-wide settings.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AsobiScope.of(context);
    final s = services.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              key: const Key('settings.sound'),
              title: const Text('Sound effects'),
              subtitle: const Text('Procedurally synthesised SFX'),
              value: s.sound,
              onChanged: (v) => s.sound = v,
            ),
            SwitchListTile(
              key: const Key('settings.haptics'),
              title: const Text('Haptics'),
              value: s.haptics,
              onChanged: (v) => s.haptics = v,
            ),
            SwitchListTile(
              key: const Key('settings.perf'),
              title: const Text('Performance overlay'),
              subtitle: const Text('Measured FPS and live entity count in games'),
              value: s.showPerf,
              onChanged: (v) => s.showPerf = v,
            ),
            SwitchListTile(
              key: const Key('settings.reduced'),
              title: const Text('Reduced effects'),
              subtitle: const Text('Fewer particles and less screen shake'),
              value: s.reducedEffects,
              onChanged: (v) => s.reducedEffects = v,
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'PLAY TOGETHER',
                style: TextStyle(fontSize: 12, letterSpacing: 1.4, color: Colors.white54),
              ),
            ),
            ListTile(
              key: const Key('settings.playerName'),
              leading: const Icon(Icons.badge_rounded),
              title: const Text('Your name'),
              subtitle: Text(s.playerName.isEmpty ? 'Shown to friends in a party' : s.playerName),
              onTap: () async {
                final v = await _editText(context, 'Your name', s.playerName, hint: 'Asha');
                if (v != null) s.playerName = v;
              },
            ),
            ListTile(
              key: const Key('settings.relay'),
              leading: const Icon(Icons.dns_rounded),
              title: const Text('Party relay'),
              subtitle: Text(
                s.relayUrl.isEmpty
                    ? 'Not set · needed to play across phones (see docs/MULTIPLAYER.md)'
                    : s.relayUrl,
              ),
              onTap: () async {
                final v = await _editText(
                  context,
                  'Party relay address',
                  s.relayUrl,
                  hint: 'wss://party.example.com or 192.168.1.20:8787',
                );
                if (v != null) s.relayUrl = v;
              },
            ),
            const Divider(),
            ListTile(
              key: const Key('settings.packs'),
              leading: const Icon(Icons.extension_rounded),
              title: const Text('Data packs'),
              subtitle: Text('${services.packs.installed.length} installed · levels and content as JSON'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const DataPacksScreen())),
            ),
            ListTile(
              title: const Text('About'),
              subtitle: Text(
                'Yantrasobi console · cartridge API v$kCartridgeApiVersion · '
                '${services.registry.length} bundled cartridges.\n'
                'All cartridge code is compiled into the app; no code is downloaded.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _editText(BuildContext context, String title, String initial, {String? hint}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('settings.editField'),
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          key: const Key('settings.editSave'),
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}
