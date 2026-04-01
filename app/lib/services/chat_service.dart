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

    final body = <String, dynamic>{'strokes': payload};
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
}
