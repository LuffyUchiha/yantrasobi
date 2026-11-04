import 'dart:collection';
import 'dart:math' as math;

/// Pure-Dart rules for Ink Claim, a grid territory-capture game.
///
/// Every painter owns a territory. Leaving it lays a trail; returning closes
/// the loop and claims the trail plus every cell it encloses. A trail is
/// fragile: anyone who crosses it eliminates its owner, including the owner.

enum Dir { up, right, down, left }

extension DirX on Dir {
  int get dx => switch (this) {
    Dir.left => -1,
    Dir.right => 1,
    _ => 0,
  };
  int get dy => switch (this) {
    Dir.up => -1,
    Dir.down => 1,
    _ => 0,
  };
  Dir get opposite => Dir.values[(index + 2) % 4];
  Dir get cw => Dir.values[(index + 1) % 4];
  Dir get ccw => Dir.values[(index + 3) % 4];
}

enum ClaimPhase { playing, won, lost }

enum ClaimEventKind { capture, eliminate, playerDied, respawn }

class ClaimEvent {
  const ClaimEvent(this.kind, this.painter, this.x, this.y, [this.amount = 0]);
  final ClaimEventKind kind;
  final int painter;
  final int x;
  final int y;
  final int amount;
}

class Painter {
  Painter(this.id);
  final int id;
  int x = 0;
  int y = 0;
  Dir dir = Dir.up;
  Dir? queued;
  bool alive = true;
  double progress = 0;
  double respawnTimer = 0;
  final List<int> trail = [];
  int kills = 0;

  // Bot brain.
  int outSteps = 0;
  int legLength = 0;
  int legsDone = 0;
  bool homing = false;

  bool get isPlayer => id == 1;
}

class ClaimWorld {
  ClaimWorld({this.cols = 36, this.rows = 60, this.bots = 3, int seed = 1, this.winShare = 0.5})
    : _rng = math.Random(seed),
      owner = List<int>.filled(cols * rows, 0),
      trailOwner = List<int>.filled(cols * rows, 0) {
    for (var i = 0; i <= bots; i++) {
      painters.add(Painter(i + 1));
    }
    _spawn(painters[0], cols ~/ 2, (rows * 0.62).round());
    for (var i = 1; i < painters.length; i++) {
      _spawnRandom(painters[i]);
    }
  }

  final int cols;
  final int rows;
  final int bots;
  final double winShare;
  final math.Random _rng;

  /// Owner id per cell (0 = unclaimed).
  final List<int> owner;

  /// Trail owner id per cell (0 = no trail).
  final List<int> trailOwner;
  final List<Painter> painters = [];
  final List<ClaimEvent> events = [];

  ClaimPhase phase = ClaimPhase.playing;
  double time = 0;
  double speed = 7.5; // cells per second
  int captures = 0;

  Painter get player => painters[0];
  bool get isOver => phase != ClaimPhase.playing;
  int get entityCount =>
      painters.where((p) => p.alive).length + painters.fold(0, (a, p) => a + p.trail.length);

  int idx(int x, int y) => y * cols + x;
  bool inBounds(int x, int y) => x >= 0 && y >= 0 && x < cols && y < rows;

  int cellsOwnedBy(int id) => owner.where((o) => o == id).length;
  double shareOf(int id) => cellsOwnedBy(id) / owner.length;
  double get playerShare => shareOf(1);

  int get score => (playerShare * 10000).round() + player.kills * 250;

