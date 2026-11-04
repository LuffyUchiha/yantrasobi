import '../yantrasobi/cartridge/cartridge.dart';
import '../yantrasobi/cartridge/registry.dart';
import 'arrow_survivor/arrow_survivor.dart';
import 'crowd_forge/crowd_forge.dart';
import 'gridlock/gridlock.dart';
import 'gulp_hole/gulp_hole.dart';
import 'ink_claim/ink_claim.dart';
import 'jam_tray/jam_tray.dart';
import 'merge_bastion/merge_bastion.dart';
import 'spiral_drop/spiral_drop.dart';
import 'stack_runner/stack_runner.dart';
import 'tube_sort/tube_sort.dart';

/// Every cartridge compiled into this build of Yantrasobi.
///
/// Adding a cartridge = implementing [Cartridge] and listing it here.
List<Cartridge> bundledCartridges() => const [
  CrowdForgeCartridge(),
  ArrowSurvivorCartridge(),
  InkClaimCartridge(),
  SpiralDropCartridge(),
  GulpHoleCartridge(),
  JamTrayCartridge(),
  StackRunnerCartridge(),
  TubeSortCartridge(),
  GridlockCartridge(),
  MergeBastionCartridge(),
];

CartridgeRegistry buildRegistry() => CartridgeRegistry(bundledCartridges());
