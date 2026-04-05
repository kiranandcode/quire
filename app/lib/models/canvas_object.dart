import 'dart:ui';
import 'package:perfect_freehand/perfect_freehand.dart';

/// Base class for all objects on the canvas.
abstract class CanvasObject {
  Rect get boundingBox;
  void translate(Offset delta);
  Map<String, dynamic> toJson();
}

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
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stroke',
    'point_count': points.length,
    'bbox': {'l': boundingBox.left, 't': boundingBox.top, 'r': boundingBox.right, 'b': boundingBox.bottom},
  };
}

class TextObject extends CanvasObject {
  String text;
  Offset position;
  double fontSize;
  String? sessionId;
  String? ocrSource;
  bool isUserText;
  String? conversationLabel;

  TextObject({
    required this.text,
    required this.position,
    this.fontSize = 16,
    this.sessionId,
    this.ocrSource,
    this.isUserText = false,
    this.conversationLabel,
  });

  @override
  Rect get boundingBox {
    // Approximate width: measure per line
    final lines = text.split('\n');
    double maxWidth = 0;
    for (final line in lines) {
      final w = line.length * fontSize * 0.55;
      if (w > maxWidth) maxWidth = w;
    }
    maxWidth = maxWidth.clamp(50, double.infinity);
    final height = lines.length * fontSize * 1.4;
    return Rect.fromLTWH(position.dx, position.dy, maxWidth, height);
  }

  @override
  void translate(Offset delta) {
    position = position + delta;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'text': text,
    'position': {'x': position.dx, 'y': position.dy},
    'fontSize': fontSize,
    'sessionId': sessionId,
    'ocrSource': ocrSource,
    'isUserText': isUserText,
  };
}

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
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'thinking',
    'label': label,
    'position': {'x': position.dx, 'y': position.dy},
    'sessionId': sessionId,
  };
}

/// A conversation thread anchored at a horizontal region.
/// Tracks session, pending strokes, and vertical layout.
class ConversationThread {
  String sessionId;
  double xCenter; // horizontal center of this thread
  double xMin;
  double xMax;
  bool isWaitingForResponse = false;
  List<StrokeObject> pendingStrokes = [];

  ConversationThread({
    required this.sessionId,
    required this.xCenter,
    required this.xMin,
    required this.xMax,
  });

  bool containsX(double x) {
    return x >= xMin && x <= xMax;
  }
}

/// Small light text above handwriting showing what OCR digitized.
class OcrAnnotationObject extends CanvasObject {
  String text;
  Offset position;
  double maxWidth;

  OcrAnnotationObject({
    required this.text,
    required this.position,
    required this.maxWidth,
  });

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
    position = position + delta;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'ocr_annotation',
    'text': text,
    'position': {'x': position.dx, 'y': position.dy},
  };
}

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
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image_bbox',
    'rect': {'l': worldRect.left, 't': worldRect.top, 'r': worldRect.right, 'b': worldRect.bottom},
    'label': label,
  };
}
