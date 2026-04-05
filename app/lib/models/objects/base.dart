import 'dart:ui';

/// Base class for all objects on the canvas.
///
/// Supports a parent-child hierarchy: children position themselves relative
/// to their parent and move with it. Children cannot be moved independently.
abstract class CanvasObject {
  CanvasObject? parent;
  final List<CanvasObject> children = [];

  /// Bounding box in world coordinates.
  Rect get boundingBox;

  /// Move this object by [delta] in world coordinates.
  /// Also translates all children (unless they derive position from parent).
  void translate(Offset delta) {
    for (final child in children) {
      child.translate(delta);
    }
  }

  /// Serialize for debug dumps.
  Map<String, dynamic> toJson();

  /// Add a child object. Sets the child's parent to this.
  void addChild(CanvasObject child) {
    child.parent = this;
    children.add(child);
  }

  /// Remove a child object. Clears the child's parent.
  void removeChild(CanvasObject child) {
    child.parent = null;
    children.remove(child);
  }

  /// Whether this object can be independently selected and moved.
  /// Override to return false for dependent objects (e.g. OCR annotations).
  bool get isSelectable => true;
}
