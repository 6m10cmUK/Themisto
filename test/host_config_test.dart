import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:themisto/models/host_config.dart';

void main() {
  group('HostConfig', () {
    group('toJson / fromJson', () {
      test('基本的なラウンドトリップ', () {
        final config = HostConfig(
          id: 'test-id-123',
          label: 'My Server',
          host: '192.168.1.1',
          port: 2222,
          username: 'admin',
          password: 'secret',
        );

        final json = config.toJson();

        expect(json['id'], 'test-id-123');
        expect(json['label'], 'My Server');
        expect(json['host'], '192.168.1.1');
        expect(json['port'], 2222);
        expect(json['username'], 'admin');
        // passwordはtoJsonに含まれない
        expect(json.containsKey('password'), isFalse);

        final restored = HostConfig.fromJson(json);
        expect(restored.id, config.id);
        expect(restored.label, config.label);
        expect(restored.host, config.host);
        expect(restored.port, config.port);
        expect(restored.username, config.username);
        expect(restored.password, isNull);
      });

      test('デフォルトポート22が使われる', () {
        final config = HostConfig(
          label: 'Test',
          host: 'example.com',
          username: 'user',
        );
        expect(config.port, 22);

        final json = config.toJson();
        final restored = HostConfig.fromJson(json);
        expect(restored.port, 22);
      });

      test('portがnullのJSONではデフォルト22になる', () {
        final json = {
          'id': 'abc',
          'label': 'Test',
          'host': 'example.com',
          'username': 'user',
          // portなし
        };
        final config = HostConfig.fromJson(json);
        expect(config.port, 22);
      });

      test('JSONエンコード/デコードのラウンドトリップ', () {
        final config = HostConfig(
          id: 'id-1',
          label: 'Server A',
          host: '10.0.0.1',
          port: 22,
          username: 'root',
        );

        final encoded = jsonEncode(config.toJson());
        final decoded = jsonDecode(encoded) as Map<String, dynamic>;
        final restored = HostConfig.fromJson(decoded);

        expect(restored.id, config.id);
        expect(restored.label, config.label);
        expect(restored.host, config.host);
        expect(restored.port, config.port);
        expect(restored.username, config.username);
      });

      test('複数ホストのリストをJSON変換できる', () {
        final hosts = [
          HostConfig(id: '1', label: 'A', host: 'a.com', username: 'u1'),
          HostConfig(id: '2', label: 'B', host: 'b.com', port: 3022, username: 'u2'),
        ];

        final encoded = jsonEncode(hosts.map((h) => h.toJson()).toList());
        final decoded = jsonDecode(encoded) as List;
        final restored = decoded
            .map((e) => HostConfig.fromJson(e as Map<String, dynamic>))
            .toList();

        expect(restored.length, 2);
        expect(restored[0].label, 'A');
        expect(restored[1].port, 3022);
      });
    });

    group('コンストラクタ', () {
      test('idを省略するとUUIDが自動生成される', () {
        final a = HostConfig(label: 'X', host: 'x.com', username: 'u');
        final b = HostConfig(label: 'Y', host: 'y.com', username: 'v');

        expect(a.id, isNotEmpty);
        expect(b.id, isNotEmpty);
        expect(a.id, isNot(equals(b.id)));
      });

      test('idを指定するとそれが使われる', () {
        final c = HostConfig(
          id: 'my-custom-id',
          label: 'Z',
          host: 'z.com',
          username: 'w',
        );
        expect(c.id, 'my-custom-id');
      });
    });

    group('copyWith', () {
      test('一部フィールドだけ変更できる', () {
        final original = HostConfig(
          id: 'orig',
          label: 'Original',
          host: 'orig.com',
          port: 22,
          username: 'user1',
          password: 'pass1',
        );

        final copied = original.copyWith(label: 'Updated', port: 3022);

        expect(copied.id, 'orig'); // idは変わらない
        expect(copied.label, 'Updated');
        expect(copied.host, 'orig.com');
        expect(copied.port, 3022);
        expect(copied.username, 'user1');
        expect(copied.password, 'pass1');
      });

      test('何も指定しなければ同じ値', () {
        final original = HostConfig(
          id: 'x',
          label: 'L',
          host: 'h.com',
          port: 44,
          username: 'u',
          password: 'p',
        );

        final copied = original.copyWith();

        expect(copied.id, original.id);
        expect(copied.label, original.label);
        expect(copied.host, original.host);
        expect(copied.port, original.port);
        expect(copied.username, original.username);
        expect(copied.password, original.password);
      });

      test('passwordを変更できる', () {
        final original = HostConfig(
          id: 'x',
          label: 'L',
          host: 'h.com',
          username: 'u',
        );
        expect(original.password, isNull);

        final copied = original.copyWith(password: 'newpass');
        expect(copied.password, 'newpass');
      });
    });
  });
}
