import 'package:dartssh2/dartssh2.dart';
import '../models/host_config.dart';
import '../models/tmux_window.dart';

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

  Future<List<TmuxWindow>> listTmuxWindows(SSHClient client, String sessionName) async {
    final safe = sanitizeSessionName(sessionName);
    try {
      final result = await client.run(
        '$pathPrefix && tmux list-windows -t $safe -F "#{window_index}|#{window_name}|#{window_active}" 2>&1',
      );
      final output = String.fromCharCodes(result).trim();
      if (output.isEmpty || output.startsWith('can\'t find') || output.startsWith('no server')) {
        return [];
      }
      return output
          .split('\n')
          .where((l) => l.contains('|'))
          .map((l) {
            final parts = l.split('|');
            if (parts.length < 3) return null;
            final index = int.tryParse(parts[0]);
            if (index == null) return null;
            return TmuxWindow(
              sessionName: sessionName,
              index: index,
              name: parts[1],
              isActive: parts[2].trim() == '1',
            );
          })
          .whereType<TmuxWindow>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> createTmuxWindow(SSHClient client, String sessionName) async {
    final safe = sanitizeSessionName(sessionName);
    await client.run('$pathPrefix && tmux new-window -t $safe');
  }

  Future<void> killTmuxWindow(SSHClient client, String sessionName, int windowIndex) async {
    final safe = sanitizeSessionName(sessionName);
    await client.run('$pathPrefix && tmux kill-window -t $safe:$windowIndex');
  }
}
