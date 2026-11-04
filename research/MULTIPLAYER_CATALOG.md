# Multiplayer catalog: what the party library shows

When a player starts a party, the library shrinks to the games that **every member can play
together**. This file decides which games appear in that shorter list. It has two parts:

1. **Existing and planned cartridges.** Which ones gain multiplayer, and how.
2. **New multiplayer-first cartridges.** These are modelled on mechanic families that are proven hits on
   the Play Store, so a party of friends has a solid list to pick from.

Same rules as `research/CATALOG.md`. A reference title is only a **mechanic family**. Each cartridge gets
its own name, rules tuning and procedural art. We copy no names, characters, art, sound or levels.
Publishers and install tiers come from general knowledge and were **not verified** against the store.
Store pages are blocked in this sandbox. Treat the tiers as rough orders of magnitude.

Sync models (see `packages/asobi_party`):

| Model | What crosses the network | Lag tolerance | Typical use |
|---|---|---|---|
| **parallel** | Same seed for everyone. Only score, progress and optional "attacks" are sent | Very high | Score duels, races, puzzle races |
| **turnBased** | One move at a time, applied in the same order on every phone | Very high | Pool, carrom, board games, card games, artillery |
| **lockstep** | Every player's input for every tick. The game waits for missing input | Needs < ~120 ms | Real-time shared arena |

Connection: **Online** means separate phones through the party relay. **Same device** means one phone
shared by several people, either on a split screen or passing it between turns.

Priority: **P1** means cheap to add and high fun with friends. **P2** means worth doing. **P3** means
heavy work or a weak fit.

---

## 1. Existing and planned cartridges

Genres marked † are inferred from the cartridge name and id. That cartridge's code isn't on this branch
yet, so check † rows against the cartridge before building them.

### 1a. Already in the console (or being built now)

| Cartridge | Genre | Multiplayer form | Sync | Players | Online / Same device | Priority |
|---|---|---|---|---|---|---|
| Ink Claim (`ink-claim`) | territory capture† | **Arena:** everyone draws on one map. Cutting a rival's trail eliminates them | lockstep | 2–4 | ✔ / – | P1 |
| Gulp Hole (`gulp-hole`) | grow-by-swallowing† | **Arena:** a bigger hole can swallow a smaller one. Biggest after 2 min wins | lockstep | 2–4 | ✔ / – | P1 |
| Serpent Loop (`serpent-loop`) | snake | **Arena mode:** several snakes on one grid. A head-on hit kills both | lockstep (grid tick, 8–12 Hz) | 2–4 | ✔ / ✔ (2-player split controls) | P1 |
| Cloud Tower (`cloud-tower`) | timing stacker | Same tower seed, live height race | parallel | 2–8 | ✔ / ✔ (alternate turns) | P1 |
| Blade Toss (`blade-toss`) | rotating-target throw | Same stage script. Furthest stage wins | parallel | 2–8 | ✔ / ✔ | P1 |
| Brickfall (`brickfall`) | brick breaker | Same level. Clearing 3 bricks in a row drops a steel row on the opponent | parallel + attacks | 2–4 | ✔ / – | P1 |
| Spiral Drop (`spiral-drop`) | helix drop† | Same tower. First to the bottom wins | parallel | 2–8 | ✔ / – | P1 |
| Dodge Lane (`dodge-lane`) | endless lane dodger | Same obstacle stream, opponent shown as a ghost. Last one alive wins | parallel (ghost) | 2–8 | ✔ / – | P1 |
| Stack Runner (`stack-runner`) | collect-and-run† | Same track, race to the finish line | parallel (ghost) | 2–8 | ✔ / – | P2 |
| Crowd Forge (`crowd-forge`) | crowd runner† | Same gates. Biggest crowd at the end wins | parallel | 2–8 | ✔ / – | P2 |
| Mob Magnet (`mob-magnet`) | crowd gathering† | Same map, highest score after 90 s | parallel | 2–8 | ✔ / – | P2 |
| Arrow Survivor (`arrow-survivor`) | survivor action | Same wave seed, survive longest. Co-op arena is P3 | parallel | 2–4 | ✔ / – | P2 |
| Merge Bastion (`merge-bastion`) | merge defence† | **Versus:** each enemy you kill adds pressure to the rival's next wave. This is the Rush Royale family, a proven PvP hit | parallel + attacks | 2 | ✔ / – | P1 |
| Jam Tray (`jam-tray`) | tile-match puzzle | Puzzle race on the same board. First to clear wins, and a 3-combo locks a tile for the rival | parallel + attacks | 2–4 | ✔ / – | P2 |
| Tube Sort (`tube-sort`) | sort puzzle† | Puzzle race on the same level, fewest moves breaks ties | parallel | 2–8 | ✔ / – | P2 |
| Gridlock (`gridlock`) | sliding-block puzzle† | Puzzle race on the same level | parallel | 2–8 | ✔ / – | P2 |
| Ball Pour (`ball-pour`) | cup/ball physics | Puzzle race on the same level | parallel | 2–8 | ✔ / – | P3 |
| Roll Ridge (`roll-ridge`) | 3D ball track | Ghost race on the same track | parallel (ghost) | 2–8 | ✔ / – | P2 |
| Deep Dig (`deep-dig`) | idle manager | Idle play with offline earnings has no live session to share | — | — | single-player only | — |
| Pocket Quest (`pocket-quest`) | text roguelike | Pass-and-play "same seed, who survives longer" is possible but weak | — | — | single-player only | — |

