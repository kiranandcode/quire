import 'dart:ui';
import 'base.dart';

/// A thinking indicator shown while waiting for Claude.
class ThinkingObject extends CanvasObject {
  Offset position;
  String label;
  String? sessionId;

  ThinkingObject({
    required this.position,
    this.label = 'thinking...',
    this.sessionId,
  });

  @override
  Rect get boundingBox {
    return Rect.fromLTWH(position.dx, position.dy, 250, 30);
  }

  @override
  void translate(Offset delta) {
    position = position + delta;
    super.translate(delta);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'thinking',
    'label': label,
    'position': {'x': position.dx, 'y': position.dy},
    'sessionId': sessionId,
  };
}
