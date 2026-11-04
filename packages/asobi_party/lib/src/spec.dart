/// How the players' copies of a game stay in agreement during a match.
enum SyncModel {
  /// Every player runs their own copy of the game from the **same seed** and
  /// only telemetry crosses the wire (score, progress, ghost position, and
  /// optional "attack" events such as garbage rows). Very tolerant of lag and
  /// works for any deterministic single-player cartridge, so it is the cheapest
  /// way to make an existing cartridge multiplayer.
  parallel,

  /// Players take turns; each move is broadcast and applied by every copy in
  /// the same order (pool, carrom, board and card games, artillery duels).
  turnBased,

  /// Real-time shared world. Every copy runs the same deterministic simulation
  /// and advances one tick only once it holds every player's input for that
  /// tick (snake arena, territory capture, head football, air hockey).
  lockstep,
}

/// Whether players compete or work together.
enum PlayMode { versus, coop }

/// How the players are connected.
enum Connection {
  /// One phone, several people (shared screen or pass-and-play).
  sameDevice,

  /// Separate phones talking through the party relay.
  online,
}

/// Multiplayer capability a cartridge declares next to its manifest.
///
/// A cartridge without a spec is single-player only and is hidden from the
/// library while a party is active.
class MultiplayerSpec {
  const MultiplayerSpec({
    required this.sync,
    this.minPlayers = 2,
    this.maxPlayers = 2,
    this.modes = const {PlayMode.versus},
    this.online = true,
    this.sameDevice = false,
    this.tickRate = 0,
    this.inputDelayTicks = 0,
    this.summary = '',
  });

  final SyncModel sync;
  final int minPlayers;
  final int maxPlayers;
  final Set<PlayMode> modes;

  /// Playable across phones through the relay.
  final bool online;

  /// Playable by several people sharing one phone.
  final bool sameDevice;

  /// Lockstep only: simulation ticks per second.
  final int tickRate;

  /// Lockstep only: how many ticks local input is delayed so remote input can
  /// arrive in time. Higher hides more latency but feels less snappy.
  final int inputDelayTicks;

  /// One line for the lobby, e.g. "Same seed, highest score wins".
  final String summary;

  static const int maxPartySize = 8;

  bool supports(PartyShape shape) {
    if (shape.players < minPlayers || shape.players > maxPlayers) return false;
    return switch (shape.connection) {
      Connection.sameDevice => sameDevice,
      Connection.online => online,
    };
  }

  /// Human-readable validation problems (empty if valid).
  List<String> validate() {
    final problems = <String>[];
    if (minPlayers < 2) problems.add('minPlayers must be at least 2');
    if (maxPlayers < minPlayers) problems.add('maxPlayers < minPlayers');
    if (maxPlayers > maxPartySize) problems.add('maxPlayers > $maxPartySize');
    if (modes.isEmpty) problems.add('no play modes');
    if (!online && !sameDevice) problems.add('neither online nor sameDevice');
    if (sync == SyncModel.lockstep) {
      if (tickRate <= 0) problems.add('lockstep needs a tickRate');
      if (inputDelayTicks < 1) problems.add('lockstep needs inputDelayTicks >= 1');
    }
    return problems;
  }

  Map<String, Object?> toJson() => {
    'sync': sync.name,
    'minPlayers': minPlayers,
    'maxPlayers': maxPlayers,
    'modes': [for (final m in modes) m.name],
    'online': online,
    'sameDevice': sameDevice,
    'tickRate': tickRate,
    'inputDelayTicks': inputDelayTicks,
    'summary': summary,
  };
}

/// The party a game must fit: how many people and how they are connected.
class PartyShape {
  const PartyShape(this.players, this.connection);

  final int players;
  final Connection connection;

  @override
  bool operator ==(Object other) =>
      other is PartyShape && other.players == players && other.connection == connection;

  @override
  int get hashCode => Object.hash(players, connection);

  @override
  String toString() => 'PartyShape($players, ${connection.name})';
}

/// A cartridge as the party layer sees it: id, version and capability.
///
/// The Flutter console builds these from its catalog; the party layer never
/// needs the cartridge's code.
class GameEntry {
  const GameEntry(this.id, this.version, this.spec);

  final String id;
  final String version;
  final MultiplayerSpec? spec;

  bool get isMultiplayer => spec != null;
}

/// What one party member reports having installed (id → version).
typedef InstalledGames = Map<String, String>;

/// Shrinks [catalog] to the games this party can play together.
///
/// A game qualifies when it declares a [MultiplayerSpec] that supports
/// [shape], and — for online parties — every member has the **same version**
/// of it installed ([members]). Cartridges are compiled into the app, so two
/// phones on different app versions may disagree; a mismatched version would
/// desync a shared simulation, so it is filtered out rather than risked.
List<GameEntry> eligibleGames(
  Iterable<GameEntry> catalog,
  PartyShape shape, {
  Iterable<InstalledGames> members = const [],
}) {
  return [
    for (final g in catalog)
      if (g.spec != null && g.spec!.supports(shape) && members.every((m) => m[g.id] == g.version)) g,
  ];
}
