import 'dart:ui';
import 'base.dart';

/// Bounding box around a detected image region on the canvas.
class ImageBboxObject extends CanvasObject {
  Rect worldRect;
  String? label;

  ImageBboxObject({required this.worldRect, this.label});

  @override
  Rect get boundingBox => worldRect;

  @override
  void translate(Offset delta) {
    worldRect = worldRect.translate(delta.dx, delta.dy);
    super.translate(delta);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image_bbox',
    'rect': {'l': worldRect.left, 't': worldRect.top, 'r': worldRect.right, 'b': worldRect.bottom},
    'label': label,
  };
}
