import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import 'host_edit_screen.dart';
import 'session_list_screen.dart';
import 'terminal_screen.dart';

class HostListScreen extends ConsumerWidget {
  const HostListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostsAsync = ref.watch(hostListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Themisto - Hosts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const HostEditScreen()),
        ),
        child: const Icon(Icons.add),
      ),
      body: hostsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (hosts) {
          if (hosts.isEmpty) {
            return const Center(child: Text('No hosts configured.\nTap + to add one.'));
          }
          return ListView.builder(
            itemCount: hosts.length,
            itemBuilder: (context, i) {
              final host = hosts[i];
              return ListTile(
                title: Text(host.label),
                subtitle: Text('${host.username}@${host.host}:${host.port}'),
                onTap: () {
                  final isDesktop =
                      defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => isDesktop
                          ? TerminalScreen(host: host)
                          : SessionListScreen(host: host),
                    ),
                  );
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => HostEditScreen(host: host),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Delete host?'),
                            content: Text('Delete "${host.label}"?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          ref.read(hostListProvider.notifier).remove(host.id);
                        }
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
