import 'dart:ui';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'base.dart';

class StrokeObject extends CanvasObject {
  final List<PointVector> points;
  Rect? _cachedBounds;

  StrokeObject({required this.points});

  @override
  Rect get boundingBox {
    if (_cachedBounds != null) return _cachedBounds!;
    if (points.isEmpty) return Rect.zero;
    double minX = points.first.x, maxX = points.first.x;
    double minY = points.first.y, maxY = points.first.y;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    _cachedBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    return _cachedBounds!;
  }

  @override
  void translate(Offset delta) {
    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      points[i] = PointVector(p.x + delta.dx, p.y + delta.dy, p.pressure);
    }
    _cachedBounds = null;
    super.translate(delta);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stroke',
    'point_count': points.length,
    'bbox': {'l': boundingBox.left, 't': boundingBox.top, 'r': boundingBox.right, 'b': boundingBox.bottom},
  };
}
