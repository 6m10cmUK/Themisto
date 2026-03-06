import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host_config.dart';
import '../services/host_storage_service.dart';
import '../services/ssh_service.dart';

final hostStorageServiceProvider = Provider((ref) => HostStorageService());
final sshServiceProvider = Provider((ref) => SshService());

final hostListProvider =
    AsyncNotifierProvider<HostListNotifier, List<HostConfig>>(
        HostListNotifier.new);

class HostListNotifier extends AsyncNotifier<List<HostConfig>> {
  @override
  Future<List<HostConfig>> build() async {
    final storage = ref.read(hostStorageServiceProvider);
    return storage.getAll();
  }

  Future<void> addOrUpdate(HostConfig host) async {
    final storage = ref.read(hostStorageServiceProvider);
    await storage.save(host);
    ref.invalidateSelf();
  }

  Future<void> remove(String id) async {
    final storage = ref.read(hostStorageServiceProvider);
    await storage.delete(id);
    ref.invalidateSelf();
  }
}

final selectedHostProvider = StateProvider<HostConfig?>((ref) => null);

final tmuxSessionsProvider =
    FutureProvider.family<List<String>, HostConfig>((ref, host) async {
  final ssh = ref.read(sshServiceProvider);
  final client = await ssh.connect(host);
  try {
    return await ssh.listTmuxSessions(client);
  } finally {
    client.close();
  }
});
