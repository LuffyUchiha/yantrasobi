import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/ink_claim/claim_world.dart';
import 'package:yantrasobi/cartridges/ink_claim/ink_claim.dart';

void main() {
  ClaimWorld solo({double winShare = 0.5}) {
    final w = ClaimWorld(seed: 4, winShare: winShare)..debugFreezeBots();
    return w;
  }

  void walk(ClaimWorld w, Dir d, int n) {
    w.player.queued = d;
    for (var i = 0; i < n; i++) {
      w.debugStep(w.player);
    }
  }

  test('manifest is valid', () => expect(InkClaimCartridge.kManifest.validate(), isEmpty));

  test('player starts with a 3×3 home and no trail', () {
    final w = solo();
    expect(w.cellsOwnedBy(1), 9);
    expect(w.player.trail, isEmpty);
  });

  test('leaving home lays a trail; returning claims trail and enclosed area', () {
    final w = solo();
    final p = w.player;
    w.debugPlace(p, 18, 37, Dir.up); // centre of home (cols/2, rows*0.62)
    final before = w.cellsOwnedBy(1);
    walk(w, Dir.up, 5); // leaves home after 1 step
    expect(p.trail, isNotEmpty);
    walk(w, Dir.right, 4);
    walk(w, Dir.down, 5); // re-enters home at row 36? keep going until captured
    walk(w, Dir.left, 3);
    expect(p.trail, isEmpty);
    expect(w.cellsOwnedBy(1), greaterThan(before + 15));
    expect(w.captures, greaterThanOrEqualTo(1));
  });

  test('crossing your own trail ends the run', () {
    final w = solo();
    final p = w.player;
    w.debugPlace(p, 18, 37, Dir.up);
    walk(w, Dir.up, 6);
    walk(w, Dir.right, 2);
    walk(w, Dir.down, 2);
    walk(w, Dir.left, 3); // crosses the upward trail
    expect(w.phase, ClaimPhase.lost);
  });

  test('steering cannot reverse directly', () {
    final w = solo();
    w.player.dir = Dir.up;
    w.steer(Dir.down);
    expect(w.player.queued, isNull);
    w.steer(Dir.left);
    expect(w.player.queued, Dir.left);
  });

  test('cutting a rival trail eliminates the rival and credits a kill', () {
    final w = ClaimWorld(seed: 9);
    final bot = w.painters[1];
    // Give the bot a trail cell right in front of the player.
    final p = w.player;
    w.debugPlace(p, 10, 10, Dir.right);
    final c = w.idx(11, 10);
    w.trailOwner[c] = bot.id;
    bot.trail
      ..clear()
      ..add(c);
    w.debugStep(p);
    expect(bot.alive, isFalse);
    expect(p.kills, 1);
    expect(w.cellsOwnedBy(bot.id), 0);
  });

  test('walls deflect instead of killing', () {
    final w = solo();
    final p = w.player;
    w.debugPlace(p, 0, 5, Dir.left);
    w.debugStep(p);
    expect(p.alive, isTrue);
    expect(p.x, 0);
  });

  test('reaching the goal share wins', () {
    final w = solo(winShare: 0.02);
    final p = w.player;
    w.debugPlace(p, 18, 37, Dir.up);
    walk(w, Dir.up, 6);
    walk(w, Dir.right, 6);
    walk(w, Dir.down, 7);
    walk(w, Dir.left, 5); // back into home at x = 19
    expect(w.phase, ClaimPhase.won);
    expect(w.score, greaterThan(0));
  });

  test('bots move, claim land, and the sim is deterministic per seed', () {
    ClaimWorld run() {
      final w = ClaimWorld(seed: 21);
      w.player.alive = true;
      for (var i = 0; i < 600; i++) {
        // Keep the player safely circling inside its home.
        w.update(1 / 60);
        if (w.isOver) break;
      }
      return w;
    }

    final a = run(), b = run();
    expect(a.owner, b.owner);
    final botLand = a.painters.skip(1).fold<int>(0, (s, p) => s + a.cellsOwnedBy(p.id));
    expect(botLand, greaterThan(27));
  });
}
