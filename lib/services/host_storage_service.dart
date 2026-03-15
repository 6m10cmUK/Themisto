import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/host_config.dart';

class HostStorageService {
  static const _hostsKey = 'hosts';
  final FlutterSecureStorage _storage;

  HostStorageService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<List<HostConfig>> getAll() async {
    try {
      final raw = await _storage.read(key: _hostsKey);
      if (raw == null) return [];
      final list = jsonDecode(raw) as List;
      final hosts =
          list.map((e) => HostConfig.fromJson(e as Map<String, dynamic>)).toList();
      for (final h in hosts) {
        h.password = await _storage.read(key: 'password_${h.id}');
        h.privateKey = await _storage.read(key: 'privateKey_${h.id}');
      }
      return hosts;
    } catch (_) {
      // 署名変更や再インストール後の復号エラー → ストレージをリセット
      await _storage.deleteAll();
      return [];
    }
  }

  Future<void> save(HostConfig host) async {
    final hosts = await getAll();
    final idx = hosts.indexWhere((h) => h.id == host.id);
    if (idx >= 0) {
      hosts[idx] = host;
    } else {
      hosts.add(host);
    }
    await _storage.write(
      key: _hostsKey,
      value: jsonEncode(hosts.map((h) => h.toJson()).toList()),
    );
    if (host.password != null) {
      await _storage.write(key: 'password_${host.id}', value: host.password!);
    }
    if (host.privateKey != null) {
      await _storage.write(key: 'privateKey_${host.id}', value: host.privateKey!);
    }
  }

  Future<void> delete(String id) async {
    final hosts = await getAll();
    hosts.removeWhere((h) => h.id == id);
    await _storage.write(
      key: _hostsKey,
      value: jsonEncode(hosts.map((h) => h.toJson()).toList()),
    );
    await _storage.delete(key: 'password_$id');
    await _storage.delete(key: 'privateKey_$id');
  }
}
