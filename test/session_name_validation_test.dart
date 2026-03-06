import 'package:flutter_test/flutter_test.dart';

/// terminal_screen.dart内の _kSessionNamePattern と同じ正規表現。
/// プライベート定数なので直接importできないため、同じパターンを再定義してテストする。
final _kSessionNamePattern = RegExp(r'^[a-zA-Z0-9_-]+$');

void main() {
  group('セッション名バリデーション (_kSessionNamePattern)', () {
    group('有効なセッション名', () {
      final validNames = [
        'main',
        'my-session',
        'my_session',
        'Session1',
        'a',
        '0',
        'abc-123_DEF',
        'A_B-C',
        '---',
        '___',
        'abcdefghijklmnopqrstuvwxyz',
        'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
        '0123456789',
      ];

      for (final name in validNames) {
        test('"$name" は有効', () {
          expect(_kSessionNamePattern.hasMatch(name), isTrue);
        });
      }
    });

    group('無効なセッション名', () {
      final invalidNames = [
        '',           // 空文字
        'hello world', // スペース
        'a b',
        'foo.bar',    // ドット
        'foo/bar',    // スラッシュ
        'foo:bar',    // コロン
        'foo@bar',    // @
        'あいう',      // 日本語
        'foo\nbar',   // 改行
        'foo\tbar',   // タブ
        r'foo$bar',   // ドル記号
        'foo;bar',    // セミコロン（コマンドインジェクション防止）
        'foo|bar',    // パイプ
        'foo&bar',    // アンパサンド
        'foo`bar',    // バッククォート
      ];

      for (final name in invalidNames) {
        test('"${name.replaceAll('\n', '\\n').replaceAll('\t', '\\t')}" は無効', () {
          expect(_kSessionNamePattern.hasMatch(name), isFalse);
        });
      }
    });
  });
}
