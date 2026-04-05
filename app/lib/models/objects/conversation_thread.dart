import 'stroke.dart';

/// A conversation thread anchored at a horizontal region.
/// Tracks session, pending strokes, and vertical layout.
class ConversationThread {
  String sessionId;
  double xCenter;
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
