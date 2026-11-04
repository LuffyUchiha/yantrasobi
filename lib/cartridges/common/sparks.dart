import 'dart:math' as math;
import 'dart:ui';

/// Pooled, allocation-free particle bursts shared by 2D cartridges.
class Sparks {
  Sparks({this.capacity = 400});

  final int capacity;
  final math.Random _rng = math.Random(3);
  final List<_Spark> _pool = [];
  int _live = 0;

  int get count => _live;

  void burst(double x, double y, int n, Color color, {double speed = 220, double life = 0.5}) {
    for (var i = 0; i < n; i++) {
      _Spark s;
      if (_live < _pool.length) {
        s = _pool[_live];
      } else if (_pool.length < capacity) {
        s = _Spark();
        _pool.add(s);
      } else {
        return;
      }
      _live++;
      final a = _rng.nextDouble() * math.pi * 2;
      final v = speed * (0.3 + _rng.nextDouble() * 0.7);
      s
        ..x = x
        ..y = y
        ..vx = math.cos(a) * v
        ..vy = math.sin(a) * v
        ..life = life * (0.5 + _rng.nextDouble() * 0.5)
        ..maxLife = life
        ..color = color;
    }
  }

  void update(double dt) {
    var i = 0;
    while (i < _live) {
      final s = _pool[i];
      s.life -= dt;
      if (s.life <= 0) {
        // Swap-remove with the last live spark.
        _live--;
        _pool[i] = _pool[_live];
        _pool[_live] = s;
        continue;
      }
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      s.vx *= 0.92;
      s.vy *= 0.92;
      i++;
    }
  }

  void clear() => _live = 0;

  final Paint _paint = Paint();

  void render(Canvas canvas) {
    for (var i = 0; i < _live; i++) {
      final s = _pool[i];
      final t = (s.life / s.maxLife).clamp(0.0, 1.0);
      _paint.color = s.color.withValues(alpha: t);
      canvas.drawCircle(Offset(s.x, s.y), 1.5 + 2.5 * t, _paint);
    }
  }
}

class _Spark {
  double x = 0, y = 0, vx = 0, vy = 0, life = 0, maxLife = 1;
  Color color = const Color(0xFFFFFFFF);
}
