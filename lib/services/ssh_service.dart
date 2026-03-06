import 'package:dartssh2/dartssh2.dart';
import '../models/host_config.dart';

class SshService {
  Future<SSHClient> connect(HostConfig config) async {
    final client = SSHClient(
      await SSHSocket.connect(config.host, config.port),
      username: config.username,
      onPasswordRequest: () => config.password ?? '',
    );
    return client;
  }

  Future<List<String>> listTmuxSessions(SSHClient client) async {
    final result = await client.run("tmux ls -F '#{session_name}' 2>/dev/null || true");
    final output = String.fromCharCodes(result).trim();
    if (output.isEmpty) return [];
    return output.split('\n').where((s) => s.isNotEmpty).toList();
  }

  Future<void> createSession(SSHClient client, String name) async {
    await client.run('tmux new-session -d -s $name');
  }

  Future<void> killSession(SSHClient client, String name) async {
    await client.run('tmux kill-session -t $name');
  }
}
