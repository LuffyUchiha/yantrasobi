import 'dart:async';

import 'package:asobi_party/asobi_party.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../cartridge/cartridge.dart';
import '../services/audio.dart';
import '../services/save_store.dart';
import 'services.dart';

/// Full-screen host for the single active cartridge session.
///
/// Owns the session: creates it on mount, disposes it on unmount. Provides the
/// pause menu, result card, perf overlay, Android back handling and automatic
/// pause when the app is backgrounded.
class CartridgeHostScreen extends StatefulWidget {
  const CartridgeHostScreen({super.key, required this.cartridge, this.match});

  final Cartridge cartridge;

  /// Set when the run is part of a party match (see docs/MULTIPLAYER.md).
  final PartyMatch? match;

  @override
  State<CartridgeHostScreen> createState() => _CartridgeHostScreenState();
}

class _CartridgeHostScreenState extends State<CartridgeHostScreen> with WidgetsBindingObserver {
  CartridgeSession? _session;
  late AsobiServices _services;
  late CartridgeSave _save;
  bool _recordedResult = false;

  // Party match plumbing (null in solo play).
  ParallelRace? _race;
  StreamSubscription<SyncEvent>? _raceSub;
  Timer? _raceTicker;
  bool _reportedToMatch = false;

  PartyMatch? get _match => widget.match;

  /// Online matches can't restart: everyone shares one run.
  bool get _online => _match?.connection == Connection.online;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    _services = AsobiScope.of(context);
    final id = widget.cartridge.manifest.id;
    _save = _services.saves.peek(id) ?? CartridgeSave();
    final session = widget.cartridge.createSession(
      CartridgeContext(
        manifest: widget.cartridge.manifest,
        save: _save,
        audio: _services.audio,
        settings: _services.settings,
        onSaveChanged: _persist,
        dataPacks: [for (final pack in _services.packs.packsFor(id)) pack.payload],
        match: _match,
      ),
    );
    final match = _match;
    if (match != null && _online && match.spec.sync == SyncModel.parallel) {
      final race = ParallelRace(match);
      _race = race;
      _raceSub = race.events.listen((_) {
        if (mounted) setState(() {});
      });
      // The host reports the cartridge's live score, so race cartridges need no network code.
      _raceTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final st = _session?.state;
        if (st == SessionState.running || st == SessionState.paused) race.report(score: session.liveScore);
      });
    }
    _session = session..addListener(_onSessionChanged);
    _save.plays++;
    _persist();
    session.start();
  }

  void _persist() => unawaited(_services.saves.persist(widget.cartridge.manifest.id, _save));

  void _onSessionChanged() {
    final s = _session!;
    if (s.state == SessionState.ended && !_recordedResult) {
      _recordedResult = true;
      final r = s.result!;
      _save.lastScore = r.score;
      if (r.score > _save.bestScore) _save.bestScore = r.score;
      if (r.won == true) _save.wins++;
      _persist();
      _reportToMatch(r.score, r.won);
      _services.audio.play(r.won == false ? Sfx.lose : Sfx.win);
    } else if (s.state == SessionState.running) {
      _recordedResult = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _session?.pause();
  }

  /// Hands this phone's result to the party. Leaving early counts as a loss.
  void _reportToMatch(int score, bool? won) {
    final match = _match;
    if (match == null || _reportedToMatch || match.isOver) return;
    _reportedToMatch = true;
    final race = _race;
    if (race != null) {
      race.finish(score: score, won: won);
      return;
    }
    // Same phone: the cartridge itself says who won; record the shared run for every seat.
    for (final seat in match.localSeats) {
      match.finish(score: score, won: _online ? won : null, seat: seat.index);
    }
  }

  @override
  void dispose() {
    _raceTicker?.cancel();
    if (_match != null && !_reportedToMatch) _reportToMatch(_session?.liveScore ?? 0, false);
    _raceSub?.cancel();
    _race?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _session?.removeListener(_onSessionChanged);
    _session?.dispose();
    _session = null;
    super.dispose();
  }

  void _restart() {
    final s = _session!;
    _save.plays++;
    _persist();
    _services.audio.play(Sfx.tap);
    s.restart();
  }

  void _exit() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final s = _session!;
    final m = widget.cartridge.manifest;
    return PopScope(
      canPop: s.state != SessionState.running,
      onPopInvokedWithResult: (didPop, _) {
        // Back while playing pauses instead of leaving.
        if (!didPop) s.pause();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: s.buildView(context)),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RoundButton(
                        key: const Key('host.pause'),
                        icon: Icons.pause_rounded,
                        tooltip: 'Pause',
                        onPressed: s.isRunning ? s.pause : null,
                      ),
                      if (_services.settings.showPerf) ...[
                        const SizedBox(width: 8),
                        _PerfOverlay(session: s),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (_race != null)
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(64, 10, 8, 0),
                    child: _RaceStrip(match: _match!, race: _race!),
                  ),
                ),
              ),
            if (s.state == SessionState.paused)
              _Panel(
                key: const Key('host.pauseMenu'),
                accent: m.accent,
                title: 'Paused',
                subtitle: m.goal,
                actions: [
                  _PanelAction('Resume', Icons.play_arrow_rounded, s.resume, key: const Key('host.resume')),
                  if (!_online)
                    _PanelAction('Restart', Icons.replay_rounded, _restart, key: const Key('host.restart')),
                  _PanelAction(
                    _online ? 'Forfeit and leave' : 'Exit to library',
                    _online ? Icons.flag_rounded : Icons.grid_view_rounded,
                    _exit,
                    key: const Key('host.exit'),
                  ),
                ],
              ),
            if (s.state == SessionState.ended)
              _ResultPanel(
                result: s.result!,
                best: _save.bestScore,
                accent: m.accent,
                onReplay: _online ? null : _restart,
                onExit: _exit,
                exitLabel: _match != null ? 'Back to party' : 'Exit to library',
                standings: _online ? _Standings(match: _match!) : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.35),
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white),
      onPressed: onPressed,
    ),
  );
}

