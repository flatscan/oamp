import 'package:shared_preferences/shared_preferences.dart';

/// Small, non-secret app settings. Credentials live in [SecureStore]
/// instead.
abstract class Preferences {
  bool? getBool(String key);
  Future<void> setBool(String key, bool value);
  List<String>? getStringList(String key);
  Future<void> setStringList(String key, List<String> value);
  String? getString(String key);
  Future<void> setString(String key, String value);
  int? getInt(String key);
  Future<void> setInt(String key, int value);
  double? getDouble(String key);
  Future<void> setDouble(String key, double value);
}

/// [Preferences] on the platform's settings store (the registry-backed
/// JSON file on Windows, NSUserDefaults on Apple, SharedPreferences on
/// Android). Loaded once at startup so reads are synchronous.
class PlatformPreferences implements Preferences {
  final SharedPreferences _prefs;
  PlatformPreferences._(this._prefs);

  static Future<PlatformPreferences> load() async =>
      PlatformPreferences._(await SharedPreferences.getInstance());

  @override
  bool? getBool(String key) => _prefs.getBool(key);

  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  @override
  List<String>? getStringList(String key) => _prefs.getStringList(key);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  @override
  String? getString(String key) => _prefs.getString(key);
  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
  @override
  int? getInt(String key) => _prefs.getInt(key);
  @override
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);
  @override
  double? getDouble(String key) => _prefs.getDouble(key);
  @override
  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);
}

/// In-memory [Preferences], for tests and as the default before startup
/// wires in the real store.
class MemoryPreferences implements Preferences {
  final Map<String, Object> _values = {};

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;

  @override
  List<String>? getStringList(String key) => _values[key] as List<String>?;

  @override
  Future<void> setStringList(String key, List<String> value) async =>
      _values[key] = List<String>.of(value);

  @override
  String? getString(String key) => _values[key] as String?;
  @override
  Future<void> setString(String key, String value) async =>
      _values[key] = value;
  @override
  int? getInt(String key) => _values[key] as int?;
  @override
  Future<void> setInt(String key, int value) async => _values[key] = value;
  @override
  double? getDouble(String key) => _values[key] as double?;
  @override
  Future<void> setDouble(String key, double value) async =>
      _values[key] = value;
}
