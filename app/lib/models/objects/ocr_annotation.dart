import 'dart:ui';
import 'base.dart';
import 'stroke.dart';

/// Small light text above handwriting showing what OCR digitized.
///
/// This is a child object — it derives its position from its parent strokes
/// and cannot be selected or moved independently. It moves when its parents
/// move, and is removed when all parents are deleted.
class OcrAnnotationObject extends CanvasObject {
  String text;
  final List<StrokeObject> parentStrokes;

  OcrAnnotationObject({
    required this.text,
    required this.parentStrokes,
  });

  Rect get _parentBounds {
    if (parentStrokes.isEmpty) return Rect.zero;
    Rect bounds = parentStrokes.first.boundingBox;
    for (final s in parentStrokes.skip(1)) {
      bounds = bounds.expandToInclude(s.boundingBox);
    }
    return bounds;
  }

  Offset get position {
    final pb = _parentBounds;
    return Offset(pb.left, pb.top - 18);
  }

  double get maxWidth => _parentBounds.width.clamp(200, 600);

  @override
  Rect get boundingBox {
    final lines = text.split('\n');
    const fontSize = 11.0;
    double w = 0;
    for (final line in lines) {
      final lw = line.length * fontSize * 0.5;
      if (lw > w) w = lw;
    }
    w = w.clamp(50, maxWidth);
    final h = lines.length * fontSize * 1.3;
    return Rect.fromLTWH(position.dx, position.dy, w, h);
  }

  @override
  void translate(Offset delta) {
    // No-op: position is derived from parent strokes.
  }

  @override
  bool get isSelectable => false;

  /// Returns true if all parent strokes have been removed from the objects list.
  bool isOrphaned(List<CanvasObject> objects) {
    return !parentStrokes.any((s) => objects.contains(s));
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'ocr_annotation',
    'text': text,
  };
}
