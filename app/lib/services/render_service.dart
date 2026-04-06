import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class RenderService {
  /// Render LaTeX content to PNG bytes via server-side pdflatex.
  static Future<Uint8List> renderLatex(String content) async {
    return _render('latex', content);
  }

  /// Render SVG content to PNG bytes via server-side rsvg-convert.
  static Future<Uint8List> renderSvg(String content) async {
    return _render('svg', content);
  }

  static Future<Uint8List> _render(String type, String content) async {
    final settings = SettingsService();
    final url = Uri.parse('${settings.backendUrl}/render');

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (settings.backendPassword.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${settings.backendPassword}';
    }

    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode({'type': type, 'content': content}),
    );

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception('Render failed: ${response.statusCode} ${response.body}');
    }
  }
}
