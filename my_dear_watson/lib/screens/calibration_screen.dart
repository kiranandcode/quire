import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show PointerDeviceKind, Image, ImageByteFormat, PictureRecorder;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import '../models/canvas_object.dart';
import '../services/ocr_service.dart';

/// Temporary calibration screen for OCR data collection.
/// Write text → OCR → edit correction → save image+text pair.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final List<StrokeObject> _strokes = [];
  StrokeObject? _currentStroke;
  final TextEditingController _correctionController = TextEditingController();
  final GlobalKey _canvasKey = GlobalKey();

  bool _isStylusGesture = false;
  bool _isOcrLoading = false;
  String _ocrResult = '';
  int _savedCount = 0;
  Offset? _pointerDownPos;
  final List<Offset> _earlyPoints = [];

  Timer? _debounceTimer;
  static const _debounceMs = 2000;

  @override
  void dispose() {
    _correctionController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onStrokeComplete(StrokeObject stroke) {
    setState(() {
      _strokes.add(stroke);
    });
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      Duration(milliseconds: _debounceMs),
      _runOcr,
    );
  }

  Future<void> _runOcr() async {
    if (_strokes.isEmpty) return;
    setState(() => _isOcrLoading = true);
    try {
      final text = await OcrService.recognize(_strokes);
      setState(() {
        _ocrResult = text;
        _correctionController.text = text;
      });
    } catch (e) {
      setState(() {
        _ocrResult = 'Error: $e';
        _correctionController.text = '';
      });
    } finally {
      setState(() => _isOcrLoading = false);
    }
  }

  Future<void> _save() async {
    if (_strokes.isEmpty) return;

    final correctedText = _correctionController.text.trim();
    if (correctedText.isEmpty) return;

    // Render strokes to image
    final image = await _renderStrokesToImage();
    if (image == null) return;

    // Save to device
    final dir = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${dir.path}/ocr_calibration');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final imgFile = File('${dataDir.path}/$timestamp.png');
    final txtFile = File('${dataDir.path}/$timestamp.txt');

    // Encode image to PNG bytes
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await imgFile.writeAsBytes(byteData.buffer.asUint8List());
      await txtFile.writeAsString(correctedText);

      setState(() {
        _savedCount++;
        _strokes.clear();
        _currentStroke = null;
        _ocrResult = '';
        _correctionController.clear();
      });
    }
  }

  Future<ui.Image?> _renderStrokesToImage() async {
    if (_strokes.isEmpty) return null;

    // Find bounding box
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final s in _strokes) {
      final b = s.boundingBox;
      if (b.left < minX) minX = b.left;
      if (b.top < minY) minY = b.top;
      if (b.right > maxX) maxX = b.right;
      if (b.bottom > maxY) maxY = b.bottom;
    }

    const pad = 40.0;
    final w = (maxX - minX + 2 * pad).ceil();
    final h = (maxY - minY + 2 * pad).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));

    // White background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Colors.white,
    );

    // Draw strokes
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    canvas.translate(-minX + pad, -minY + pad);

    for (final stroke in _strokes) {
      final outlinePoints = getStroke(
        stroke.points,
        options: StrokeOptions(
          size: 3,
          thinning: 0.5,
          smoothing: 0.5,
          streamline: 0.5,
          simulatePressure: true,
        ),
      );
      if (outlinePoints.length < 2) continue;
      final path = Path();
      path.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);
      for (int i = 1; i < outlinePoints.length - 1; i++) {
        final p0 = outlinePoints[i];
        final p1 = outlinePoints[i + 1];
        path.quadraticBezierTo(p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      }
      path.close();
      canvas.drawPath(path, paint);
    }

    final picture = recorder.endRecording();
    return picture.toImage(w, h);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('OCR Calibration  [$_savedCount saved]'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 26),
            onPressed: () => setState(() {
              _strokes.clear();
              _currentStroke = null;
              _ocrResult = '';
              _correctionController.clear();
            }),
          ),
        ],
      ),
      body: Row(
        children: [
          // Left: drawing area
          Expanded(
            flex: 3,
            child: Listener(
              onPointerDown: (event) {
                _isStylusGesture =
                    event.kind == ui.PointerDeviceKind.stylus ||
                    event.kind == ui.PointerDeviceKind.invertedStylus;
                if (_isStylusGesture) {
                  _pointerDownPos = event.localPosition;
                  _earlyPoints.clear();
                }
              },
              onPointerMove: (event) {
                if (_isStylusGesture && _currentStroke == null && _pointerDownPos != null) {
                  _earlyPoints.add(event.localPosition);
                }
              },
              child: GestureDetector(
                onScaleStart: (details) {
                  if (!_isStylusGesture) return;
                  final first = _pointerDownPos ?? details.localFocalPoint;
                  final points = <PointVector>[PointVector(first.dx, first.dy)];
                  for (final p in _earlyPoints) {
                    points.add(PointVector(p.dx, p.dy));
                  }
                  points.add(PointVector(details.localFocalPoint.dx, details.localFocalPoint.dy));
                  _pointerDownPos = null;
                  _earlyPoints.clear();
                  setState(() {
                    _currentStroke = StrokeObject(points: points);
                  });
                },
                onScaleUpdate: (details) {
                  if (!_isStylusGesture || _currentStroke == null) return;
                  setState(() {
                    _currentStroke = StrokeObject(points: [
                      ..._currentStroke!.points,
                      PointVector(details.localFocalPoint.dx, details.localFocalPoint.dy),
                    ]);
                  });
                },
                onScaleEnd: (_) {
                  if (!_isStylusGesture || _currentStroke == null) return;
                  _onStrokeComplete(_currentStroke!);
                  setState(() => _currentStroke = null);
                },
                child: RepaintBoundary(
                  key: _canvasKey,
                  child: CustomPaint(
                    painter: _CalibrationPainter(
                      strokes: _strokes,
                      currentStroke: _currentStroke,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
          // Divider
          Container(width: 1, color: const Color(0xFF1A1A1A)),
          // Right: OCR result + correction
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'OCR Result',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 14,
                      color: Color(0xFF6A6A6A),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_isOcrLoading)
                    const Text(
                      'recognising...',
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 18,
                        fontStyle: FontStyle.italic,
                        color: Color(0xFF6A6A6A),
                      ),
                    )
                  else
                    Text(
                      _ocrResult.isEmpty ? 'Write something on the left' : _ocrResult,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: _ocrResult.isEmpty
                            ? const Color(0xFF9A9A9A)
                            : const Color(0xFF1A1A1A),
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text(
                    'Correction',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 14,
                      color: Color(0xFF6A6A6A),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _correctionController,
                    maxLines: 4,
                    style: const TextStyle(
                      fontFamily: 'serif',
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Edit the correct text here',
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: (_strokes.isNotEmpty && !_isOcrLoading)
                        ? _save
                        : null,
                    child: const Text('Save & Next'),
                  ),
                  const Spacer(),
                  Text(
                    '$_savedCount samples collected',
                    style: const TextStyle(
                      fontFamily: 'serif',
                      fontSize: 16,
                      color: Color(0xFF6A6A6A),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalibrationPainter extends CustomPainter {
  final List<StrokeObject> strokes;
  final StrokeObject? currentStroke;

  _CalibrationPainter({required this.strokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    for (final stroke in strokes) {
      _drawStroke(canvas, stroke, paint);
    }
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!, paint);
    }
  }

  void _drawStroke(Canvas canvas, StrokeObject stroke, Paint paint) {
    if (stroke.points.isEmpty) return;
    final outlinePoints = getStroke(
      stroke.points,
      options: StrokeOptions(
        size: 3,
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
      path.quadraticBezierTo(p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CalibrationPainter oldDelegate) => true;
}
