import '../yantrasobi/cartridge/cartridge.dart';
import '../yantrasobi/cartridge/registry.dart';
import 'arrow_survivor/arrow_survivor.dart';
import 'ball_pour/ball_pour.dart';
import 'blade_toss/blade_toss.dart';
import 'brickfall/brickfall.dart';
import 'crowd_forge/crowd_forge.dart';
import 'deep_dig/deep_dig.dart';
import 'dodge_lane/dodge_lane.dart';
import 'gridlock/gridlock.dart';
import 'gulp_hole/gulp_hole.dart';
import 'ink_claim/ink_claim.dart';
import 'jam_tray/jam_tray.dart';
import 'merge_bastion/merge_bastion.dart';
import 'mob_magnet/mob_magnet.dart';
import 'pocket_quest/pocket_quest.dart';
import 'roll_ridge/roll_ridge.dart';
import 'serpent_loop/serpent_loop.dart';
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
  MobMagnetCartridge(),
  RollRidgeCartridge(),
  GulpHoleCartridge(),
  JamTrayCartridge(),
  StackRunnerCartridge(),
  TubeSortCartridge(),
  GridlockCartridge(),
  MergeBastionCartridge(),
  DodgeLaneCartridge(),
  DeepDigCartridge(),
  BallPourCartridge(),
  PocketQuestCartridge(),
  BladeTossCartridge(),
  SerpentLoopCartridge(),
  BrickfallCartridge(),
];

CartridgeRegistry buildRegistry() => CartridgeRegistry(bundledCartridges());