class _PanelAction {
  const _PanelAction(this.label, this.icon, this.onTap, {this.key});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Key? key;
}

class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.accent,
    required this.title,
    required this.actions,
    this.subtitle,
    this.body,
  });

  final Color accent;
  final String title;
  final String? subtitle;
  final Widget? body;
  final List<_PanelAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.all(22),
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: const Color(0xFF181A2B),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: accent.withValues(alpha: 0.6), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
              if (body != null) ...[const SizedBox(height: 14), body!],
              const SizedBox(height: 18),
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.icon(
                    key: a.key,
                    style: FilledButton.styleFrom(
                      backgroundColor: a == actions.first ? accent : Colors.white12,
                      foregroundColor: a == actions.first ? Colors.black : Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: a.onTap,
                    icon: Icon(a.icon),
                    label: Text(a.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({
    required this.result,
    required this.best,
    required this.accent,
    required this.onReplay,
    required this.onExit,
    this.exitLabel = 'Exit to library',
    this.standings,
  });

  final RunResult result;
  final int best;
  final Color accent;

  /// Null hides "Play again" (online party matches).
  final VoidCallback? onReplay;
  final VoidCallback onExit;
  final String exitLabel;
  final Widget? standings;

  @override
  Widget build(BuildContext context) {
    final title = switch (result.won) {
      true => 'Victory!',
      false => 'Game Over',
      null => 'Run Complete',
    };
    final rows = <MapEntry<String, String>>[
      MapEntry('Score', '${result.score}'),
      MapEntry('Best', '$best'),
      ...result.details.entries,
    ];
    return _Panel(
      key: const Key('host.result'),
      accent: accent,
      title: title,
      subtitle: result.headline,
      body: Column(
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Text(r.key, style: const TextStyle(color: Colors.white60)),
                  const Spacer(),
                  Text(
                    r.value,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          if (standings != null) ...[const Divider(height: 22), standings!],
        ],
      ),
      actions: [
        if (onReplay != null)
          _PanelAction('Play again', Icons.replay_rounded, onReplay!, key: const Key('host.replay')),
        _PanelAction(exitLabel, Icons.grid_view_rounded, onExit, key: const Key('host.resultExit')),
      ],
    );
  }
}

/// Measures the actual frame rate of the host widget plus the session's live
/// entity count. Values are measured on whatever device runs the app.
class _PerfOverlay extends StatefulWidget {
  const _PerfOverlay({required this.session});

  final CartridgeSession session;

  @override
  State<_PerfOverlay> createState() => _PerfOverlayState();
}

class _PerfOverlayState extends State<_PerfOverlay> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _frames = 0;
  Duration _windowStart = Duration.zero;
  double _fps = 0;
  int _entities = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _frames++;
      final span = elapsed - _windowStart;
      if (span >= const Duration(milliseconds: 500)) {
        setState(() {
          _fps = _frames * 1e6 / span.inMicroseconds;
          _entities = widget.session.entityCount;
        });
        _frames = 0;
        _windowStart = elapsed;
      }
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('host.perf'),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      '${_fps.toStringAsFixed(0)} fps · $_entities ent',
      style: const TextStyle(
        color: Colors.greenAccent,
        fontSize: 12,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// Live opponent scores during a party race.
class _RaceStrip extends StatelessWidget {
  const _RaceStrip({required this.match, required this.race});

  final PartyMatch match;
  final ParallelRace race;

  @override
  Widget build(BuildContext context) {
    final opponents = [
      for (final seat in match.seats)
        if (!seat.isLocal) seat,
    ];
    return Wrap(
      key: const Key('host.raceStrip'),
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final seat in opponents)
          Builder(
            builder: (context) {
              final t = race.opponents[seat.index];
              final done = match.results[seat.index];
              final out = !seat.connected || done != null || t?.alive == false;
              final score = done?.score ?? t?.score ?? 0;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${seat.name} $score${!seat.connected ? ' · left' : (out ? ' · done' : '')}',
                  style: TextStyle(
                    color: out ? Colors.white54 : Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Party standings on the result card: final ranking, or who is still playing.
class _Standings extends StatelessWidget {
  const _Standings({required this.match});

  final PartyMatch match;

  @override
  Widget build(BuildContext context) {
    final standings = match.standings;
    if (standings == null) {
      final playing = [
        for (final seat in match.seats)
          if (!match.results.containsKey(seat.index)) seat.name,
      ];
      return Text(
        'Waiting for ${playing.join(', ')} to finish…',
        key: const Key('host.waiting'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      );
    }
    return Column(
      key: const Key('host.standings'),
      children: [
        for (var i = 0; i < standings.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Text('${i + 1}.  ', style: const TextStyle(color: Colors.white60)),
                Expanded(
                  child: Text(
                    '${match.seats[standings[i].seat].name}${match.isLocal(standings[i].seat) ? ' (you)' : ''}'
                    '${standings[i].forfeit ? ' · left' : ''}',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: i == 0 ? FontWeight.w900 : FontWeight.w600,
                    ),
                  ),
                ),
                Text('${standings[i].score}', style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
      ],
    );
  }
}
