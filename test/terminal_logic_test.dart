import 'package:flutter_test/flutter_test.dart';

/// terminal_screen.dart のロジックテスト
/// プライベートクラス・メソッドは直接テストできないため、
/// 同等のロジックを再現してテストする。

void main() {
  group('リトライロジック', () {
    // _reconnectTab のリトライカウント・backoff ロジックを再現
    int retryCount = 0;
    const maxRetries = 5;

    setUp(() {
      retryCount = 0;
    });

    test('リトライ回数が上限を超えたらエラー', () {
      retryCount = 6;
      final shouldStop = retryCount > maxRetries;
      expect(shouldStop, isTrue);
    });

    test('リトライ回数が上限以内なら継続', () {
      for (var i = 1; i <= maxRetries; i++) {
        retryCount = i;
        final shouldStop = retryCount > maxRetries;
        expect(shouldStop, isFalse, reason: 'リトライ $i 回目で停止してはいけない');
      }
    });

    test('backoffは_retryCount秒（最大5秒）', () {
      for (var i = 1; i <= 10; i++) {
        final backoff = i.clamp(1, 5);
        expect(backoff, lessThanOrEqualTo(5));
        expect(backoff, greaterThanOrEqualTo(1));
      }
      expect(1.clamp(1, 5), 1);
      expect(3.clamp(1, 5), 3);
      expect(5.clamp(1, 5), 5);
      expect(7.clamp(1, 5), 5);
    });

    test('接続成功時のみリトライカウントがリセットされる', () {
      int resetIfConnected(int count, bool connected) =>
          connected ? 0 : count;

      expect(resetIfConnected(3, true), 0);
      expect(resetIfConnected(3, false), 3);
      expect(resetIfConnected(5, true), 0);
      expect(resetIfConnected(1, false), 1);
    });
  });

  group('タブインデックス管理', () {
    // _closeTab のインデックス調整ロジックを再現
    int currentIndex = 0;
    List<String> tabs = [];

    setUp(() {
      tabs = ['A', 'B', 'C', 'D'];
      currentIndex = 0;
    });

    void closeTab(int index) {
      if (index < 0 || index >= tabs.length) return;
      tabs.removeAt(index);
      if (index < currentIndex) {
        currentIndex--;
      } else if (currentIndex >= tabs.length) {
        currentIndex = tabs.isEmpty ? 0 : tabs.length - 1;
      }
    }

    test('現在のタブより左のタブを閉じるとインデックスがデクリメントされる', () {
      currentIndex = 2; // 'C'を選択中
      closeTab(0); // 'A'を閉じる
      expect(tabs, ['B', 'C', 'D']);
      expect(currentIndex, 1); // 'C'のまま
    });

    test('現在のタブより右のタブを閉じてもインデックスは変わらない', () {
      currentIndex = 1; // 'B'を選択中
      closeTab(3); // 'D'を閉じる
      expect(tabs, ['A', 'B', 'C']);
      expect(currentIndex, 1); // 'B'のまま
    });

    test('現在のタブ自身を閉じると末尾にクランプされる', () {
      currentIndex = 3; // 'D'を選択中（最後）
      closeTab(3); // 'D'を閉じる
      expect(tabs, ['A', 'B', 'C']);
      expect(currentIndex, 2); // 末尾にクランプ
    });

    test('現在のタブ自身を閉じる（中間）', () {
      currentIndex = 2; // 'C'を選択中
      closeTab(2); // 'C'を閉じる
      expect(tabs, ['A', 'B', 'D']);
      expect(currentIndex, 2); // 'D'が選択される
    });

    test('最後の1つを閉じると空になる', () {
      tabs = ['A'];
      currentIndex = 0;
      closeTab(0);
      expect(tabs, isEmpty);
      expect(currentIndex, 0);
    });

    test('連続で左のタブを閉じてもインデックスが正しい', () {
      currentIndex = 3; // 'D'を選択中
      closeTab(0); // 'A'を閉じる → ['B','C','D'], index=2
      expect(currentIndex, 2);
      closeTab(0); // 'B'を閉じる → ['C','D'], index=1
      expect(currentIndex, 1);
      closeTab(0); // 'C'を閉じる → ['D'], index=0
      expect(currentIndex, 0);
      expect(tabs, ['D']);
    });

    test('範囲外のインデックスでは何も起きない', () {
      currentIndex = 1;
      closeTab(-1);
      expect(tabs.length, 4);
      closeTab(10);
      expect(tabs.length, 4);
      expect(currentIndex, 1);
    });
  });

  group('スクロールロジック', () {
    // _handleScroll のロジックを再現
    const kScrollThreshold = 20.0;
    const kSgrMouseUp = '\x1b[<65;1;1M';
    const kSgrMouseDown = '\x1b[<64;1;1M';

    test('閾値未満のスクロールではイベントが送られない', () {
      double accumulator = 0;
      final events = <String>[];

      accumulator += 10.0; // 閾値未満
      while (accumulator >= kScrollThreshold) {
        events.add(kSgrMouseUp);
        accumulator -= kScrollThreshold;
      }
      while (accumulator <= -kScrollThreshold) {
        events.add(kSgrMouseDown);
        accumulator += kScrollThreshold;
      }

      expect(events, isEmpty);
      expect(accumulator, 10.0);
    });

    test('閾値以上のスクロールでイベントが送られる', () {
      double accumulator = 0;
      final events = <String>[];

      accumulator += 25.0;
      while (accumulator >= kScrollThreshold) {
        events.add(kSgrMouseUp);
        accumulator -= kScrollThreshold;
      }

      expect(events.length, 1);
      expect(events[0], kSgrMouseUp);
      expect(accumulator, 5.0);
    });

    test('大きなスクロールで複数イベントが送られる', () {
      double accumulator = 0;
      final events = <String>[];

      accumulator += 65.0;
      while (accumulator >= kScrollThreshold) {
        events.add(kSgrMouseUp);
        accumulator -= kScrollThreshold;
      }

      expect(events.length, 3);
      expect(accumulator, 5.0);
    });

    test('逆方向スクロール', () {
      double accumulator = 0;
      final events = <String>[];

      accumulator -= 45.0;
      while (accumulator <= -kScrollThreshold) {
        events.add(kSgrMouseDown);
        accumulator += kScrollThreshold;
      }

      expect(events.length, 2);
      expect(events.every((e) => e == kSgrMouseDown), isTrue);
      expect(accumulator, -5.0);
    });

    test('蓄積がリセットされる', () {
      double accumulator = 15.0;
      accumulator = 0;
      expect(accumulator, 0);
    });
  });

  group('ポインタ移動判定', () {
    const kMinDistance = 5.0;

    test('移動距離が閾値未満ならスクロールしない', () {
      final dy = 3.0;
      final shouldScroll = dy.abs() >= kMinDistance;
      expect(shouldScroll, isFalse);
    });

    test('移動距離が閾値以上ならスクロールする', () {
      final dy = 6.0;
      final shouldScroll = dy.abs() >= kMinDistance;
      expect(shouldScroll, isTrue);
    });

    test('横方向の移動が大きい場合はスクロールしない', () {
      final dx = 10.0;
      final dy = 6.0;
      final shouldScroll = dy.abs() >= kMinDistance && dx.abs() <= dy.abs();
      expect(shouldScroll, isFalse);
    });

    test('縦方向の移動が大きい場合はスクロールする', () {
      final dx = 3.0;
      final dy = 10.0;
      final shouldScroll = dy.abs() >= kMinDistance && dx.abs() <= dy.abs();
      expect(shouldScroll, isTrue);
    });
  });
}
