import '../yantrasobi/cartridge/cartridge.dart';
import '../yantrasobi/cartridge/registry.dart';
import 'arrow_survivor/arrow_survivor.dart';
import 'ball_pour/ball_pour.dart';
import 'blade_toss/blade_toss.dart';
import 'brickfall/brickfall.dart';
import 'cloud_tower/cloud_tower.dart';
import 'crowd_forge/crowd_forge.dart';
import 'curve_kick/curve_kick.dart';
import 'deep_dig/deep_dig.dart';
import 'dodge_lane/dodge_lane.dart';
import 'edge_dash/edge_dash.dart';
import 'gridlock/gridlock.dart';
import 'gulp_hole/gulp_hole.dart';
import 'ink_claim/ink_claim.dart';
import 'jam_tray/jam_tray.dart';
import 'merge_bastion/merge_bastion.dart';
import 'mob_magnet/mob_magnet.dart';
import 'pocket_quest/pocket_quest.dart';
import 'puck_duel/puck_duel.dart';
import 'roll_ridge/roll_ridge.dart';
import 'serpent_loop/serpent_loop.dart';
import 'shatter_run/shatter_run.dart';
import 'spiral_drop/spiral_drop.dart';
import 'swing_hook/swing_hook.dart';
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
  ShatterRunCartridge(),
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
  CloudTowerCartridge(),
  CurveKickCartridge(),
  SwingHookCartridge(),
  EdgeDashCartridge(),
  PuckDuelCartridge(),
];

CartridgeRegistry buildRegistry() => CartridgeRegistry(bundledCartridges());
