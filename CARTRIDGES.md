# Cartridges

Status key:
* **COMPLETE**: passes the gate. That means a library entry, launch, touch controls, a clear goal,
  score or win/lose, replay, cleanup, a manifest, rules tests, and green format/analyze/test.
* **PARTIAL**: playable, with the gaps listed.
* **BLOCKED**: cannot ship; the blocker is listed.

Every registered cartridge also runs through `test/yantrasobi/console_flow_test.dart`: library tile,
detail, launch, pause, resume, Android back (pauses), restart, a drag across the surface, and exit.
3D cartridges run their canvas fallback in tests because the test VM has no GPU.

| # | Cartridge (id) | Engine | Mechanic family | Status | Rules tests | Web capture |
|---|---|---|---|---|---|---|
| 1 | Crowd Forge (`crowd-forge`) | flutter_scene 3D | crowd launcher, multiplier gates | COMPLETE | 14 | `docs/screenshots/crowd_forge_3d_web.png` |
| 2 | Arrow Survivor (`arrow-survivor`) | Flame 2D | auto-attack survivor, upgrade cards | COMPLETE | 9 | `arrow_survivor_web.png` |
| 3 | Ink Claim (`ink-claim`) | Flame 2D | territory capture (trail + flood fill) | COMPLETE | 9 | `ink_claim_web.png` |
| 4 | Spiral Drop (`spiral-drop`) | flutter_scene 3D | helix tower descent | COMPLETE | 9 | `spiral_drop_3d_web.png` |
| 5 | Gulp Hole (`gulp-hole`) | Flame 2D | growing hole swallows the city | COMPLETE | 16 | `gulp_hole_web.png` |
| 6 | Jam Tray (`jam-tray`) | Flame 2D | layered tiles into a 7-slot tray | COMPLETE | 15 | `jam_tray_web.png` |
| 7 | Stack Runner (`stack-runner`) | Flame 2D (pseudo-3D) | block-stack runner, finish multipliers | COMPLETE | 14 | `stack_runner_web.png` |
| 8 | Tube Sort (`tube-sort`) | Flame 2D | colour sorting (solver-checked) | COMPLETE | 9 | `tube_sort_web.png` |
| 9 | Gridlock (`gridlock`) | Flame 2D | traffic-escape puzzle | COMPLETE | 14 | – |
| 10 | Merge Bastion (`merge-bastion`) | Flame 2D | merge defence | COMPLETE | 13 | `merge_bastion_web.png` |
| 11 | Mob Magnet (`mob-magnet`) | flutter_scene 3D | crowd collecting in a city | COMPLETE | 11 | `mob_magnet_3d_web.png` |
| 12 | Dodge Lane (`dodge-lane`) | Flame 2D (pseudo-3D) | endless lane dodger | COMPLETE | 15 | `dodge_lane_web.png` |
| 13 | Deep Dig (`deep-dig`) | Flame 2D | idle mining manager (offline earnings) | COMPLETE | 15 | `deep_dig_web.png` |
| 14 | Ball Pour (`ball-pour`) | Flame 2D + custom circle physics | cup/ball physics | COMPLETE | 16 | `ball_pour_web.png` |
| 15 | Pocket Quest (`pocket-quest`) | Flutter widgets | text roguelike auto-adventure | COMPLETE | 14 | `pocket_quest_web.png` |
| 16 | Roll Ridge (`roll-ridge`) | flutter_scene 3D | rolling ball obstacle course | COMPLETE | 10 | `roll_ridge_3d_web.png` |
| 17 | Blade Toss (`blade-toss`) | Flame 2D | blades into a rotating target | COMPLETE | 15 | `blade_toss_web.png` |
| 18 | Serpent Loop (`serpent-loop`) | Flame 2D | snake (classic + wrap modes) | COMPLETE | 15 | `serpent_loop_web.png` |
| 19 | Brickfall (`brickfall`) | Flame 2D | paddle-and-ball brick breaker | COMPLETE | 19 | `brickfall_web.png` |

Not verified anywhere: real Android devices (none available). APKs are built only in CI, and that is
unverified while pushes to GitHub fail (see CURRENT_STATUS.md).

## Notes per cartridge

### Crowd Forge (3D reference)
* **Goal:** knock the enemy forge's HP to 0 before 20 red runners breach your base.
* **Controls:** hold to fire; slide to aim.
* **Systems:**
  * ×2/×3/×4 multiplier gates (some sway).
  * Blades from level 2.
  * Champion every 45 shots.
  * Fixed 360/160 unit pools mapped 1:1 onto two `InstancedMesh` draws.
  * Level saved on win.
* **Balance:** a sweeping bot clears level 1 in about 21 s. Idling loses.

### Arrow Survivor (2D reference)
* **Goal:** survive 10 waves; bosses on waves 5 and 10.
* **Controls:** floating joystick; pick an upgrade card between waves.
* **Systems:** arrow pool, 5 enemy archetypes, 8 upgrades, heart drops. The arena sits below the HUD.

