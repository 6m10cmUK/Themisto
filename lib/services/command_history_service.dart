import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CommandHistoryService {
  static const _storage = FlutterSecureStorage();
  static const _maxHistory = 500;

  final String hostId;
  List<String> _history = [];
  bool _loaded = false;

  CommandHistoryService({required this.hostId});

  String get _key => 'cmd_history_$hostId';

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final json = await _storage.read(key: _key);
    if (json != null) {
      _history = List<String>.from(jsonDecode(json));
    }
    _loaded = true;
  }

  Future<void> add(String command) async {
    await _ensureLoaded();
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    // Remove duplicate if exists, then add to end
    _history.remove(trimmed);
    _history.add(trimmed);
    if (_history.length > _maxHistory) {
      _history.removeRange(0, _history.length - _maxHistory);
    }
    await _storage.write(key: _key, value: jsonEncode(_history));
  }

  Future<List<String>> search(String prefix) async {
    await _ensureLoaded();
    if (prefix.isEmpty) return [];
    final results = <String>[];
    // Search from most recent
    for (var i = _history.length - 1; i >= 0; i--) {
      if (_history[i].startsWith(prefix) && _history[i] != prefix) {
        results.add(_history[i]);
        if (results.length >= 5) break;
      }
    }
    return results;
  }
}
