import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/canvas_object.dart';
import 'settings_service.dart';

class OcrService {
  static Future<String> recognize(List<StrokeObject> strokes) async {
    final settings = SettingsService();
    final url = Uri.parse('${settings.backendUrl}/ocr');

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

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['text'] as String;
    } else {
      throw Exception('OCR failed: ${response.statusCode} ${response.body}');
    }
  }
}
