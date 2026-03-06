import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/host_config.dart';
import '../services/ssh_service.dart';

class _TerminalTab {
  final String sessionName;
  final Terminal terminal;
  SSHSession? session;
  bool connected = false;
  String? error;
  double scrollAccumulator = 0;
  bool _reconnecting = false;

  _TerminalTab({required this.sessionName})
      : terminal = Terminal(maxLines: 10000);
}

class TerminalScreen extends StatefulWidget {
  final HostConfig host;
  final String sessionName;

  const TerminalScreen({
    super.key,
    required this.host,
    required this.sessionName,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final List<_TerminalTab> _tabs = [];
  int _currentIndex = 0;
  bool _ctrlHeld = false;
  SSHClient? _sharedClient;
  _TerminalTab get _currentTab => _tabs[_currentIndex];

  @override
  void initState() {
    super.initState();
    _addTab(widget.sessionName);
  }

  Future<SSHClient> _getClient() async {
    if (_sharedClient != null) return _sharedClient!;
    final ssh = SshService();
    _sharedClient = await ssh.connect(widget.host);
    return _sharedClient!;
  }

  Future<void> _reconnectTab(_TerminalTab tab) async {
    if (tab._reconnecting) return;
    tab._reconnecting = true;
    _sharedClient?.close();
    _sharedClient = null;
    await Future.delayed(const Duration(milliseconds: 500));
    tab.error = null;
    tab.connected = false;
    if (mounted) setState(() {});
    await _connectTab(tab);
    tab._reconnecting = false;
  }

  void _addTab(String sessionName) {
    final tab = _TerminalTab(sessionName: sessionName);
    setState(() {
      _tabs.add(tab);
      _currentIndex = _tabs.length - 1;
    });
    _connectTab(tab);
  }

  Future<void> _connectTab(_TerminalTab tab) async {
    try {
      final client = await _getClient();

      tab.session = await client.shell(
        pty: SSHPtyConfig(
          width: tab.terminal.viewWidth,
          height: tab.terminal.viewHeight,
        ),
      );

      tab.session!.write(Uint8List.fromList(
        '${SshService.pathPrefix} && tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t ${tab.sessionName}\n'
            .codeUnits,
      ));

      tab.session!.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((data) {
        tab.terminal.write(data);
      });

      tab.session!.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((data) {
        tab.terminal.write(data);
      });

      tab.terminal.onOutput = (data) {
        tab.session?.write(Uint8List.fromList(utf8.encode(data)));
      };

      tab.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        tab.session?.resizeTerminal(width, height);
      };

      tab.session!.done.then((_) {
        if (mounted) {
          setState(() {
            tab.connected = false;
            tab.error = 'Connection lost';
          });
        }
      });

      setState(() => tab.connected = true);
    } catch (e) {
      setState(() => tab.error = e.toString());
    }
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    tab.session?.close();
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        Navigator.pop(context);
        return;
      }
      if (_currentIndex >= _tabs.length) {
        _currentIndex = _tabs.length - 1;
      }
    });
  }

  Future<void> _showAddTabDialog() async {
    final ssh = SshService();
    SSHClient? client;
    List<String> sessions = [];

    try {
      client = await ssh.connect(widget.host);
      final (list, _) = await ssh.listTmuxSessions(client);
      sessions = list;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      return;
    } finally {
      client?.close();
    }

    // Filter out already opened sessions
    final openNames = _tabs.map((t) => t.sessionName).toSet();
    final available = sessions.where((s) => !openNames.contains(s)).toList();

    if (!mounted) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Open session', style: TextStyle(fontSize: 18)),
          ),
          if (available.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No other sessions available'),
            ),
          ...available.map((name) => ListTile(
                leading: const Icon(Icons.terminal),
                title: Text(name),
                onTap: () => Navigator.pop(ctx, name),
              )),
          const SizedBox(height: 16),
        ],
      ),
    );

    if (selected != null) {
      _addTab(selected);
    }
  }

  void _handleScroll(_TerminalTab tab, double delta) {
    tab.scrollAccumulator += delta;
    const threshold = 20.0;
    while (tab.scrollAccumulator >= threshold) {
      tab.session?.write(Uint8List.fromList('\x1b[<65;1;1M'.codeUnits));
      tab.scrollAccumulator -= threshold;
    }
    while (tab.scrollAccumulator <= -threshold) {
      tab.session?.write(Uint8List.fromList('\x1b[<64;1;1M'.codeUnits));
      tab.scrollAccumulator += threshold;
    }
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.session?.close();
    }
    _sharedClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: _buildTabBar(),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildTabBar() {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () {
              for (final tab in _tabs) {
                tab.session?.close();
              }
              _sharedClient?.close();
              Navigator.pop(context);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, i) {
                final tab = _tabs[i];
                final selected = i == _currentIndex;
                return GestureDetector(
                  onTap: () => setState(() => _currentIndex = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tab.sessionName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => _closeTab(i),
                          child: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            onPressed: _showAddTabDialog,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
          ),
        ],
      ),
    );
  }

  void _sendKey(String seq) {
    _currentTab.session?.write(Uint8List.fromList(utf8.encode(seq)));
  }

  void _sendCtrlKey(String char) {
    final code = char.toUpperCase().codeUnitAt(0) - 0x40;
    if (code > 0 && code < 32) {
      _currentTab.session?.write(Uint8List.fromList([code]));
    }
    setState(() => _ctrlHeld = false);
  }

  Widget _buildBody() {
    final tab = _currentTab;
    if (tab.error != null) {
      if (!tab._reconnecting) {
        Future.microtask(() => _reconnectTab(tab));
      }
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('再接続中...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    if (!tab.connected) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerMove: (event) {
              _handleScroll(tab, -event.delta.dy);
            },
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _handleScroll(tab, event.scrollDelta.dy);
              }
            },
            child: TerminalView(
              tab.terminal,
              autofocus: true,
              textStyle: const TerminalStyle(
                fontFamily: 'TerminalFont',
                fontFamilyFallback: ['TerminalFontJP'],
                locale: Locale('ja', 'JP'),
              ),
            ),
          ),
        ),
        _buildAccessoryBar(),
      ],
    );
  }

  Widget _buildAccessoryBar() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _keyButton('Esc', () => _sendKey('\x1b')),
              _keyButton(
                'Ctrl',
                () => setState(() => _ctrlHeld = !_ctrlHeld),
                toggled: _ctrlHeld,
              ),
              _keyButton('Tab', () => _sendKey('\t')),
              _divider(),
              _keyButton('↑', () => _sendKey('\x1b[A')),
              _keyButton('↓', () => _sendKey('\x1b[B')),
              _keyButton('←', () => _sendKey('\x1b[D')),
              _keyButton('→', () => _sendKey('\x1b[C')),
              _divider(),
              _keyButton('Opt', () => _sendKey('\x1b')),
              _keyButton('BS', () => _sendKey('\x7f')),
              _keyButton('Enter', () => _sendKey('\r')),
              _divider(),
              _keyButton('C-a', () => _sendCtrlKey('a')),
              _keyButton('C-b', () => _sendCtrlKey('b')),
              _keyButton('C-c', () => _sendCtrlKey('c')),
              _keyButton('C-d', () => _sendCtrlKey('d')),
              _keyButton('C-z', () => _sendCtrlKey('z')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyButton(String label, VoidCallback onTap, {bool toggled = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: toggled
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            if (_ctrlHeld && label.length == 1) {
              _sendCtrlKey(label);
            } else {
              onTap();
            }
          },
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: toggled
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Theme.of(context).colorScheme.outline.withAlpha(80),
    );
  }
}
