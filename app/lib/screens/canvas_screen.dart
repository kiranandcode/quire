import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import '../models/canvas_object.dart';
import '../services/chat_service.dart';
import '../services/debug_service.dart';
import '../services/ocr_service.dart';
import '../services/settings_service.dart';
import 'settings_screen.dart';

enum Tool { pen, select, claude }

const _thinkingWords = [
  'thinking...',
  'discombobulating...',
  'financialising...',
  'bubigongsonning...',
  'perambulating...',
  'defenestrating...',
  'confabulating...',
  'discombobulating...',
  'ruminating...',
  'pontificating...',
  'cogitating...',
  'deliberating...',
  'noodling...',
  'philosophising...',
  'brain-wrangling...',
];

class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key});

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  final List<CanvasObject> _objects = [];
  StrokeObject? _currentStroke;
  bool _showWelcome = true;
  final GlobalKey _canvasRepaintKey = GlobalKey();

  // Tool state
  Tool _activeTool = Tool.pen;

  // Selection state
  Rect? _selectionRect;
  Offset? _selectionStart;
  List<CanvasObject> _selectedObjects = [];
  bool _isOcrLoading = false;
  bool _isMoving = false;
  Offset? _moveLastWorld;

  // Canvas transform
  Offset _offset = Offset.zero;
  double _scale = 1.0;
  Offset? _offsetAtGestureStart;
  double? _scaleAtGestureStart;
  Offset? _focalAtGestureStart;

  bool _isStylusGesture = false;
  Offset? _pointerDownWorld; // capture first point before gesture recognizer
  final List<Offset> _earlyMovePoints = []; // points before gesture starts

  // Claude pen state
  final List<ConversationThread> _threads = [];
  Timer? _debounceTimer;
  List<StrokeObject> _claudeStrokeBuffer = [];
  Timer? _thinkingAnimTimer;
  final _random = math.Random();

  // Conversation labels (A, B, C...)
  int _nextConversationLabel = 0;
  final Map<String, String> _threadLabels = {};

  static const _debounceMs = 2500;
  static const _parallelThresholdFactor = 0.6; // fraction of screen width

  String _labelForIndex(int index) {
    String label = '';
    int n = index;
    do {
      label = String.fromCharCode(65 + (n % 26)) + label;
      n = n ~/ 26 - 1;
    } while (n >= 0);
    return label;
  }

  Offset _screenToWorld(Offset screen) {
    return (screen - _offset) / _scale;
  }

  Offset _worldToScreen(Offset world) {
    return world * _scale + _offset;
  }

  double get _parallelThreshold {
    final screenWidth = MediaQuery.of(context).size.width / _scale;
    return screenWidth * _parallelThresholdFactor;
  }

  // --- Basic actions ---

  void _clear() {
    DebugService.trace('clear', {'object_count': _objects.length});
    setState(() {
      _objects.clear();
      _currentStroke = null;
      _clearSelection();
      _threads.clear();
      _claudeStrokeBuffer.clear();
      _debounceTimer?.cancel();
      _thinkingAnimTimer?.cancel();
      _threadLabels.clear();
      _nextConversationLabel = 0;
    });
  }

  void _undo() {
    DebugService.trace('undo');
    if (_objects.isNotEmpty) {
      setState(() {
        _objects.removeLast();
        _clearSelection();
      });
    }
  }

  void _clearSelection() {
    _selectedObjects = [];
    _selectionRect = null;
    _selectionStart = null;
    _isMoving = false;
    _moveLastWorld = null;
  }

  void _selectObjectsInRect(Rect worldRect) {
    _selectedObjects = _objects.where((obj) {
      return worldRect.overlaps(obj.boundingBox);
    }).toList();
  }

  Rect? get _selectionBoundingBox {
    if (_selectedObjects.isEmpty) return null;
    Rect bounds = _selectedObjects.first.boundingBox;
    for (final obj in _selectedObjects.skip(1)) {
      bounds = bounds.expandToInclude(obj.boundingBox);
    }
    return bounds;
  }

  // --- OCR (select tool) ---

  Future<void> _ocrSelected() async {
    final strokes = _selectedObjects.whereType<StrokeObject>().toList();
    if (strokes.isEmpty) return;
    setState(() => _isOcrLoading = true);
    try {
      final text = await OcrService.recognize(strokes);
      if (text.isNotEmpty) {
        setState(() {
          final bounds = _selectionBoundingBox!;
          for (final s in strokes) {
            _objects.remove(s);
          }
          _objects.add(TextObject(
            text: text,
            position: bounds.topLeft,
            fontSize: 20,
          ));
          _clearSelection();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OCR error: $e')),
        );
      }
    } finally {
      setState(() => _isOcrLoading = false);
    }
  }

  // --- Claude pen ---

  ConversationThread? _findThread(double xMin, double xMax) {
    final threshold = _parallelThreshold;
    for (final t in _threads) {
      // Check if horizontal ranges overlap with generous margin
      if (xMin < t.xMax + threshold && xMax > t.xMin - threshold) {
        return t;
      }
    }
    return null;
  }

  void _onClaudeStrokeComplete(StrokeObject stroke) {
    final bb = stroke.boundingBox;
    final isPhantom = _isPhantomStroke(stroke);

    DebugService.trace('stroke_end', {
      'tool': 'claude',
      'points': stroke.points.length,
      'width': bb.width,
      'height': bb.height,
      'ratio': bb.height > 0 ? bb.width / bb.height : 0,
      'phantom': isPhantom,
      'first_pt': {'x': stroke.points.first.x, 'y': stroke.points.first.y, 'p': stroke.points.first.pressure},
      'last_pt': {'x': stroke.points.last.x, 'y': stroke.points.last.y, 'p': stroke.points.last.pressure},
    });

    if (isPhantom) return;

    setState(() {
      _objects.add(stroke);
      _claudeStrokeBuffer.add(stroke);
    });

    DebugService.trace('claude_stroke', {
      'buffer_size': _claudeStrokeBuffer.length,
      'bounds': {
        'l': bb.left,
        't': bb.top,
        'r': bb.right,
        'b': bb.bottom,
      },
    });

    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      Duration(milliseconds: _debounceMs),
      _sendClaudeBuffer,
    );
  }

  void _sendClaudeBuffer() {
    if (_claudeStrokeBuffer.isEmpty) return;
    DebugService.trace('claude_send_buffer', {'stroke_count': _claudeStrokeBuffer.length});

    final strokes = List<StrokeObject>.from(_claudeStrokeBuffer);
    _claudeStrokeBuffer.clear();

    // Find bounding box of all buffered strokes
    Rect bounds = strokes.first.boundingBox;
    for (final s in strokes.skip(1)) {
      bounds = bounds.expandToInclude(s.boundingBox);
    }

    // Find or create thread
    var thread = _findThread(bounds.left, bounds.right);
    DebugService.trace('send_buffer', {
      'stroke_count': strokes.length,
      'bounds': {'l': bounds.left, 't': bounds.top, 'r': bounds.right, 'b': bounds.bottom},
      'found_thread': thread?.sessionId,
      'thread_count': _threads.length,
      'threshold': _parallelThreshold,
    });
    if (thread == null) {
      thread = ConversationThread(
        sessionId: DateTime.now().microsecondsSinceEpoch.toString(),
        xCenter: bounds.center.dx,
        xMin: bounds.left,
        xMax: bounds.right,
      );
      _threads.add(thread);
      _threadLabels[thread.sessionId] = _labelForIndex(_nextConversationLabel++);
    }

    // If thread is already waiting, queue strokes back into buffer
    if (thread.isWaitingForResponse) {
      _claudeStrokeBuffer.addAll(strokes);
      DebugService.trace('send_buffer_queued', {
        'reason': 'thread_waiting',
        'stroke_count': strokes.length,
      });
      return;
    }

    // Add thinking indicator below strokes
    final thinkingPos = Offset(bounds.left, bounds.bottom + 15);
    final thinking = ThinkingObject(
      position: thinkingPos,
      sessionId: thread.sessionId,
    );
    setState(() {
      _objects.add(thinking);
      thread!.isWaitingForResponse = true;
    });

    // Start thinking animation
    _startThinkingAnimation(thinking);

    // Fire off the request
    _doClaudeChat(strokes, thread, thinking, bounds);
  }

  void _startThinkingAnimation(ThinkingObject thinking) {
    _thinkingAnimTimer?.cancel();
    _thinkingAnimTimer = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) {
        if (!_objects.contains(thinking)) {
          _thinkingAnimTimer?.cancel();
          return;
        }
        setState(() {
          thinking.label =
              _thinkingWords[_random.nextInt(_thinkingWords.length)];
        });
      },
    );
  }

  Future<void> _doClaudeChat(
    List<StrokeObject> strokes,
    ConversationThread thread,
    ThinkingObject thinking,
    Rect strokeBounds,
  ) async {
    try {
      // Create the response TextObject immediately — we'll fill it as deltas arrive
      final responseY = thinking.position.dy;
      final convLabel = _threadLabels[thread.sessionId];
      final responseText = TextObject(
        text: '',
        position: Offset(strokeBounds.left, responseY),
        fontSize: 20,
        conversationLabel: convLabel,
      );
      double lastHeight = 0;

      final response = await ChatService.chatStream(
        strokes,
        sessionId: thread.sessionId,
        onMetadata: (sessionId, ocrText, regions) {
          if (!mounted) return;
          setState(() {
            // Add OCR annotation above the stroke batch
            if (ocrText.isNotEmpty) {
              _objects.add(OcrAnnotationObject(
                text: ocrText,
                position: Offset(strokeBounds.left, strokeBounds.top - 18),
                maxWidth: strokeBounds.width.clamp(200, 600),
              ));
            }
            // Add bounding boxes for detected image regions
            for (final region in regions) {
              if (region.type == 'image' && region.worldBbox != null) {
                final wb = region.worldBbox!;
                _objects.add(ImageBboxObject(
                  worldRect: Rect.fromLTRB(wb[0], wb[1], wb[2], wb[3]),
                  label: 'image',
                ));
              }
            }
          });
        },
        onDelta: (delta) {
          if (!mounted) return;
          setState(() {
            // On first delta, swap thinking indicator for the response object
            if (_objects.contains(thinking)) {
              _objects.remove(thinking);
              _thinkingAnimTimer?.cancel();
              _objects.add(responseText);
            }
            responseText.text += delta;

            // Shift objects below as response grows
            final newHeight = responseText.boundingBox.height + 20;
            final heightDelta = newHeight - lastHeight;
            if (heightDelta > 0) {
              for (final obj in _objects) {
                if (obj == responseText) continue;
                if (obj.boundingBox.top > responseY - 5) {
                  obj.translate(Offset(0, heightDelta));
                }
              }
              // Compensate canvas if user is writing below
              if (_currentStroke != null &&
                  _currentStroke!.boundingBox.top > responseY - 20) {
                _offset = _offset - Offset(0, heightDelta * _scale);
              }
              lastHeight = newHeight;
            }
          });
        },
      );

      if (!mounted) return;

      DebugService.trace('claude_response', {'ocr': response.ocrText, 'response_len': response.text.length, 'session': response.sessionId});
      setState(() {
        // Ensure thinking is removed (in case no deltas arrived)
        if (_objects.contains(thinking)) {
          _objects.remove(thinking);
          _objects.add(responseText);
        }
        thread.isWaitingForResponse = false;
        responseText.sessionId = response.sessionId;
        responseText.ocrSource = response.ocrText;
        thread.sessionId = response.sessionId;
      });
      // Re-send any strokes that were queued while waiting
      if (_claudeStrokeBuffer.isNotEmpty) {
        _sendClaudeBuffer();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _objects.remove(thinking);
          thread.isWaitingForResponse = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Claude error: $e')),
        );
        // Re-send queued strokes even on error
        if (_claudeStrokeBuffer.isNotEmpty) {
          _sendClaudeBuffer();
        }
      }
    }
  }

  void _handleTap(Offset world) {
    for (final obj in _objects.reversed) {
      if (obj is TextObject && obj.ocrSource != null && obj.boundingBox.contains(world)) {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
            side: BorderSide(color: Color(0xFF1A1A1A), width: 0.5),
          ),
          builder: (_) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recognised handwriting',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6A6A6A),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  obj.ocrSource!,
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    fontStyle: FontStyle.italic,
                    color: Color(0xFF1A1A1A),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
        return;
      }
    }
  }

  Future<void> _takeScreenshot() async {
    await DebugService.sendScreenshot(_canvasRepaintKey);
    _dumpCanvas();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Screenshot sent'), duration: Duration(seconds: 1)),
      );
    }
  }

  void _dumpCanvas() {
    DebugService.sendCanvasDump(_objects.map((o) => o.toJson()).toList());
  }

  // --- Gesture handling ---

  void _handleStylusStart(Offset localPoint) {
    final world = _screenToWorld(localPoint);
    if (_activeTool == Tool.pen || _activeTool == Tool.claude) {
      // Use points captured before gesture recognizer kicked in
      final firstPoint = _pointerDownWorld ?? world;
      final points = <PointVector>[
        PointVector(firstPoint.dx, firstPoint.dy),
      ];
      for (final p in _earlyMovePoints) {
        points.add(PointVector(p.dx, p.dy));
      }
      points.add(PointVector(world.dx, world.dy));
      _pointerDownWorld = null;
      _earlyMovePoints.clear();
      setState(() {
        _currentStroke = StrokeObject(points: points);
      });
    } else if (_activeTool == Tool.select) {
      if (_selectedObjects.isNotEmpty && _selectionBoundingBox != null) {
        // Check if tapping inside selection → start move
        final padded = _selectionBoundingBox!.inflate(8.0 / _scale);
        if (padded.contains(world)) {
          _isMoving = true;
          _moveLastWorld = world;
          return;
        }
      }
      setState(() {
        _clearSelection();
        _selectionStart = world;
        _selectionRect = Rect.fromPoints(world, world);
      });
    }
  }

  void _handleStylusUpdate(Offset localPoint) {
    final world = _screenToWorld(localPoint);
    if ((_activeTool == Tool.pen || _activeTool == Tool.claude) &&
        _currentStroke != null) {
      setState(() {
        _currentStroke = StrokeObject(points: [
          ..._currentStroke!.points,
          PointVector(world.dx, world.dy),
        ]);
      });
    } else if (_activeTool == Tool.select) {
      if (_isMoving && _moveLastWorld != null) {
        final delta = world - _moveLastWorld!;
        setState(() {
          for (final obj in _selectedObjects) {
            obj.translate(delta);
          }
          _moveLastWorld = world;
        });
      } else if (_selectionStart != null) {
        setState(() {
          _selectionRect = Rect.fromPoints(_selectionStart!, world);
        });
      }
    }
  }

  bool _isPhantomStroke(StrokeObject stroke) {
    final bb = stroke.boundingBox;
    return bb.height > 0 && bb.width / bb.height > 8 && bb.width > 100;
  }

  void _handleStylusEnd() {
    if (_activeTool == Tool.pen && _currentStroke != null) {
      final stroke = _currentStroke!;
      final bb = stroke.boundingBox;
      final isPhantom = _isPhantomStroke(stroke);
      DebugService.trace('stroke_end', {
        'tool': 'pen',
        'points': stroke.points.length,
        'width': bb.width,
        'height': bb.height,
        'ratio': bb.height > 0 ? bb.width / bb.height : 0,
        'phantom': isPhantom,
        'first_pt': {'x': stroke.points.first.x, 'y': stroke.points.first.y, 'p': stroke.points.first.pressure},
        'last_pt': {'x': stroke.points.last.x, 'y': stroke.points.last.y, 'p': stroke.points.last.pressure},
      });
      setState(() {
        if (!isPhantom) {
          _objects.add(stroke);
        }
        _currentStroke = null;
      });
    } else if (_activeTool == Tool.claude && _currentStroke != null) {
      final stroke = _currentStroke!;
      setState(() => _currentStroke = null);
      DebugService.trace('claude_stroke_end', {'points': stroke.points.length});
      _onClaudeStrokeComplete(stroke);
    } else if (_activeTool == Tool.select) {
      if (_isMoving) {
        setState(() {
          _isMoving = false;
          _moveLastWorld = null;
        });
      } else if (_selectionRect != null) {
        setState(() {
          _selectObjectsInRect(_selectionRect!);
          _selectionRect = null;
          _selectionStart = null;
        });
      }
    }
  }

  void _handlePanZoomStart(Offset focalPoint) {
    _offsetAtGestureStart = _offset;
    _scaleAtGestureStart = _scale;
    _focalAtGestureStart = focalPoint;
  }

  void _handlePanZoomUpdate(Offset focalPoint, double scale) {
    if (_offsetAtGestureStart == null) return;
    setState(() {
      final newScale =
          (_scaleAtGestureStart! * scale).clamp(0.1, 10.0);
      final focalWorld =
          (_focalAtGestureStart! - _offsetAtGestureStart!) /
          _scaleAtGestureStart!;
      _scale = newScale;
      _offset = focalPoint - focalWorld * _scale;
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _thinkingAnimTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QUIRE'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 0.5),
        ),
        actions: [
          _ToolButton(
            icon: Icons.edit_outlined,
            label: 'Pen',
            selected: _activeTool == Tool.pen,
            onTap: () { DebugService.trace('tool_switch', {'tool': 'pen'}); setState(() {
              _activeTool = Tool.pen;
              _clearSelection();
            }); },
          ),
          _ToolButton(
            icon: Icons.select_all_outlined,
            label: 'Select',
            selected: _activeTool == Tool.select,
            onTap: () { DebugService.trace('tool_switch', {'tool': 'select'}); setState(() => _activeTool = Tool.select); },
          ),
          _ToolButton(
            icon: Icons.auto_awesome_outlined,
            label: 'Claude',
            selected: _activeTool == Tool.claude,
            onTap: () { DebugService.trace('tool_switch', {'tool': 'claude'}); setState(() {
              _activeTool = Tool.claude;
              _clearSelection();
            }); },
          ),
          const SizedBox(width: 12),
          Builder(builder: (context) {
            if (!SettingsService().debugMode) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.camera_alt_outlined, size: 26),
              tooltip: 'Screenshot',
              onPressed: _takeScreenshot,
            );
          }),
          IconButton(
            icon: const Icon(Icons.undo_rounded, size: 26),
            onPressed: _undo,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, size: 26),
            onPressed: _clear,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 26),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              setState(() {}); // rebuild to pick up changed settings
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          OnyxSdkPenArea(
            strokeStyle: (_activeTool == Tool.pen || _activeTool == Tool.claude)
                ? OnyxStrokeStyle.fountainPen
                : OnyxStrokeStyle.disabled,
            strokeColor: Colors.black,
            strokeWidth: 3.0,
            child: Listener(
              onPointerDown: (event) {
                final isStylus =
                    event.kind == PointerDeviceKind.stylus ||
                    event.kind == PointerDeviceKind.invertedStylus;
                if (_showWelcome && isStylus) {
                  setState(() => _showWelcome = false);
                }
                _isStylusGesture = isStylus;
                if (isStylus) {
                  _pointerDownWorld = _screenToWorld(event.localPosition);
                  _earlyMovePoints.clear();
                }
              },
              onPointerMove: (event) {
                // Capture move events before gesture recognizer kicks in
                if (_isStylusGesture && _currentStroke == null && _pointerDownWorld != null) {
                  _earlyMovePoints.add(_screenToWorld(event.localPosition));
                }
              },
              child: GestureDetector(
                onTapUp: (details) {
                  final world = _screenToWorld(details.localPosition);
                  _handleTap(world);
                },
                onScaleStart: (details) {
                  if (_isStylusGesture) {
                    _handleStylusStart(details.localFocalPoint);
                  } else {
                    _handlePanZoomStart(details.localFocalPoint);
                  }
                },
                onScaleUpdate: (details) {
                  if (_isStylusGesture) {
                    _handleStylusUpdate(details.localFocalPoint);
                  } else {
                    _handlePanZoomUpdate(
                        details.localFocalPoint, details.scale);
                  }
                },
                onScaleEnd: (_) {
                  if (_isStylusGesture) {
                    _handleStylusEnd();
                  }
                  _offsetAtGestureStart = null;
                  _scaleAtGestureStart = null;
                },
                child: RepaintBoundary(
                  key: _canvasRepaintKey,
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _CanvasPainter(
                        objects: _objects,
                        currentStroke: _currentStroke,
                        selectionRect: _selectionRect,
                        selectedObjects: _selectedObjects,
                        offset: _offset,
                        scale: _scale,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Welcome message
          if (_showWelcome)
            const Center(
              child: Text(
                'What are you\nworking on today?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A1A),
                  height: 1.4,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          // Context menu for selection
          if (_selectedObjects.isNotEmpty && _selectionBoundingBox != null)
            _buildContextMenu(),
        ],
      ),
    );
  }

  Widget _buildContextMenu() {
    final bounds = _selectionBoundingBox!;
    final bottomCenter = _worldToScreen(bounds.bottomCenter);
    return Positioned(
      left: bottomCenter.dx - 80,
      top: bottomCenter.dy + 12,
      child: Material(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: const BorderSide(color: Color(0xFF1A1A1A), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ContextAction(
              icon: Icons.text_fields,
              label: 'To Text',
              loading: _isOcrLoading,
              onTap: _isOcrLoading ? null : _ocrSelected,
            ),
            _ContextAction(
              icon: Icons.open_with,
              label: 'Move',
              onTap: () {
                setState(() => _isMoving = true);
              },
            ),
            _ContextAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              onTap: () {
                setState(() {
                  for (final obj in _selectedObjects) {
                    _objects.remove(obj);
                  }
                  _clearSelection();
                });
              },
            ),
          ],
        ),
      ),
    );
  }
}