### Ink Claim
* **Goal:** paint 50% of the board.
* **Controls:** swipe to turn.
* **Systems:** trail cutting, enclosed-area fill, 3 bot painters, walls deflect.

### Spiral Drop (3D)
* **Goal:** reach the finish platform.
* **Controls:** drag to rotate the tower.
* **Systems:**
  * Ring sectors built with `GeometryBuilder` in one instanced draw.
  * Hazards from ring 4.
  * Blaze (3 drops without a bounce) smashes the next ring.
  * Levels saved.

### Gulp Hole
* **Goal:** be the biggest hole when the 90 s timer ends, or eat 60% of the city.
* **Controls:** floating joystick.
* **Systems:**
  * 3 rival holes.
  * 20 s start grace.
  * Rivals hunt only when 35% bigger, with limited hunt time.
* **Balance:** checked with a scripted bot only.

### Jam Tray
* **Goal:** clear the board without filling the 7-slot tray.
* **Systems:** 3 undos and 2 shuffles per run. Boards are generated in reverse, so they are always solvable.
* **Difficulty:** level 1 has only 3 kinds and cannot be lost (deliberate onboarding).

### Stack Runner
* **Goal:** reach the finish stairs; score is gems × the step reached.
* **Systems:** walls strip blocks; gaps take a block per plank; x1–x10 stairs.
* **Not done:** the optional colour gates.

### Tube Sort
* **Goal:** one colour per tube.
* **Systems:**
  * Every deal is checked by a DFS solver.
  * 5 undos and 1 extra tube per run.
  * Glyphs on the balls help colour-blind players.

### Gridlock
* **Goal:** drive every vehicle off the lot; 3 bumps lose.
* **Systems:**
  * Lots are generated by reverse construction, so they are always solvable.
  * 2 hints per run.
  * Lots grow from 6x8 to 9x12.

### Merge Bastion
* **Goal:** survive 15 waves.
* **Systems:**
  * Summon for 10 coins plus 2 per purchase.
  * Merge twins up to tier 8.
  * Boss every 5th wave.
* **Balance:** a bot that summons and merges wins level 1 on 20 of 20 seeds. Idling loses by wave 3.

### Mob Magnet (3D)
* **Goal:** have the largest mob after 75 s, or absorb every rival leader.
* **Controls:** joystick.
* **Systems:**
  * Up to 420 people drawn as one per-instance-coloured `InstancedMesh`.
  * Spatial hash for contacts.
  * 3 bot mobs that flee bigger mobs and chase smaller ones.
  * The camera pulls back as the mob grows.

### Dodge Lane
* **Goal:** an endless run for score (distance, coins, near misses). One unshielded hit ends it.
* **Controls:** swipe sideways, up to jump, down to duck.
* **Systems:** every generated row passes a reachability validator. Pickups are shield, magnet, and slow-mo.

### Deep Dig
* **Goal:** hit the contract cash milestone ($1M, then $10M, and so on). There is no losing; exit anytime.
* **Systems:**
  * Shafts, a lift, and a hauler, each tapped manually or automated with a foreman.
  * Upgrade costs grow ×1.15 per level.
  * Offline earnings, capped at 2 h, are saved in the cartridge save.

### Ball Pour
* **Goal:** settle the target number of balls in the cup.
* **Controls:** hold to open the gate; drag planks along their rails.
* **Systems:**
  * Custom deterministic circle-and-segment physics with a fixed step and a speed cap (no tunnelling).
  * 10 authored levels as declarative data, then a looping harder variant.

### Pocket Quest
* **Goal:** survive 30 days and beat the day-30 boss.
* **Controls:** NEXT DAY, pick 1 of 3 at shrines, shop, CAMP.
* **Systems:**
  * Fights run round by round and stop while paused.
  * 14 skills with 4 synergies.
  * Each chapter cleared is saved and makes the next one harder.
* Built on the widget adapter (no Flame).

### Roll Ridge (3D)
* **Goal:** reach the finish with lives left (3 lives, checkpoints).
* **Controls:** drag sideways to steer.
* **Systems:**
  * Ramps launch the ball over gaps.
  * Hazards are sweepers, pushers and bumpers.
  * Track tiles are yawed along the curve in one instanced draw.
  * Gradient sky.

### Blade Toss
* **Goal:** an endless stage climb; one clash ends the run.
* **Controls:** tap to throw.
* **Systems:**
  * Spin scripts: constant, swell, reverse and stop-and-go.
  * Pre-placed obstacle blades.
  * Gems on the rim.
  * A boss every 5 stages.
  * Generation keeps a safe window open.

### Serpent Loop
* **Modes:** Classic, with level goals, walls and rock layouts from level 3; Wrap, an endless score attack.
* **Controls:** swipe, with a 2-turn queue.
* **Pickups:** apples, golden fruit, shrink berries, phase orbs.

### Brickfall
* **Goal:** clear every breakable brick; 3 lives.
* **Bricks:** 10 authored layouts, then generated ones. Brick types are tough, steel and explosive.
* **Capsules:** wide paddle, multi-ball, slow ball, laser, extra life.
* **Physics:** substepped, so the ball cannot tunnel.
