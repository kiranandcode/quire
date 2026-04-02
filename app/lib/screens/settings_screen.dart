import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import 'calibration_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _addressController;
  late TextEditingController _portController;
  late TextEditingController _passwordController;
  final _settings = SettingsService();
  late String _selectedModel;

  @override
  void initState() {
    super.initState();
    _addressController =
        TextEditingController(text: _settings.backendAddress);
    _portController =
        TextEditingController(text: _settings.backendPort.toString());
    _passwordController =
        TextEditingController(text: _settings.backendPassword);
    _selectedModel = _settings.claudeModel;
  }

  @override
  void dispose() {
    _addressController.dispose();
    _portController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_portController.text);
    final address = _addressController.text.trim();
    if (port == null || port <= 0 || port > 65535 || address.isEmpty) return;

    _settings.setBackendAddress(address);
    _settings.setBackendPort(port);
    _settings.setBackendPassword(_passwordController.text);
    _settings.setClaudeModel(_selectedModel);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 2, color: Colors.black),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Backend Server',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: 'localhost',
              ),
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8080',
              ),
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                hintText: 'Optional',
              ),
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'For local dev: use localhost + adb reverse tcp:<port> tcp:<port>',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Switch(
                  value: _settings.debugMode,
                  activeThumbColor: Colors.black,
                  onChanged: (v) {
                    setState(() => _settings.setDebugMode(v));
                  },
                ),
                const SizedBox(width: 8),
                const Text('Debug mode', style: TextStyle(fontSize: 18)),
              ],
            ),
            Text(
              'Streams trace events to server for logging',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            const Text(
              'Claude Model',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _selectedModel,
              decoration: const InputDecoration(
                labelText: 'Model',
              ),
              style: const TextStyle(fontSize: 18, color: Colors.black),
              items: const [
                DropdownMenuItem(value: 'claude-sonnet-4-20250514', child: Text('Sonnet 4')),
                DropdownMenuItem(value: 'claude-opus-4-20250514', child: Text('Opus 4')),
                DropdownMenuItem(value: 'claude-haiku-4-20250414', child: Text('Haiku 4')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _selectedModel = v);
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CalibrationScreen()),
              ),
              child: const Text('OCR Calibration'),
            ),
          ],
        ),
      ),
    );
  }
}
