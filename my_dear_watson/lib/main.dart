import 'package:flutter/material.dart';
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'screens/canvas_screen.dart';
import 'services/settings_service.dart';
import 'theme/eink_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OnyxSdkPenArea.init();
  await SettingsService().init();
  runApp(const QuireApp());
}

class QuireApp extends StatelessWidget {
  const QuireApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quire',
      theme: einkTheme,
      debugShowCheckedModeBanner: false,
      home: const CanvasScreen(),
    );
  }
}
