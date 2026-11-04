import 'dart:math' as math;
import 'dart:ui';

import 'package:vector_math/vector_math.dart';

/// Pinhole projection matching flutter_scene's `PerspectiveCamera` conventions
/// (left-handed view space: +X right, +Y up, +Z into the screen; vertical FOV).
///
/// Used for HUD labels anchored to 3D objects and for the 2.5D canvas
/// fallback renderer, so both render paths agree on where things are.
class Projector {
  Projector({
    required this.eye,
    required this.target,
    required this.size,
    this.fovY = 50 * math.pi / 180,
    Vector3? up,
  }) : up = up ?? Vector3(0, 1, 0) {
    _forward = (target - eye)..normalize();
    _right = this.up.cross(_forward)..normalize();
    _up2 = _forward.cross(_right)..normalize();
    _tanY = math.tan(fovY / 2);
  }

  final Vector3 eye;
  final Vector3 target;
  final Vector3 up;
  final Size size;
  final double fovY;

  late final Vector3 _forward;
  late final Vector3 _right;
  late final Vector3 _up2;
  late final double _tanY;

  double get aspect => size.height == 0 ? 1 : size.width / size.height;

  /// View-space depth of [p] (distance along the camera's forward axis).
  double depth(Vector3 p) => (p - eye).dot(_forward);

  /// Projects a world point to screen pixels, or null if behind the camera.
  Offset? project(Vector3 p) => projectXYZ(p.x, p.y, p.z);

  Offset? projectXYZ(double x, double y, double z) {
    final dx = x - eye.x, dy = y - eye.y, dz = z - eye.z;
    final zc = dx * _forward.x + dy * _forward.y + dz * _forward.z;
    if (zc <= 0.05) return null;
    final xs = (dx * _right.x + dy * _right.y + dz * _right.z) / zc;
    final ys = (dx * _up2.x + dy * _up2.y + dz * _up2.z) / zc;
    final ndcX = xs / (_tanY * aspect);
    final ndcY = ys / _tanY;
    return Offset((ndcX + 1) / 2 * size.width, (1 - ndcY) / 2 * size.height);
  }

  /// Screen-space size in pixels of a world length [worldSize] at depth of [p].
  double scaleAt(Vector3 p, double worldSize) {
    final z = depth(p);
    if (z <= 0.05) return 0;
    return worldSize / (z * _tanY) * size.height / 2;
  }

  /// Intersects the camera ray through screen point [s] with the plane y = [planeY].
  Vector3? unprojectToGround(Offset s, {double planeY = 0}) {
    final ndcX = s.dx / size.width * 2 - 1;
    final ndcY = 1 - s.dy / size.height * 2;
    final dir = _forward + _right * (ndcX * _tanY * aspect) + _up2 * (ndcY * _tanY);
    if (dir.y.abs() < 1e-6) return null;
    final t = (planeY - eye.y) / dir.y;
    if (t <= 0) return null;
    return eye + dir * t;
  }
}
