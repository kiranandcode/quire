import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _keyAddress = 'backend_address';
  static const _keyPort = 'backend_port';
  static const _keyPassword = 'backend_password';
  static const _keyDebug = 'debug_mode';
  static const _keyModel = 'claude_model';

  static const defaultAddress = 'localhost';
  static const defaultPort = 8080;
  static const defaultModel = 'claude-sonnet-4-20250514';

  static final SettingsService _instance = SettingsService._();
  factory SettingsService() => _instance;
  SettingsService._();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String get backendAddress => _prefs?.getString(_keyAddress) ?? defaultAddress;
  int get backendPort => _prefs?.getInt(_keyPort) ?? defaultPort;
  String get backendPassword => _prefs?.getString(_keyPassword) ?? '';

  Future<void> setBackendAddress(String address) async {
    await _prefs?.setString(_keyAddress, address);
  }

  Future<void> setBackendPort(int port) async {
    await _prefs?.setInt(_keyPort, port);
  }

  Future<void> setBackendPassword(String password) async {
    await _prefs?.setString(_keyPassword, password);
  }

  bool get debugMode => _prefs?.getBool(_keyDebug) ?? false;

  Future<void> setDebugMode(bool enabled) async {
    await _prefs?.setBool(_keyDebug, enabled);
  }

  String get claudeModel => _prefs?.getString(_keyModel) ?? defaultModel;

  Future<void> setClaudeModel(String model) async {
    await _prefs?.setString(_keyModel, model);
  }

  String get backendUrl => 'http://$backendAddress:$backendPort';
}