### 1b. User-requested backlog (`research/CATALOG.md`)

| Working title | Reference family | Multiplayer form | Sync | Players | Online / Same device | Priority |
|---|---|---|---|---|---|---|
| **Cue Clash** | 8-ball billiards (8 Ball Pool, Miniclip, 500M+ tier) | The 1v1 table is the whole point of this family | turnBased | 2 | ✔ / ✔ | **P1: build multiplayer-first** |
| **Bonk Ball** | 1v1 head football (Head Ball 2, Masomo, 100M+ tier) | Real-time 1v1. Same device: left and right halves of the screen | lockstep | 2 | ✔ / ✔ | **P1** |
| **Flipper Rush** | pinball | Classic alternating balls, highest total wins | turnBased | 2–4 | ✔ / ✔ (pass-and-play) | P1 |
| **Plank Dash** | plank race (Bridge Race) | Race friends instead of bots. Ghosts first, shared planks later | parallel → lockstep | 2–4 | ✔ / – | P2 |
| **Key Cascade** | rhythm tiles (Magic Tiles) | Same song, accuracy battle. Same device: one column set each | parallel | 2–4 | ✔ / ✔ | P1 |
| **Slope Buggy** | hill climb (Hill Climb Racing 2 is built on ghost races, 100M+ tier) | Ghost race on the same terrain seed | parallel (ghost) | 2–6 | ✔ / – | P1 |
| **Digit Barrage** | numbered-block shooter | Score duel. Splitting a big block sends small ones to the rival | parallel + attacks | 2 | ✔ / – | P2 |
| **Garden Guard** | lane defence | Versus: spend resources to send attackers into the rival's lanes | parallel + attacks | 2 | ✔ / – | P2 |
| Thrust Corridor, Swing Hook, Edge Dash, Dune Glide, Ruin Sprint, Shatter Run, Marble Maze, Deep Bite | endless / track | Same seed, ghost or score race | parallel | 2–8 | ✔ / – | P2 (one spec line each) |
| Snip Drop, Dig Flow, Doodle Link | physics puzzle | Puzzle race on the same level | parallel | 2–4 | ✔ / – | P3 |
| Rocket Rascal, Junk Rover | physics sandbox | Weak fit | — | — | single-player only | — |

**Takeaway.** The **parallel** model means most existing cartridges join the party list cheaply. A cartridge
declares a spec, uses `match.seed` and exposes its live score. That alone gives a 2-player online party
**~20 games** before any new title is built. The thin spots are **same-device play** and **real
interaction between players**. Section 2 fills those.

---

## 2. New multiplayer-first cartridges

Picked because their family is a long-running Play Store success *built on playing against people*.
Each one also fits a one-thumb, procedural-art cartridge.

