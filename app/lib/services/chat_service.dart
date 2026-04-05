import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/canvas_object.dart';
import 'settings_service.dart';

class DetectedRegion {
  String type; // "text" or "image"
  final List<double>? worldBbox; // [x1, y1, x2, y2] in world coordinates
  String? content; // OCR text for text regions, mutable for user edits
  DetectedRegion({required this.type, this.worldBbox, this.content});

  Map<String, dynamic> toJson() => {
    'type': type,
    if (content != null) 'content': content,
    if (worldBbox != null) 'world_bbox': worldBbox,
  };
}

class ChatResponse {
  final String text;
  final String ocrText;
  final String sessionId;
  ChatResponse({required this.text, required this.ocrText, required this.sessionId});
}

class ChatService {
  /// Detect text vs image regions without sending to Claude.
  static Future<List<DetectedRegion>> detect(List<StrokeObject> strokes) async {
    final settings = SettingsService();
    final url = Uri.parse('${settings.backendUrl}/detect');

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (settings.backendPassword.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${settings.backendPassword}';
    }

    final payload = strokes.map((s) {
      return s.points.map((p) => {'x': p.x, 'y': p.y, 'p': p.pressure}).toList();
    }).toList();

    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode({'strokes': payload}),
    );

    if (response.statusCode != 200) {
      throw Exception('Detect failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body);
    final rawRegions = data['regions'] as List<dynamic>? ?? [];
    return rawRegions.map((r) {
      final wb = r['world_bbox'] as List<dynamic>?;
      return DetectedRegion(
        type: r['type'] as String,
        content: r['content'] as String?,
        worldBbox: wb?.map((v) => (v as num).toDouble()).toList(),
      );
    }).toList();
  }

  /// Streaming chat. Accepts optional pre-classified regions.
  static Future<ChatResponse> chatStream(
    List<StrokeObject> strokes, {
    String? sessionId,
    required void Function(String delta) onDelta,
    void Function(String sessionId, String ocrText, List<DetectedRegion> regions)? onMetadata,
    List<DetectedRegion>? regions,
  }) async {
    final settings = SettingsService();
    final url = Uri.parse('${settings.backendUrl}/chat/stream');

    final payload = strokes.map((s) {
      return s.points.map((p) => {'x': p.x, 'y': p.y, 'p': p.pressure}).toList();
    }).toList();

    final body = <String, dynamic>{
      'strokes': payload,
      'model': settings.claudeModel,
    };
    if (sessionId != null) {
      body['session_id'] = sessionId;
    }
    if (regions != null) {
      body['regions'] = regions.map((r) => r.toJson()).toList();
    }

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    if (settings.backendPassword.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${settings.backendPassword}';
    }
    request.body = jsonEncode(body);

    final client = http.Client();
    final streamedResponse = await client.send(request);

    if (streamedResponse.statusCode != 200) {
      final responseBody = await streamedResponse.stream.bytesToString();
      client.close();
      throw Exception('Chat stream failed: ${streamedResponse.statusCode} $responseBody');
    }

    String metaSessionId = sessionId ?? '';
    String ocrText = '';
    String fullText = '';

    String buffer = '';
    await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
      buffer += chunk;

      while (buffer.contains('\n\n')) {
        final pos = buffer.indexOf('\n\n');
        final block = buffer.substring(0, pos);
        buffer = buffer.substring(pos + 2);

        String eventType = '';
        String data = '';
        for (final line in block.split('\n')) {
          if (line.startsWith('event: ')) {
            eventType = line.substring(7);
          } else if (line.startsWith('data: ')) {
            data = line.substring(6);
          }
        }

        switch (eventType) {
          case 'metadata':
            final meta = jsonDecode(data);
            metaSessionId = meta['session_id'] as String;
            ocrText = meta['ocr_text'] as String;
            final rawRegions = meta['regions'] as List<dynamic>? ?? [];
            final parsedRegions = rawRegions.map((r) {
              final wb = r['world_bbox'] as List<dynamic>?;
              return DetectedRegion(
                type: r['type'] as String,
                worldBbox: wb?.map((v) => (v as num).toDouble()).toList(),
              );
            }).toList();
            onMetadata?.call(metaSessionId, ocrText, parsedRegions);
            break;
          case 'delta':
            fullText += data;
            onDelta(data);
            break;
          case 'error':
            client.close();
            throw Exception('Claude error: $data');
          case 'done':
            break;
        }
      }
    }

    client.close();
    return ChatResponse(
      text: fullText,
      ocrText: ocrText,
      sessionId: metaSessionId,
    );
  }
}
