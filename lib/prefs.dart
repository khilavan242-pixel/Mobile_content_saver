import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Tiny settings store kept in one JSON file inside the app's private folder.
/// Same calls as the shared_preferences plugin (which crashed on some builds),
/// so the rest of the app did not need to change.
class SharedPreferences {
  SharedPreferences._(this._file, this._data);

  final File? _file;
  final Map<String, dynamic> _data;
  static SharedPreferences? _instance;

  static Future<SharedPreferences> getInstance() async {
    final cached = _instance;
    if (cached != null) return cached;
    File? file;
    Map<String, dynamic> data = {};
    try {
      final dir = await getApplicationSupportDirectory();
      file = File('${dir.path}/tubebox_settings.json');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) data = decoded;
      }
    } catch (_) {}
    return _instance = SharedPreferences._(file, data);
  }

  Future<void> _save() async {
    try {
      await _file?.writeAsString(jsonEncode(_data), flush: true);
    } catch (_) {}
  }

  String? getString(String k) => _data[k] is String ? _data[k] as String : null;
  bool? getBool(String k) => _data[k] is bool ? _data[k] as bool : null;
  int? getInt(String k) => _data[k] is int ? _data[k] as int : null;
  double? getDouble(String k) => _data[k] is num ? (_data[k] as num).toDouble() : null;
  List<String>? getStringList(String k) => _data[k] is List ? (_data[k] as List).map((e) => e.toString()).toList() : null;
  bool containsKey(String k) => _data.containsKey(k);
  Set<String> getKeys() => _data.keys.toSet();

  Future<bool> _put(String k, dynamic v) async {
    _data[k] = v;
    await _save();
    return true;
  }

  Future<bool> setString(String k, String v) => _put(k, v);
  Future<bool> setBool(String k, bool v) => _put(k, v);
  Future<bool> setInt(String k, int v) => _put(k, v);
  Future<bool> setDouble(String k, double v) => _put(k, v);
  Future<bool> setStringList(String k, List<String> v) => _put(k, List<String>.from(v));

  Future<bool> remove(String k) async {
    _data.remove(k);
    await _save();
    return true;
  }
}
