import 'dart:math' as math;

/// Pure-Dart rules for Key Cascade: four lanes of falling keys. Tap the next
/// key in order (it plays the next note of the tune), hold long keys, and
/// don't tap empty lanes or let a key slip past the bottom.

class Song {
  const Song(this.title, this.notes, {this.bpm = 100});
  final String title;

  /// (midi, beats) pairs. Beats ≥ 2 become hold keys.
  final List<(int, int)> notes;
  final int bpm;
}

/// Public-domain melodies plus original procedural tunes.
class Songs {
  static const Song odeToJoy = Song('Ode to Joy (Beethoven, public domain)', [
    (64, 1),
    (64, 1),
    (65, 1),
    (67, 1),
    (67, 1),
    (65, 1),
    (64, 1),
    (62, 1),
    (60, 1),
    (60, 1),
    (62, 1),
    (64, 1),
    (64, 1),
    (62, 1),
    (62, 2),
    (64, 1),
    (64, 1),
    (65, 1),
    (67, 1),
    (67, 1),
    (65, 1),
    (64, 1),
    (62, 1),
    (60, 1),
    (60, 1),
    (62, 1),
    (64, 1),
    (62, 1),
    (60, 1),
    (60, 2),
  ], bpm: 96);

  static const Song twinkle = Song('Twinkle Twinkle (traditional, public domain)', [
    (60, 1),
    (60, 1),
    (67, 1),
    (67, 1),
    (69, 1),
    (69, 1),
    (67, 2),
    (65, 1),
    (65, 1),
    (64, 1),
    (64, 1),
    (62, 1),
    (62, 1),
    (60, 2),
    (67, 1),
    (67, 1),
    (65, 1),
    (65, 1),
    (64, 1),
    (64, 1),
    (62, 2),
    (67, 1),
    (67, 1),
    (65, 1),
    (65, 1),
    (64, 1),
    (64, 1),
    (62, 2),
  ], bpm: 100);

  /// An original tune: a seeded random walk on the C major pentatonic scale.
  static Song lantern(int seed, {int length = 40}) {
    final rng = math.Random(seed);
    const scale = [60, 62, 64, 67, 69, 72, 74, 76];
    var i = 3;
    final notes = <(int, int)>[];
    for (var k = 0; k < length; k++) {
      i = (i + rng.nextInt(5) - 2).clamp(0, scale.length - 1);
      final beats = (k % 8 == 7) ? 2 : 1;
      notes.add((scale[i], beats));
    }
    return Song('Lantern Walk (original)', notes, bpm: 108);
  }

  static List<Song> forLevel(int level) => [odeToJoy, twinkle, lantern(level * 7)];
}

class KeyTile {
  KeyTile(this.index, this.lane, this.beat, this.length, this.midi);
  final int index;
  final int lane;

  /// Beat at which the tile's bottom edge reaches the bottom of the screen.
  final double beat;
  final int length;
  final int midi;
  bool tapped = false;
  bool holding = false;
  double heldBeats = 0;
  bool missed = false;
  bool get isHold => length >= 2;
}

enum CascadeEventKind { hit, holdComplete, miss, songEnd }

class CascadeEvent {
  const CascadeEvent(this.kind, this.lane, [this.midi = 0]);
  final CascadeEventKind kind;
  final int lane;
  final int midi;
}

class CascadeWorld {
  CascadeWorld({required this.song, this.lanes = 4, int seed = 1, this.speedScale = 1}) {
    final rng = math.Random(seed);
    var beat = 4.0; // a few empty rows before the first key
    var lastLane = -1;
    for (var i = 0; i < song.notes.length; i++) {
      final (midi, beats) = song.notes[i];
      var lane = rng.nextInt(lanes);
      if (lane == lastLane) lane = (lane + 1 + rng.nextInt(lanes - 1)) % lanes;
      lastLane = lane;
      tiles.add(KeyTile(i, lane, beat, beats, midi));
      beat += beats;
    }
    endBeat = beat + 2;
  }

  /// Rows visible on screen (one row = one beat).
  static const double visibleRows = 4.5;
  static const int startLives = 3;

  final Song song;
  final int lanes;
  final double speedScale;
  final List<KeyTile> tiles = [];
  final List<CascadeEvent> events = [];
  late final double endBeat;

  double beat = 0;
  int lives = startLives;
  int score = 0;
  int hits = 0;
  int misses = 0;
  int combo = 0;
  int bestCombo = 0;
  bool started = false;
  bool finished = false;
  int _next = 0;
  final Set<int> _down = {};

  bool get isOver => finished || lives <= 0;
  bool get won => finished && lives > 0;
  double get beatsPerSecond => song.bpm / 60 * speedScale;
  int get entityCount => tiles.where((t) => !t.tapped && !t.missed).length;
  KeyTile? get nextTile => _next < tiles.length ? tiles[_next] : null;
  double get accuracy => tiles.isEmpty ? 0 : hits / tiles.length;

  /// 0..3 stars from accuracy, awarded on completion.
  int get stars => !won
      ? 0
      : (accuracy >= 0.98
            ? 3
            : accuracy >= 0.85
            ? 2
            : 1);

  void update(double dt) {
    events.clear();
    if (isOver || !started) return;
    beat += dt * beatsPerSecond;
    // Advance held tiles.
    for (final t in tiles) {
      if (!t.holding) continue;
      t.heldBeats = math.min(t.length.toDouble(), beat - t.beat);
      if (t.heldBeats >= t.length - 0.05) {
        t.holding = false;
        score += 10 * t.length;
        events.add(CascadeEvent(CascadeEventKind.holdComplete, t.lane, t.midi));
      }
    }
    // A key whose top edge leaves the bottom of the screen unplayed is a miss.
    final next = nextTile;
    if (next != null && !next.tapped && beat > next.beat + next.length + 0.15) {
      _miss(next.lane, skip: true);
    }
    if (_next >= tiles.length && beat >= endBeat) {
      finished = true;
      score += lives * 50;
      events.add(const CascadeEvent(CascadeEventKind.songEnd, -1));
    }
  }

  /// A finger touched [lane].
  void press(int lane) {
    if (isOver) return;
    _down.add(lane);
    final next = nextTile;
    if (!started) {
      // The first tap must hit the first key, which also starts the scroll.
      if (next != null && next.lane == lane) {
        started = true;
        beat = next.beat;
        _hit(next);
      }
      return;
    }
    if (next == null) return;
    final onScreen = next.beat - beat < visibleRows;
    if (next.lane == lane && onScreen) {
      _hit(next);
    } else {
      _miss(lane);
    }
  }

  /// A finger lifted from [lane]; releasing a hold key early ends it.
  void release(int lane) {
    _down.remove(lane);
    for (final t in tiles) {
      if (t.holding && t.lane == lane) {
        t.holding = false;
        score += (10 * t.heldBeats).round();
      }
    }
  }

  void _hit(KeyTile t) {
    t.tapped = true;
    hits++;
    combo++;
    bestCombo = math.max(bestCombo, combo);
    score += 10 + math.min(combo, 50) ~/ 10;
    if (t.isHold && _down.contains(t.lane)) t.holding = true;
    _next++;
    events.add(CascadeEvent(CascadeEventKind.hit, t.lane, t.midi));
  }

  void _miss(int lane, {bool skip = false}) {
    lives--;
    misses++;
    combo = 0;
    if (skip) {
      tiles[_next].missed = true;
      _next++;
    }
    events.add(CascadeEvent(CascadeEventKind.miss, lane));
  }
}
