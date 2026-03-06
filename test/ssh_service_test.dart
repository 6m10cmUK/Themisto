import 'package:flutter_test/flutter_test.dart';
import 'package:themisto/services/ssh_service.dart';

void main() {
  group('SshService', () {
    test('pathPrefixにHomebrew・usr/local/binパスが含まれる', () {
      expect(SshService.pathPrefix, contains('/opt/homebrew/bin'));
      expect(SshService.pathPrefix, contains('/usr/local/bin'));
      expect(SshService.pathPrefix, contains('export PATH='));
    });

    test('listTmuxSessionsの出力パース（ロジック検証）', () {
      // listTmuxSessionsの内部ロジックを再現してテスト
      // 実際のメソッドはSSHClientが必要なので、パースロジックだけ検証

      // tmux lsの典型的な出力
      const output =
          'main: 1 windows (created Thu Jan  1 00:00:00 2026)\n'
          'dev: 2 windows (created Thu Jan  1 00:00:00 2026)\n'
          'test-session: 1 windows (created Thu Jan  1 00:00:00 2026)';

      final lines = output.split('\n').where((s) => s.isNotEmpty).toList();
      final sessions = lines
          .where((l) => l.contains(':'))
          .map((l) => l.split(':').first.trim())
          .toList();

      expect(sessions, ['main', 'dev', 'test-session']);
    });

    test('空出力のパース', () {
      const output = '';
      final isEmpty = output.isEmpty ||
          output.contains('no server running') ||
          output.contains('not found');
      expect(isEmpty, isTrue);
    });

    test('"no server running"のパース', () {
      const output = 'no server running on /tmp/tmux-501/default';
      final isEmpty = output.isEmpty ||
          output.contains('no server running') ||
          output.contains('not found');
      expect(isEmpty, isTrue);
    });

    test('"not found"のパース', () {
      const output = 'tmux: not found';
      final isEmpty = output.isEmpty ||
          output.contains('no server running') ||
          output.contains('not found');
      expect(isEmpty, isTrue);
    });
  });
}
