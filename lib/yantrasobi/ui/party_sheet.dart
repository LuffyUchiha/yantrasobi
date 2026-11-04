import 'package:asobi_party/asobi_party.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../party/party_service.dart';
import '../runtime/services.dart';

/// Opens the "Play together" sheet: start a party, join one, or share this phone.
Future<void> showPartySheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const PartySheet(),
);

class PartySheet extends StatefulWidget {
  const PartySheet({super.key});

  @override
  State<PartySheet> createState() => _PartySheetState();
}

class _PartySheetState extends State<PartySheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _code = TextEditingController();
  int _localPlayers = 2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_name.text.isEmpty) _name.text = AsobiScope.of(context).settings.playerName;
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _saveName(AsobiServices s) {
    if (_name.text.trim() != s.settings.playerName) s.settings.playerName = _name.text;
  }

  Future<void> _run(Future<void> Function(AsobiParty party) action) async {
    final s = AsobiScope.of(context);
    _saveName(s);
    await action(s.party);
    if (mounted && s.party.active) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final services = AsobiScope.of(context);
    final party = services.party;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: party,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Play together',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              const Text(
                'The library shrinks to the games everyone in the party can play.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('party.name'),
                controller: _name,
                maxLength: 16,
                decoration: const InputDecoration(labelText: 'Your name', counterText: ''),
              ),
              const SizedBox(height: 18),
              _heading('Online with friends'),
              if (!party.relayConfigured)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Set a party relay address in Settings to play across phones.',
                    style: TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              FilledButton.icon(
                key: const Key('party.host'),
                onPressed: party.busy || !party.relayConfigured ? null : () => _run((p) => p.host()),
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: const Text('Start a party'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('party.code'),
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                        LengthLimitingTextInputFormatter(kRoomCodeLength),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Party code', hintText: 'K7QF3M'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.tonal(
                    key: const Key('party.join'),
                    onPressed: party.busy || !party.relayConfigured || _code.text.length != kRoomCodeLength
                        ? null
                        : () => _run((p) => p.join(_code.text)),
                    child: const Text('Join'),
                  ),
                ],
              ),
              if (party.busy)
                const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
              if (party.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    party.error!,
                    key: const Key('party.error'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              const SizedBox(height: 22),
              _heading('On this phone'),
              SegmentedButton<int>(
                key: const Key('party.localCount'),
                segments: const [
                  ButtonSegment(value: 2, label: Text('2 players')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 4, label: Text('4')),
                ],
                selected: {_localPlayers},
                onSelectionChanged: (v) => setState(() => _localPlayers = v.first),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('party.local'),
                onPressed: () => _run((p) {
                  final me = _name.text.trim().isEmpty ? 'Player 1' : _name.text.trim();
                  return p.sameDevice([me, for (var i = 2; i <= _localPlayers; i++) 'Player $i']);
                }),
                icon: const Icon(Icons.people_alt_rounded),
                label: const Text('Share this phone'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(fontSize: 12, letterSpacing: 1.4, color: Colors.white54),
    ),
  );
}

/// Shown above the library while a party is open.
class PartyBanner extends StatelessWidget {
  const PartyBanner({super.key, required this.party, required this.gameCount});

  final AsobiParty party;
  final int gameCount;

  @override
  Widget build(BuildContext context) {
    final c = party.controller!;
    final online = c.connection == Connection.online;
    final names = [for (final m in c.members) '${m.name}${m.id == c.hostId && online ? ' (host)' : ''}']
        .join(', ');
    return Container(
      key: const Key('party.banner'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF23264A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF5B6BFF)),
      ),
      child: Row(
        children: [
          Icon(online ? Icons.groups_rounded : Icons.people_alt_rounded, color: const Color(0xFF9AA6FF)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? (c.code == null ? 'Connecting…' : 'Party ${c.code}') : 'Sharing this phone',
                  key: const Key('party.bannerTitle'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  '$names · ${c.members.length} players · $gameCount games',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          if (online && c.code != null)
            IconButton(
              tooltip: 'Copy code',
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () => Clipboard.setData(ClipboardData(text: c.code!)),
            ),
          TextButton(key: const Key('party.leave'), onPressed: party.leave, child: const Text('Leave')),
        ],
      ),
    );
  }
}

/// Bottom bar of the party library: who picked what, ready-up and start.
class PartyLobbyBar extends StatelessWidget {
  const PartyLobbyBar({super.key, required this.party, required this.titleOf});

  final AsobiParty party;
  final String Function(String id) titleOf;

  @override
  Widget build(BuildContext context) {
    final c = party.controller!;
    final online = c.connection == Connection.online;
    final me = c.members.where((m) => m.isSelf).firstOrNull;
    final picked = c.selectedGameId;
    final waiting = [
      for (final m in c.members)
        if (!m.ready) m.name,
    ];
    final String status;
    if (c.members.length < 2) {
      status = 'Share the code: friends join from Play together → Join.';
    } else if (picked == null) {
      status = c.isHost ? 'Tap a game to pick it for everyone.' : 'The host is choosing a game…';
    } else if (online && waiting.isNotEmpty) {
      status = '${titleOf(picked)} · waiting for ${waiting.join(', ')}';
    } else {
      status = '${titleOf(picked)} · everyone is ready';
    }
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('party.lobbyBar'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        color: const Color(0xFF181A2B),
        child: Row(
          children: [
            Expanded(
              child: Text(
                status,
                key: const Key('party.status'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            if (online && me != null && picked != null)
              FilterChip(
                key: const Key('party.ready'),
                label: const Text('Ready'),
                selected: me.ready,
                onSelected: c.setReady,
              ),
            if (c.isHost) ...[
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('party.start'),
                onPressed: c.canStart ? c.start : null,
                child: const Text('START'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
