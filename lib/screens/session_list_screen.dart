import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host_config.dart';
import '../providers/providers.dart';
import 'terminal_screen.dart';

class SessionListScreen extends ConsumerStatefulWidget {
  final HostConfig host;
  const SessionListScreen({super.key, required this.host});

  @override
  ConsumerState<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends ConsumerState<SessionListScreen> {
  List<String>? _sessions;
  String? _rawOutput;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ssh = ref.read(sshServiceProvider);
      final client = await ssh.connect(widget.host);
      try {
        final (sessions, raw) = await ssh.listTmuxSessions(client);
        setState(() {
          _sessions = sessions;
          _rawOutput = raw;
          _loading = false;
        });
      } finally {
        client.close();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _createSession() async {
    final name = await _showNameDialog();
    if (name == null || name.isEmpty) return;
    try {
      final ssh = ref.read(sshServiceProvider);
      final client = await ssh.connect(widget.host);
      try {
        await ssh.createSession(client, name);
      } finally {
        client.close();
      }
      _loadSessions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _killSession(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kill session?'),
        content: Text('Kill "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kill'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final ssh = ref.read(sshServiceProvider);
      final client = await ssh.connect(widget.host);
      try {
        await ssh.killSession(client, name);
      } finally {
        client.close();
      }
      _loadSessions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<String?> _showNameDialog() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New tmux session'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Session name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sessions - ${widget.host.label}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSessions,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createSession,
        child: const Icon(Icons.add),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Error: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadSessions, child: const Text('Retry')),
          ],
        ),
      );
    }
    final sessions = _sessions ?? [];
    if (sessions.isEmpty) {
      return Center(child: Text('No tmux sessions.\n\nDebug output:\n${_rawOutput ?? "empty"}'));
    }
    return ListView.builder(
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final name = sessions[i];
        return ListTile(
          title: Text(name),
          leading: const Icon(Icons.terminal),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TerminalScreen(
                host: widget.host,
                sessionName: name,
              ),
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _killSession(name),
          ),
        );
      },
    );
  }
}
