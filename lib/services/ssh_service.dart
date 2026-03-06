import 'package:dartssh2/dartssh2.dart';
import '../models/host_config.dart';

class SshService {
  static const pathPrefix =
      'export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"';

  Future<SSHClient> connect(HostConfig config) async {
    final client = SSHClient(
      await SSHSocket.connect(config.host, config.port),
      username: config.username,
      onPasswordRequest: () => config.password ?? '',
    );
    return client;
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
    await client.run('$pathPrefix && tmux new-session -d -s $name');
  }

  Future<void> killSession(SSHClient client, String name) async {
    await client.run('$pathPrefix && tmux kill-session -t $name');
  }
}
