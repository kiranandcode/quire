import 'dart:typed_data';
import 'dart:ui';
import 'base.dart';

/// A rendered diagram (LaTeX/SVG → PNG) displayed on the canvas.
class DiagramObject extends CanvasObject {
  Offset position;
  final Uint8List imageBytes;
  double width;
  double height;

  DiagramObject({
    required this.position,
    required this.imageBytes,
    this.width = 0,
    this.height = 0,
  });

  @override
  Rect get boundingBox => Rect.fromLTWH(position.dx, position.dy, width, height);

  @override
  void translate(Offset delta) {
    position = position + delta;
    super.translate(delta);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'diagram',
    'position': {'x': position.dx, 'y': position.dy},
    'width': width,
    'height': height,
    'bytes': imageBytes.length,
  };
}