| # | Working title | Reference family (publisher, install tier, unverified) | Why it works with friends | Sync | Players | Online / Same device | Priority |
|---|---|---|---|---|---|---|---|
| 1 | **Chaupar Run** | race board game: Ludo King (Gametion, 500M+ to 1B tier). Ludo/Pachisi rules are traditional and public domain | Living-room classic in India. Pass-and-play plus online, and quick rematches | turnBased | 2–4 | ✔ / ✔ | **P1** |
| 2 | **Striker Ring** | carrom: Carrom Pool (Miniclip, 100M+ tier). Carrom is a traditional game | Turn-based flick physics. Reuses Cue Clash's circle physics | turnBased | 2 (4 as teams) | ✔ / ✔ | **P1** |
| 3 | **Thumb Fiesta** | same-device party packs: "2 Player Games" and "Stickman Party 1-4 Player" style apps (100M+ tier as a category) | Gives one phone and two to four friends something to play right away. Six micro-games: tap race, reaction draw, tug-of-war, sumo push, paddle rally, colour memory | local | 2–4 | – / ✔ | **P1** |
| 4 | **Puck Rush** | air hockey (Glow Hockey and similar, 50M–100M+ tier) | The best-known shared-screen 1v1. Online version comes later | local → lockstep | 2 | ✔ (later) / ✔ | **P1** |
| 5 | **Lob Duel** | turn-based artillery: Bowmasters / Tank Stars (Playgendary, 100M+ tier each) | Aim, power, wind, destructible ground. Turns hide latency completely | turnBased | 2–4 | ✔ / ✔ | **P1** |
| 6 | **Stack Siege** | falling-block versus (classic block-puzzle battles, Puyo-style garbage) | Clearing lines sends junk rows to the rival. Uses an original piece set, *not* tetrominoes, to stay clear of that trade dress | parallel + attacks | 2–4 | ✔ / – | P1 |
| 7 | **Quick Wit** | 2-player math/logic duel apps and trivia duels (Trivia Crack, Etermax, 100M+ tier) | Procedural maths and logic questions, so there's no licensed question bank. Split-screen buzzers on one phone | parallel | 2–4 | ✔ / ✔ | P1 |
| 8 | **Gravity Four** + **Box Claim** | four-in-a-row and dots-and-boxes (many 10M+ tier apps) | Tiny, timeless, perfect for testing the turn-based path. Rules are already in `packages/asobi_party/example/` | turnBased | 2 | ✔ / ✔ | P1 (cheap) |
| 9 | **Eights Up** | shedding card game: UNO! (Mattel163, 100M+ tier). Uses Crazy Eights rules, which are public domain | Huge with families. Hands are hidden, so the host deals. Fine for friends, not for ranked play | turnBased (host deals) | 2–6 | ✔ / ✔ (pass-and-play hides hands) | P2 |
| 10 | **Fleet Hunt** | hidden-fleet battle: Sea Battle 2 (Byril, 50M+ tier) | Each fleet layout is hashed at the start and revealed at the end, so nobody can move ships mid-game | turnBased | 2 | ✔ / ✔ (pass-and-play) | P2 |
| 11 | **Putt Party** | mini-golf race: Golf Battle (Miniclip, 10M+ tier), Mini Golf King | Everyone plays the same hole at once and sees the others' balls as ghosts | parallel (ghost) | 2–6 | ✔ / ✔ (turns) | P2 |
| 12 | **Draughts Duel** | checkers / chess apps (Chess.com etc., 100M+ tier) | Draughts is small enough to ship with a decent AI fallback | turnBased | 2 | ✔ / ✔ | P2 |
| 13 | **Sketch Guess** | draw-and-guess (Draw Something / Gartic family) | Great party game. Needs an original word list and stroke streaming | parallel (stroke stream) | 3–8 | ✔ / – | P2 |
| 14 | **Tumble Trials** | obstacle-course party royale: Stumble Guys (Scopely, 100M+ tier) | Proven but heavy. A 2D side-view version is feasible | lockstep | 2–8 | ✔ / – | P3 |
| 15 | **Doodle Skirmish** | 2D LAN shooter: Mini Militia (Appsomniacs, 100M+ tier) | Proven, but it's real-time combat with a weapons economy | lockstep | 2–6 | ✔ / – | P3 |

Deliberately **not** proposed:

* **Rummy, Teen Patti, poker and anything that resembles real-money play.** These bring age-rating and
  gambling-policy risk.
* **Social deduction (Among Us family).** It needs voice or chat and 5+ players.
* **Anything that needs servers to own the game world or run matchmaking with strangers.** The party
  model is friends-only by design.

## 3. Resulting party library (once P1 lands)

| Party shape | Games shown |
|---|---|
| 2 phones online | Every P1 parallel cartridge in §1a, plus Cue Clash, Bonk Ball, Flipper Rush, Key Cascade, Slope Buggy, Chaupar Run, Striker Ring, Lob Duel, Stack Siege, Quick Wit, Gravity Four, Box Claim, and the lockstep arenas (Ink Claim, Gulp Hole, Serpent Loop). **~30** |
| 3–4 phones online | Parallel cartridges, the lockstep arenas, Chaupar Run, Flipper Rush, Lob Duel, Stack Siege, Quick Wit. **~20** |
| 5–8 phones online | Parallel races (Cloud Tower, Blade Toss, Spiral Drop, Dodge Lane…). **~10** |
| 1 phone, 2 people | Thumb Fiesta, Puck Rush, Cue Clash, Striker Ring, Chaupar Run, Lob Duel, Gravity Four, Box Claim, Bonk Ball, Key Cascade, Quick Wit, Serpent Loop (split), Cloud Tower and Blade Toss (alternating turns). **~14** |
| 1 phone, 3–4 people | Thumb Fiesta, Chaupar Run, Flipper Rush, Lob Duel, Quick Wit. **~5** |

Suggested build order for multiplayer: **Gravity Four** (proves the turn-based path end to end),
then parallel specs on the 6 P1 existing cartridges (proves the party library), then **Thumb Fiesta**,
**Chaupar Run**, **Cue Clash**, **Serpent Loop arena** (proves lockstep), **Lob Duel**,
**Striker Ring**, **Puck Rush**, then **Stack Siege**.
