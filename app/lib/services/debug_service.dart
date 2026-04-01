import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class DebugService {
  static Future<void> trace(String event, [Map<String, dynamic>? data]) async {
    final settings = SettingsService();
    if (!settings.debugMode) return;

    try {
      await http.post(
        Uri.parse('${settings.backendUrl}/debug'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'event': event,
          'ts': DateTime.now().toIso8601String(),
          if (data != null) ...data,
        }),
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Screenshot always sends regardless of debug mode.
  static Future<void> sendScreenshot(GlobalKey canvasKey) async {
    final settings = SettingsService();

    try {
      final boundary = canvasKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      await http.post(
        Uri.parse('${settings.backendUrl}/screenshot'),
        headers: {'Content-Type': 'image/png'},
        body: byteData.buffer.asUint8List(),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Canvas dump always sends regardless of debug mode.
  static Future<void> sendCanvasDump(List<Map<String, dynamic>> objects) async {
    final settings = SettingsService();

    try {
      await http.post(
        Uri.parse('${settings.backendUrl}/canvas-dump'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'objects': objects, 'ts': DateTime.now().toIso8601String()}),
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
