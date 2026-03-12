import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// 通知タップ時にセッション名を流すStream
  static final _tapController = StreamController<String>.broadcast();
  static Stream<String> get onTap => _tapController.stream;

  static Future<void> init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _tapController.add(payload);
        }
      },
    );
    // Android 13+ の通知パーミッション要求
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;
  }

  /// タブごとに通知を表示/更新する。
  /// [tabId] を通知IDとして使うので同じタブの通知は上書きされる。
  static Future<void> showIdle({
    required int tabId,
    required String sessionName,
    required String hostLabel,
    String lastLine = '',
  }) async {
    const channel = AndroidNotificationDetails(
      'terminal_idle',
      'Terminal Idle',
      channelDescription: 'ターミナルの出力停止通知',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
    );
    const details = NotificationDetails(android: channel);
    final body = lastLine.isNotEmpty ? lastLine : '入力待ち';
    await _plugin.show(
      id: tabId,
      title: '$hostLabel - $sessionName',
      body: body,
      notificationDetails: details,
      payload: sessionName,
    );
  }

  /// タブの通知を消す
  static Future<void> cancel(int tabId) async {
    await _plugin.cancel(id: tabId);
  }

  /// 全通知を消す
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
