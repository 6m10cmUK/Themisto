import 'package:dartssh2/dartssh2.dart';
import '../models/host_config.dart';

class SshService {
  static const pathPrefix =
      'export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"';

  static final _validSessionName = RegExp(r'^[a-zA-Z0-9_-]+$');

  /// セッション名がシェルインジェクションに安全かを検証し、
  /// シングルクォートで囲んだ文字列を返す。
  static String sanitizeSessionName(String name) {
    if (!_validSessionName.hasMatch(name)) {
      throw ArgumentError('不正なセッション名: $name');
    }
    return "'$name'";
  }

  Future<SSHClient> connect(HostConfig config) async {
    final socket = await SSHSocket.connect(config.host, config.port);

    if (config.authType == AuthType.key && config.privateKey != null) {
      return SSHClient(
        socket,
        username: config.username,
        identities: SSHKeyPair.fromPem(config.privateKey!),
      );
    }

    return SSHClient(
      socket,
      username: config.username,
      onPasswordRequest: () => config.password ?? '',
    );
  }

  Future<(List<String>, String)> listTmuxSessions(SSHClient client) async {
    final result = await client.run('$pathPrefix && tmux ls 2>&1 || true');
    final output = String.fromCharCodes(result).trim();
    if (output.isEmpty || output.contains('no server running') || output.contains('not found')) {
      return (<String>[], output);
    }
    final lines = output.split('\n').where((s) => s.isNotEmpty).toList();
    final sessions = lines
        .where((l) => l.contains(':'))
        .map((l) => l.split(':').first.trim())
        .toList();
    return (sessions, output);
  }

  Future<void> createSession(SSHClient client, String name) async {
    final safeName = sanitizeSessionName(name);
    await client.run('$pathPrefix && tmux new-session -d -s $safeName');
  }

  Future<void> killSession(SSHClient client, String name) async {
    final safeName = sanitizeSessionName(name);
    await client.run('$pathPrefix && tmux kill-session -t $safeName');
  }
}
