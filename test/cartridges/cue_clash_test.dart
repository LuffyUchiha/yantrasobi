import 'package:flutter_test/flutter_test.dart';
import 'package:yantrasobi/cartridges/cue_clash/cue_world.dart';

int game(CpuLevel a, CpuLevel b, int seed, {int first = 0}) {
  final w = CueWorld(seed: seed, firstPlayer: first);
  final ais = [AiController(player: 0, level: a, seed: seed), AiController(player: 1, level: b, seed: seed + 1)];
  var shots = 0;
  while (!w.isOver && shots < 200) {
    final m = ais[w.current].think(w)!;
    final ok = w.submitMove(w.current, m);
    if (!ok) { print('rejected $m'); break; }
    w.runUntilRest();
    shots++;
  }
  print('seed $seed shots $shots winner ${w.winner} end ${w.endReason} groups ${w.groups} rem ${w.remainingOf(0)} ${w.remainingOf(1)} tick ${w.tick}');
  return w.winner ?? -1;
}

void main() {
  test('probe', () {
    final w = CueWorld(seed: 3);
    final sw = Stopwatch()..start();
    w.submitMove(0, CueShot(angle: -1.5708, power: 1));
    w.runUntilRest();
    print('break ticks ${w.tick} ms ${sw.elapsedMilliseconds} potted ${w.lastReport!.potted} foul ${w.lastReport!.foul} cur ${w.current} onTable ${w.entityCount}');
    for (final b in w.balls) { if (!b.potted) print('${b.id} ${b.x.toStringAsFixed(2)} ${b.y.toStringAsFixed(2)}'); }
    sw.reset();
    var hw = 0;
    for (var s = 0; s < 4; s++) {
      if (game(CpuLevel.hard, CpuLevel.easy, s, first: s % 2) == 0) hw++;
    }
    print('hard wins $hw ms ${sw.elapsedMilliseconds}');
  });
}
