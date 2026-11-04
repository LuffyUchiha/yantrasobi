import '../yantrasobi/cartridge/cartridge.dart';
import '../yantrasobi/cartridge/registry.dart';
import 'arrow_survivor/arrow_survivor.dart';
import 'crowd_forge/crowd_forge.dart';
import 'ink_claim/ink_claim.dart';
import 'jam_tray/jam_tray.dart';
import 'spiral_drop/spiral_drop.dart';

/// Every cartridge compiled into this build of Yantrasobi.
///
/// Adding a cartridge = implementing [Cartridge] and listing it here.
List<Cartridge> bundledCartridges() => const [
  CrowdForgeCartridge(),
  ArrowSurvivorCartridge(),
  InkClaimCartridge(),
  SpiralDropCartridge(),
  JamTrayCartridge(),
];

CartridgeRegistry buildRegistry() => CartridgeRegistry(bundledCartridges());