// --- Toolbar widgets ---

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1A1A1A) : Colors.white,
          border: Border.all(
            color: const Color(0xFF1A1A1A),
            width: selected ? 1.5 : 0.75,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18,
                color: selected ? Colors.white : const Color(0xFF1A1A1A)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'serif',
                fontSize: 15,
                fontWeight: FontWeight.w400,
                letterSpacing: 0.5,
                color: selected ? Colors.white : const Color(0xFF1A1A1A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool loading;
  final VoidCallback? onTap;

  const _ContextAction({
    required this.icon,
    required this.label,
    this.loading = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Color(0xFF1A1A1A),
                ),
              )
            else
              Icon(icon, size: 18, color: const Color(0xFF1A1A1A)),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'serif',
                fontSize: 15,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Painter ---

class _CanvasPainter extends CustomPainter {
  final List<CanvasObject> objects;
  final StrokeObject? currentStroke;
  final Rect? selectionRect;
  final List<CanvasObject> selectedObjects;
  final Offset offset;
  final double scale;

  _CanvasPainter({
    required this.objects,
    this.currentStroke,
    this.selectionRect,
    required this.selectedObjects,
    required this.offset,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    final strokePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    // Draw all objects
    for (final obj in objects) {
      if (obj is StrokeObject) {
        _drawStroke(canvas, obj, strokePaint);
      } else if (obj is TextObject) {
        _drawText(canvas, obj);
      } else if (obj is ThinkingObject) {
        _drawThinking(canvas, obj);
      } else if (obj is OcrAnnotationObject) {
        _drawOcrAnnotation(canvas, obj);
      } else if (obj is ImageBboxObject) {
        _drawImageBbox(canvas, obj);
      }
    }

    // Draw current stroke in progress
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!, strokePaint);
    }

    // Draw selection rectangle
    if (selectionRect != null) {
      final selPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.1)
        ..style = PaintingStyle.fill;
      canvas.drawRect(selectionRect!, selPaint);
      final selBorder = Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale;
      canvas.drawRect(selectionRect!, selBorder);
    }

    // Draw bounding box around selected objects
    if (selectedObjects.isNotEmpty) {
      Rect bounds = selectedObjects.first.boundingBox;
      for (final obj in selectedObjects.skip(1)) {
        bounds = bounds.expandToInclude(obj.boundingBox);
      }
      final padded = bounds.inflate(8.0 / scale);
      final borderPaint = Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 / scale;
      canvas.drawRect(padded, borderPaint);
    }

    canvas.restore();
  }

  void _drawStroke(Canvas canvas, StrokeObject stroke, Paint paint) {
    if (stroke.points.isEmpty) return;

    final outlinePoints = getStroke(
      stroke.points,
      options: StrokeOptions(
        size: 2,
        thinning: 0.5,
        smoothing: 0.5,
        streamline: 0.5,
        simulatePressure: true,
      ),
    );

    if (outlinePoints.length < 2) return;

    final path = Path();
    path.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);
    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      path.quadraticBezierTo(
        p0.dx,
        p0.dy,
        (p0.dx + p1.dx) / 2,
        (p0.dy + p1.dy) / 2,
      );
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawText(Canvas canvas, TextObject obj) {
    final style = TextStyle(
      color: const Color(0xFF1A1A1A),
      fontSize: obj.fontSize,
      fontFamily: 'serif',
      fontWeight: FontWeight.w500,
      fontStyle: obj.isUserText ? FontStyle.italic : FontStyle.normal,
      height: 1.6,
      letterSpacing: 0.3,
    );
    final tp = TextPainter(
      text: TextSpan(text: obj.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 600);
    tp.paint(canvas, obj.position);

    // Conversation label tag at top-right
    if (obj.conversationLabel != null) {
      final labelStyle = TextStyle(
        color: const Color(0xFF555555),
        fontSize: 13,
        fontFamily: 'serif',
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      );
      final lp = TextPainter(
        text: TextSpan(text: obj.conversationLabel, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      lp.paint(canvas, Offset(obj.position.dx + tp.width - lp.width, obj.position.dy - lp.height - 2));
    }
  }

  void _drawOcrAnnotation(Canvas canvas, OcrAnnotationObject obj) {
    final style = TextStyle(
      color: const Color(0xFF666666),
      fontSize: 12,
      fontFamily: 'serif',
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.italic,
      height: 1.3,
      letterSpacing: 0.3,
    );
    final tp = TextPainter(
      text: TextSpan(text: obj.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: obj.maxWidth);
    tp.paint(canvas, obj.position);
  }

  void _drawImageBbox(Canvas canvas, ImageBboxObject obj) {
    final paint = Paint()
      ..color = const Color(0xFF444444)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale;
    canvas.drawRect(obj.worldRect, paint);

    if (obj.label != null) {
      final style = TextStyle(
        color: const Color(0xFF444444),
        fontSize: 12,
        fontFamily: 'serif',
        fontWeight: FontWeight.w400,
        letterSpacing: 0.3,
      );
      final tp = TextPainter(
        text: TextSpan(text: obj.label, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(obj.worldRect.left + 3, obj.worldRect.top - tp.height - 2));
    }
  }

  void _drawThinking(Canvas canvas, ThinkingObject obj) {
    // Draw star
    final starPaint = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.fill;
    final cx = obj.position.dx + 8;
    final cy = obj.position.dy + 10;
    _drawStar(canvas, cx, cy, 6, 3, starPaint);

    // Draw label
    final style = TextStyle(
      color: const Color(0xFF4A4A4A),
      fontSize: 17,
      fontFamily: 'serif',
      fontWeight: FontWeight.w500,
      fontStyle: FontStyle.italic,
      letterSpacing: 0.5,
    );
    final tp = TextPainter(
      text: TextSpan(text: '  ${obj.label}', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx + 10, obj.position.dy + 2));
  }

  void _drawStar(
      Canvas canvas, double cx, double cy, double outer, double inner, Paint paint) {
    final path = Path();
    for (int i = 0; i < 10; i++) {
      final r = i.isEven ? outer : inner;
      final angle = (i * 36 - 90) * 3.14159 / 180;
      final x = cx + r * math.cos(angle);
      final y = cy + r * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) => true;
}
