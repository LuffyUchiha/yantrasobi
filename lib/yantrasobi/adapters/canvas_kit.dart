import 'dart:collection';

import 'package:flutter/painting.dart';

/// Small helpers for drawing HUDs straight onto a game canvas.
class CanvasText {
  CanvasText._();

  static final LinkedHashMap<String, TextPainter> _cache = LinkedHashMap();
  static const int _maxEntries = 160;

  /// Draws [text] anchored at [at]; [align] picks the anchor
  /// (e.g. `Alignment.center` centres the text on [at]).
  static Size draw(
    Canvas canvas,
    String text,
    Offset at, {
    double size = 16,
    Color color = const Color(0xFFFFFFFF),
    FontWeight weight = FontWeight.w700,
    Alignment align = Alignment.topLeft,
    double? maxWidth,
  }) {
    final key = '$text|$size|${color.toARGB32()}|${weight.value}|$maxWidth';
    var tp = _cache.remove(key);
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            color: color,
            fontWeight: weight,
            shadows: const [Shadow(blurRadius: 3, color: Color(0xAA000000), offset: Offset(0, 1))],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth ?? double.infinity);
      if (_cache.length >= _maxEntries) {
        _cache.remove(_cache.keys.first)?.dispose();
      }
    }
    _cache[key] = tp;
    final dx = at.dx - tp.width * (align.x + 1) / 2;
    final dy = at.dy - tp.height * (align.y + 1) / 2;
    tp.paint(canvas, Offset(dx, dy));
    return tp.size;
  }
}

/// Draws a horizontal progress bar.
void drawBar(Canvas canvas, Rect rect, double t, Color fill, {Color back = const Color(0x66000000)}) {
  final r = Radius.circular(rect.height / 2);
  canvas.drawRRect(RRect.fromRectAndRadius(rect, r), Paint()..color = back);
  final w = rect.width * t.clamp(0.0, 1.0);
  if (w > 0) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(rect.left, rect.top, w, rect.height), r),
      Paint()..color = fill,
    );
  }
}
