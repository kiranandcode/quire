import 'dart:ui';
import 'base.dart';

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

  static const double maxLineWidth = 600.0;

  @override
  Rect get boundingBox {
    final lines = text.split('\n');
    final charWidth = fontSize * 0.55;
    double totalHeight = 0;
    for (final line in lines) {
      final lineWidth = line.length * charWidth;
      final wrappedLines = lineWidth > maxLineWidth
          ? (lineWidth / maxLineWidth).ceil()
          : 1;
      totalHeight += wrappedLines * fontSize * 1.6;
    }
    return Rect.fromLTWH(position.dx, position.dy, maxLineWidth, totalHeight);
  }

  @override
  void translate(Offset delta) {
    position = position + delta;
    super.translate(delta);
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
