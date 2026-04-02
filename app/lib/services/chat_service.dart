import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/canvas_object.dart';
import 'settings_service.dart';

class ChatResponse {
  final String text;
  final String ocrText;
  final String sessionId;
  ChatResponse({required this.text, required this.ocrText, required this.sessionId});
}

class ChatService {
  /// Non-streaming chat (kept as fallback).
  static Future<ChatResponse> chat(
    List<StrokeObject> strokes, {
    String? sessionId,
  }) async {
    final settings = SettingsService();
    final url = Uri.parse('${settings.backendUrl}/chat');

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (settings.backendPassword.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${settings.backendPassword}';
    }

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

    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return ChatResponse(
        text: data['text'] as String,
        ocrText: data['ocr_text'] as String,
        sessionId: data['session_id'] as String,
      );
    } else {
      throw Exception('Chat failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Streaming chat. Calls onDelta for each text chunk, onMetadata once
  /// with session_id/ocr_text, and returns the full ChatResponse when done.
  static Future<ChatResponse> chatStream(
    List<StrokeObject> strokes, {
    String? sessionId,
    required void Function(String delta) onDelta,
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

    // Parse SSE events from the byte stream
    String buffer = '';
    await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
      buffer += chunk;

      // Process complete SSE event blocks (separated by \n\n)
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