  void _spawnRandom(Painter p) {
    for (var attempt = 0; attempt < 40; attempt++) {
      final x = 3 + _rng.nextInt(cols - 6);
      final y = 3 + _rng.nextInt(rows - 6);
      var free = true;
      for (var dy = -2; dy <= 2 && free; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final i = idx(x + dx, y + dy);
          if (owner[i] != 0 || trailOwner[i] != 0) {
            free = false;
            break;
          }
        }
      }
      if (free || attempt == 39) {
        _spawn(p, x, y);
        return;
      }
    }
  }

  void _spawn(Painter p, int x, int y) {
    p
      ..x = x
      ..y = y
      ..alive = true
      ..progress = 0
      ..dir = Dir.values[_rng.nextInt(4)]
      ..queued = null
      ..homing = false
      ..outSteps = 0
      ..legsDone = 0;
    p.trail.clear();
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final cx = x + dx, cy = y + dy;
        if (!inBounds(cx, cy)) continue;
        final i = idx(cx, cy);
        if (trailOwner[i] != 0) continue;
        owner[i] = p.id;
      }
    }
  }

  /// Requests a turn for the player. Reversing straight back is ignored.
  void steer(Dir d) {
    if (d == player.dir.opposite) return;
    player.queued = d;
  }

  void update(double dt) {
    events.clear();
    if (isOver) return;
    var remaining = math.min(dt, 0.25);
    while (remaining > 1e-9 && !isOver) {
      final step = math.min(remaining, 1 / 60);
      _tick(step);
      remaining -= step;
    }
  }

  void _tick(double dt) {
    time += dt;
    for (final p in painters) {
      if (!p.alive) {
        if (!p.isPlayer) {
          p.respawnTimer -= dt;
          if (p.respawnTimer <= 0) {
            _spawnRandom(p);
            events.add(ClaimEvent(ClaimEventKind.respawn, p.id, p.x, p.y));
          }
        }
        continue;
      }
      p.progress += speed * (p.isPlayer ? 1 : 0.88) * dt;
      while (p.progress >= 1 && p.alive && !isOver) {
        p.progress -= 1;
        if (!p.isPlayer) _think(p);
        _advance(p);
      }
    }
    if (!isOver && playerShare >= winShare) phase = ClaimPhase.won;
  }

  /// Moves a painter one cell, handling trails, captures and eliminations.
  void _advance(Painter p) {
    final q = p.queued;
    if (q != null && q != p.dir.opposite) p.dir = q;
    p.queued = null;
    var nx = p.x + p.dir.dx, ny = p.y + p.dir.dy;
    if (!inBounds(nx, ny)) {
      // Walls deflect: turn clockwise (or counter-clockwise) instead of dying.
      for (final d in [p.dir.cw, p.dir.ccw]) {
        if (inBounds(p.x + d.dx, p.y + d.dy)) {
          p.dir = d;
          break;
        }
      }
      nx = p.x + p.dir.dx;
      ny = p.y + p.dir.dy;
    }
    final i = idx(nx, ny);
    final t = trailOwner[i];
    if (t != 0) {
      // Crossing any trail cuts it: its owner is eliminated.
      final victim = painters[t - 1];
      _eliminate(victim, by: p);
      if (!p.alive) return;
    }
    p
      ..x = nx
      ..y = ny;
    if (owner[i] == p.id) {
      if (p.trail.isNotEmpty) _capture(p);
    } else {
      trailOwner[i] = p.id;
      p.trail.add(i);
    }
    // Head-on: two heads on the same cell → the one with less territory loses.
    for (final o in painters) {
      if (o == p || !o.alive || o.x != p.x || o.y != p.y) continue;
      final loser = cellsOwnedBy(o.id) <= cellsOwnedBy(p.id) ? o : p;
      _eliminate(loser, by: loser == o ? p : o);
    }
  }

  void _eliminate(Painter victim, {required Painter by}) {
    if (!victim.alive) return;
    victim.alive = false;
    for (final c in victim.trail) {
      if (trailOwner[c] == victim.id) trailOwner[c] = 0;
    }
    victim.trail.clear();
    if (victim != by) by.kills++;
    if (victim.isPlayer) {
      phase = ClaimPhase.lost;
      events.add(ClaimEvent(ClaimEventKind.playerDied, victim.id, victim.x, victim.y));
      return;
    }
    // Bots lose their land and come back later.
    for (var c = 0; c < owner.length; c++) {
      if (owner[c] == victim.id) owner[c] = 0;
    }
    victim.respawnTimer = 3;
    events.add(ClaimEvent(ClaimEventKind.eliminate, victim.id, victim.x, victim.y));
  }

  /// Converts the trail to territory and fills every region enclosed by it.
  void _capture(Painter p) {
    final before = cellsOwnedBy(p.id);
    for (final c in p.trail) {
      owner[c] = p.id;
      trailOwner[c] = 0;
    }
    p.trail.clear();
    // Flood from the border through cells not owned by p; unreached = enclosed.
    final reached = List<bool>.filled(owner.length, false);
    final queue = Queue<int>();
    void seed(int x, int y) {
      final i = idx(x, y);
      if (!reached[i] && owner[i] != p.id) {
        reached[i] = true;
        queue.add(i);
      }
    }

    for (var x = 0; x < cols; x++) {
      seed(x, 0);
      seed(x, rows - 1);
    }
    for (var y = 0; y < rows; y++) {
      seed(0, y);
      seed(cols - 1, y);
    }
    while (queue.isNotEmpty) {
      final i = queue.removeFirst();
      final x = i % cols, y = i ~/ cols;
      if (x > 0) seed(x - 1, y);
      if (x < cols - 1) seed(x + 1, y);
      if (y > 0) seed(x, y - 1);
      if (y < rows - 1) seed(x, y + 1);
    }
    for (var c = 0; c < owner.length; c++) {
      if (!reached[c] && owner[c] != p.id) {
        // Enclosed: claim it. Enclosed rival trails are cut.
        final t = trailOwner[c];
        if (t != 0 && t != p.id) _eliminate(painters[t - 1], by: p);
        owner[c] = p.id;
      }
    }
    // A rival whose head is now inside our land keeps going; but a rival that
    // lost all its land is eliminated.
    for (final o in painters) {
      if (o != p && o.alive && !o.isPlayer && cellsOwnedBy(o.id) == 0 && o.trail.isEmpty) {
        _eliminate(o, by: p);
      }
    }
    final gained = cellsOwnedBy(p.id) - before;
    captures++;
    events.add(ClaimEvent(ClaimEventKind.capture, p.id, p.x, p.y, gained));
  }

  /// Simple bot: go out a short leg, turn, go along, turn back home.
  void _think(Painter p) {
    final home = owner[idx(p.x, p.y)] == p.id;
    if (home && p.trail.isEmpty) {
      p.homing = false;
      p.legsDone = 0;
      if (_rng.nextDouble() < 0.25) p.queued = _rng.nextBool() ? p.dir.cw : p.dir.ccw;
      p.legLength = 3 + _rng.nextInt(6);
      p.outSteps = 0;
      return;
    }
    p.outSteps++;
    // Danger: the player head is close to our trail → rush home.
    final pl = player;
    if (pl.alive && p.trail.isNotEmpty) {
      for (final c in p.trail) {
        final cx = c % cols, cy = c ~/ cols;
        if ((cx - pl.x).abs() + (cy - pl.y).abs() <= 3) {
          p.homing = true;
          break;
        }
      }
    }
    if (!p.homing && p.outSteps >= p.legLength) {
      p.outSteps = 0;
      p.legsDone++;
      final turn = p.legsDone.isOdd ? p.dir.cw : p.dir.ccw;
      p.queued = turn;
      if (p.legsDone >= 2) p.homing = true;
    }
    if (p.homing) p.queued = _homeDirection(p);
    // Never step onto our own trail.
    final next = p.queued ?? p.dir;
    final nx = p.x + next.dx, ny = p.y + next.dy;
    if (inBounds(nx, ny) && trailOwner[idx(nx, ny)] == p.id) {
      for (final d in [next.cw, next.ccw]) {
        final ax = p.x + d.dx, ay = p.y + d.dy;
        if (inBounds(ax, ay) && trailOwner[idx(ax, ay)] != p.id && d != p.dir.opposite) {
          p.queued = d;
          break;
        }
      }
    }
  }

  Dir _homeDirection(Painter p) {
    // Nearest owned cell by Manhattan distance (coarse scan).
    var best = double.infinity;
    var tx = p.x, ty = p.y;
    for (var c = 0; c < owner.length; c += 1) {
      if (owner[c] != p.id) continue;
      final cx = c % cols, cy = c ~/ cols;
      final d = ((cx - p.x).abs() + (cy - p.y).abs()).toDouble();
      if (d < best) {
        best = d;
        tx = cx;
        ty = cy;
      }
    }
    final options = <Dir>[];
    if (tx > p.x) options.add(Dir.right);
    if (tx < p.x) options.add(Dir.left);
    if (ty > p.y) options.add(Dir.down);
    if (ty < p.y) options.add(Dir.up);
    for (final d in options) {
      final nx = p.x + d.dx, ny = p.y + d.dy;
      if (d != p.dir.opposite && inBounds(nx, ny) && trailOwner[idx(nx, ny)] != p.id) return d;
    }
    return p.dir;
  }

  // --- Test helpers ---
  void debugPlace(Painter p, int x, int y, Dir dir) {
    p
      ..x = x
      ..y = y
      ..dir = dir
      ..queued = null
      ..progress = 0;
  }

  /// Advances only the given painter by one cell.
  void debugStep(Painter p) {
    events.clear();
    _advance(p);
    if (!isOver && playerShare >= winShare) phase = ClaimPhase.won;
  }

  void debugFreezeBots() {
    for (final b in painters.skip(1)) {
      _eliminate(b, by: b);
      b.respawnTimer = 1e9;
    }
  }
}
