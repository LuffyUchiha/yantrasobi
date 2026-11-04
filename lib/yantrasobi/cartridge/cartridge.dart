import 'package:flutter/widgets.dart';

import '../services/audio.dart';
import '../services/save_store.dart';
import '../services/settings.dart';
import 'manifest.dart';

/// Outcome of one run of a cartridge, reported to the host.
@immutable
class RunResult {
  const RunResult({required this.score, this.won, this.headline, this.details = const {}});

  final int score;

  /// `true` = level cleared, `false` = defeated, `null` = endless/score-attack.
  final bool? won;

  /// Short sentence shown on the result card, e.g. "Wave 7 reached".
  final String? headline;

  /// Extra labelled stats for the result card.
  final Map<String, String> details;
}

/// Everything the host lends to a running cartridge.
class CartridgeContext {
  CartridgeContext({
    required this.manifest,
    required this.save,
    required this.audio,
    required this.settings,
    this.onSaveChanged,
  });

  final CartridgeManifest manifest;

  /// The cartridge's own persistent save (stats + free-form [CartridgeSave.data]).
  final CartridgeSave save;
  final AsobiAudio audio;
  final AsobiSettings settings;

  /// Called by cartridges after mutating [save.data] mid-run (e.g. idle
  /// progress, unlocked levels). The host persists it.
  final VoidCallback? onSaveChanged;

  void commitSave() => onSaveChanged?.call();
}

/// Lifecycle states of a [CartridgeSession].
///
/// ```
/// created --start--> running <--pause/resume--> paused
///    running/paused --end(result)--> ended --restart--> running
///    any --dispose--> disposed
/// ```
enum SessionState { created, running, paused, ended, disposed }

/// One live instance of a cartridge. Exactly one session is active at a time;
/// the host disposes it before another can be created.
abstract class CartridgeSession extends ChangeNotifier {
  CartridgeSession(this.context);

  final CartridgeContext context;

  SessionState _state = SessionState.created;
  SessionState get state => _state;

  RunResult? _result;

  /// Result of the last finished run (non-null while [state] is ended).
  RunResult? get result => _result;

  int _runs = 0;

  /// Number of runs started in this session (1 after [start]).
  int get runs => _runs;

  bool get isRunning => _state == SessionState.running;

  void _expect(Set<SessionState> allowed, String action) {
    if (!allowed.contains(_state)) {
      throw StateError('Cannot $action a session in state ${_state.name}');
    }
  }

  void start() {
    _expect({SessionState.created}, 'start');
    _runs = 1;
    onStart();
    _state = SessionState.running;
    notifyListeners();
  }

  void pause() {
    if (_state != SessionState.running) return;
    onPause();
    _state = SessionState.paused;
    notifyListeners();
  }

  void resume() {
    if (_state != SessionState.paused) return;
    onResume();
    _state = SessionState.running;
    notifyListeners();
  }

  /// Begins a fresh run (from running, paused or ended).
  void restart() {
    _expect({SessionState.running, SessionState.paused, SessionState.ended}, 'restart');
    _result = null;
    _runs++;
    onRestart();
    _state = SessionState.running;
    notifyListeners();
  }

  /// Called by the game when a run finishes. Idempotent per run.
  void end(RunResult result) {
    if (_state != SessionState.running && _state != SessionState.paused) return;
    _result = result;
    onEnd(result);
    _state = SessionState.ended;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_state == SessionState.disposed) return;
    onDispose();
    _state = SessionState.disposed;
    super.dispose();
  }

  /// Builds the game's view. Called by the host while the session is alive.
  Widget buildView(BuildContext context);

  /// Live entity count for the performance overlay (0 if not tracked).
  int get entityCount => 0;

  // Template hooks for adapters / cartridges.
  @protected
  void onStart() {}
  @protected
  void onPause() {}
  @protected
  void onResume() {}
  @protected
  void onRestart() {}
  @protected
  void onEnd(RunResult result) {}
  @protected
  void onDispose() {}
}

/// A bundled game. Cartridges are compiled into the app; the registry only
/// holds factories, so no game state exists until [createSession] is called.
abstract class Cartridge {
  const Cartridge();

  CartridgeManifest get manifest;

  CartridgeSession createSession(CartridgeContext context);
}
