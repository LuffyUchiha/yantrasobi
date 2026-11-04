# Cartridges

Status key: **COMPLETE** = passes the gate (library entry, launch, touch, goal, score/win-lose,
replay, cleanup, manifest, rules tests, format/analyze/test green). **PARTIAL** = playable but
gaps listed. **BLOCKED** = cannot ship; blocker listed.

| # | Cartridge | Engine | Mechanic family | Status | Rules tests |
|---|-----------|--------|-----------------|--------|-------------|
| 1 | Arrow Survivor (`arrow-survivor`) | Flame 2D | auto-attack arena survivor, waves, upgrade cards | COMPLETE | `test/cartridges/arrow_survivor_test.dart` (9) |

## Details

### Arrow Survivor
* **Goal:** survive 10 waves (bosses on 5 and 10). Lose when HP reaches 0.
* **Controls:** drag anywhere to move with a floating joystick; tap a card to pick an upgrade.
* **Systems:** auto-fire at the nearest enemy, a pooled arrow pool, 5 enemy archetypes, pick one
  of three upgrades between waves (multishot, rate, pierce, damage, speed, vitality, orbit
  blades, heal), heart drops.
* **Score:** points per kill by type, plus 100 × wave for each wave cleared.
