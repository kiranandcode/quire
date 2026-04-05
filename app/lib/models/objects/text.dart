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

  @override
  Rect get boundingBox {
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
