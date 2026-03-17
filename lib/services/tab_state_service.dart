import 'package:shared_preferences/shared_preferences.dart';

/// タブの識別子: セッション名とウィンドウインデックスを保持
class TabIdentifier {
  final String sessionName;
  final int? windowIndex; // null = アクティブウィンドウ

  const TabIdentifier({required this.sessionName, this.windowIndex});

  /// 永続化用文字列に変換: "session" or "session:0"
  String toKey() =>
      windowIndex != null ? '$sessionName:$windowIndex' : sessionName;

  /// 永続化文字列からパース
  static TabIdentifier fromKey(String key) {
    final idx = key.lastIndexOf(':');
    if (idx < 0) return TabIdentifier(sessionName: key);
    final maybeIndex = int.tryParse(key.substring(idx + 1));
    if (maybeIndex == null) return TabIdentifier(sessionName: key);
    return TabIdentifier(
      sessionName: key.substring(0, idx),
      windowIndex: maybeIndex,
    );
  }
}

class TabStateService {
  static String _key(String hostId) => 'open_tabs_$hostId';

  static Future<List<TabIdentifier>> load(String hostId) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getStringList(_key(hostId)) ?? [];
    return keys.map(TabIdentifier.fromKey).toList();
  }

  static Future<void> save(String hostId, List<TabIdentifier> tabs) async {
    final prefs = await SharedPreferences.getInstance();
    if (tabs.isEmpty) {
      await prefs.remove(_key(hostId));
    } else {
      await prefs.setStringList(_key(hostId), tabs.map((t) => t.toKey()).toList());
    }
  }
}
