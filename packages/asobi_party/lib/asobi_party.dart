/// Multiplayer layer for the Yantrasobi console.
///
/// * [MultiplayerSpec] — what a cartridge supports (players, sync model, same-device/online).
/// * [eligibleGames] — shrinks the library to what the current party can play.
/// * [PartyController] — lobby, host, game pick, ready-up, shared seed, results.
/// * [ParallelRace], [TurnSync], [Lockstep] — in-match sync helpers.
/// * [RoomLink] / [LoopbackRelay] — transport seam; see `io.dart` for the WebSocket relay.
library;

export 'src/party.dart';
export 'src/room.dart';
export 'src/spec.dart';
export 'src/sync.dart';
