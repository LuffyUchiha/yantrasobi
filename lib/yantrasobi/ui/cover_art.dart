import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../cartridge/manifest.dart';

/// Procedurally generated cartridge cover. Deterministic per cartridge id, so
/// no image assets are needed.
class CartridgeCover extends StatelessWidget {
  const CartridgeCover({super.key, required this.manifest, this.iconSize = 44});

  final CartridgeManifest manifest;
  final double iconSize;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _CoverPainter(manifest.id, manifest.accent),
    child: Center(
      child: Icon(manifest.icon, size: iconSize, color: Colors.white.withValues(alpha: 0.95)),
    ),
  );
}

class _CoverPainter extends CustomPainter {
  _CoverPainter(this.id, this.accent);

  final String id;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final seed = id.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff);
    final rng = math.Random(seed);
    final rect = Offset.zero & size;
    final hsl = HSLColor.fromColor(accent);
    final dark = hsl.withLightness((hsl.lightness * 0.35).clamp(0, 1)).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, dark],
        ).createShader(rect),
    );
    final style = rng.nextInt(3);
    final p = Paint()..color = Colors.white.withValues(alpha: 0.10);
    for (var i = 0; i < 9; i++) {
      final c = Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height);
      final r = size.shortestSide * (0.08 + rng.nextDouble() * 0.25);
      switch (style) {
        case 0:
          canvas.drawCircle(c, r, p);
        case 1:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: c, width: r * 2, height: r * 1.2),
              Radius.circular(r * 0.3),
            ),
            p,
          );
        default:
          final path = Path()
            ..moveTo(c.dx, c.dy - r)
            ..lineTo(c.dx + r, c.dy + r)
            ..lineTo(c.dx - r, c.dy + r)
            ..close();
          canvas.drawPath(path, p);
      }
    }
  }

  @override
  bool shouldRepaint(_CoverPainter old) => old.id != id || old.accent != accent;
}
