import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/host_config.dart';
import '../services/ssh_service.dart';
import '../widgets/split_view.dart';

final _isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

const _kScrollThreshold = 20.0;
const _kSgrMouseUp = '\x1b[<65;1;1M';
const _kSgrMouseDown = '\x1b[<64;1;1M';
const _kMaxLines = 10000;
final _kSessionNamePattern = RegExp(r'^[a-zA-Z0-9_-]+$');
const _kPointerMoveMinDistance = 5.0;

class _TerminalTab {
  final String sessionName;
  final Terminal terminal;
  final TerminalController controller;
  SSHSession? session;
  bool connected = false;
  String? error;
  double scrollAccumulator = 0;
  bool _reconnecting = false;
  int _retryCount = 0;
  List<StreamSubscription> subscriptions = [];
  Offset? _lastPointerPosition;

  _TerminalTab({required this.sessionName})
      : terminal = Terminal(maxLines: _kMaxLines),
        controller = TerminalController();
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

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  final List<_TerminalTab> _tabs = [];
  int _currentIndex = 0;
  bool _ctrlHeld = false;
  SSHClient? _sharedClient;
  Completer<SSHClient>? _connectingClient;
  SplitViewController? _splitController;
  _TerminalTab get _currentTab => _tabs[_currentIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _addTab(widget.sessionName);
  }

  Future<void> _enableBackground() async {
    const config = FlutterBackgroundAndroidConfig(
      notificationTitle: 'Themisto',
      notificationText: 'SSH接続中',
      notificationImportance: AndroidNotificationImportance.normal,
    );
    final initialized = await FlutterBackground.initialize(androidConfig: config);
    if (initialized) {
      await FlutterBackground.enableBackgroundExecution();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // アプリがフォアグラウンドに戻った時、切断されたタブを再接続
      for (final tab in _tabs) {
        if (!tab.connected && !tab._reconnecting) {
          tab._retryCount = 0;
          _reconnectTab(tab);
        }
      }
    }
  }

  Future<SSHClient> _getClient() async {
    if (_sharedClient != null && !_sharedClient!.isClosed) {
      return _sharedClient!;
    }
    if (_sharedClient != null && _sharedClient!.isClosed) {
      _sharedClient = null;
    }
    if (_connectingClient != null) {
      return _connectingClient!.future;
    }
    _connectingClient = Completer<SSHClient>();
    try {
      final ssh = SshService();
      final client = await ssh.connect(widget.host);
      _sharedClient = client;
      _connectingClient!.complete(client);
      return client;
    } catch (e) {
      _connectingClient!.completeError(e);
      rethrow;
    } finally {
      _connectingClient = null;
    }
  }

  Future<void> _reconnectTab(_TerminalTab tab) async {
    if (tab._reconnecting) return;
    tab._reconnecting = true;
    tab._retryCount++;
    if (tab._retryCount > 5) {
      tab._reconnecting = false;
      if (mounted) {
        setState(() {
          tab.error = '再接続に失敗した（5回リトライ済み）';
        });
      }
      return;
    }
    try {
      final backoff = Duration(seconds: tab._retryCount.clamp(1, 5));
      await Future.delayed(backoff);
      for (final sub in tab.subscriptions) {
        sub.cancel();
      }
      tab.subscriptions.clear();
      tab.session?.close();
      tab.session = null;
      tab.scrollAccumulator = 0;
      tab.error = null;
      tab.connected = false;
      if (mounted) setState(() {});
      await _connectTab(tab);
      if (tab.connected) {
        tab._retryCount = 0;
      }
    } finally {
      tab._reconnecting = false;
    }
  }

  void _addTab(String sessionName) {
    if (!_kSessionNamePattern.hasMatch(sessionName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('無効なセッション名')),
      );
      return;
    }
    final tab = _TerminalTab(sessionName: sessionName);
    setState(() {
      _tabs.add(tab);
      _currentIndex = _tabs.length - 1;
      if (_isDesktop) {
        _splitController ??= SplitViewController(initialTabIndex: 0);
      }
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

      tab.subscriptions.add(
        tab.session!.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .listen((data) {
          tab.terminal.write(data);
        }),
      );

      tab.subscriptions.add(
        tab.session!.stderr
            .cast<List<int>>()
            .transform(utf8.decoder)
            .listen((data) {
          tab.terminal.write(data);
        }),
      );

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
          _reconnectTab(tab);
        }
      });

      setState(() => tab.connected = true);
      if (!_isDesktop && !FlutterBackground.isBackgroundExecutionEnabled) {
        _enableBackground();
      }
    } catch (e) {
      setState(() => tab.error = e.toString());
    }
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    for (final sub in tab.subscriptions) {
      sub.cancel();
    }
    tab.subscriptions.clear();
    tab.session?.close();
    setState(() {
      _splitController?.removeTabFromAll(index);
      _tabs.removeAt(index);
      if (index < _currentIndex) {
        _currentIndex--;
      } else if (_currentIndex >= _tabs.length) {
        _currentIndex = _tabs.isEmpty ? 0 : _tabs.length - 1;
      }
    });
    if (_tabs.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  Future<void> _showAddTabDialog() async {
    final ssh = SshService();
    List<String> sessions = [];

    try {
      final client = await _getClient();
      final (list, _) = await ssh.listTmuxSessions(client);
      sessions = list;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      return;
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
    while (tab.scrollAccumulator >= _kScrollThreshold) {
      tab.session?.write(Uint8List.fromList(_kSgrMouseUp.codeUnits));
      tab.scrollAccumulator -= _kScrollThreshold;
    }
    while (tab.scrollAccumulator <= -_kScrollThreshold) {
      tab.session?.write(Uint8List.fromList(_kSgrMouseDown.codeUnits));
      tab.scrollAccumulator += _kScrollThreshold;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_isDesktop && FlutterBackground.isBackgroundExecutionEnabled) {
      FlutterBackground.disableBackgroundExecution();
    }
    for (final tab in _tabs) {
      for (final sub in tab.subscriptions) {
        sub.cancel();
      }
      tab.subscriptions.clear();
      tab.session?.close();
    }
    _sharedClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    return Scaffold(
      resizeToAvoidBottomInset: false,
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
                final tabWidget = GestureDetector(
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
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: GestureDetector(
                            onTap: () => _closeTab(i),
                            child: const Center(
                              child: Icon(Icons.close, size: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
                if (!_isDesktop) return tabWidget;
                return Draggable<int>(
                  data: i,
                  feedback: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(tab.sessionName,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.4,
                    child: tabWidget,
                  ),
                  child: tabWidget,
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

  void _copySelection() {
    if (_tabs.isEmpty) return;
    final range = _currentTab.controller.selection;
    if (range == null) return;
    final text = _currentTab.terminal.buffer.getText(range);
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('コピーしました'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _pasteClipboard() async {
    if (_tabs.isEmpty) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _currentTab.session?.write(
        Uint8List.fromList(utf8.encode(data.text!)),
      );
    }
  }

  void _sendKey(String seq) {
    if (_tabs.isEmpty) return;
    _currentTab.session?.write(Uint8List.fromList(utf8.encode(seq)));
  }

  void _sendCtrlKey(String char) {
    if (_tabs.isEmpty) return;
    final code = char.toUpperCase().codeUnitAt(0) - 0x40;
    if (code > 0 && code < 32) {
      _currentTab.session?.write(Uint8List.fromList([code]));
    }
    setState(() => _ctrlHeld = false);
  }

  Widget _buildTerminalPane(int tabIndex) {
    if (tabIndex < 0 || tabIndex >= _tabs.length) {
      return Container(color: Colors.black);
    }
    final tab = _tabs[tabIndex];
    if (tab.error != null) {
      if (tab._reconnecting) {
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tab.error!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                tab._retryCount = 0;
                _reconnectTab(tab);
              },
              child: const Text('再試行'),
            ),
          ],
        ),
      );
    }
    if (!tab.connected) {
      return const Center(child: CircularProgressIndicator());
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        tab._lastPointerPosition = event.position;
      },
      onPointerMove: (event) {
        if (tab._lastPointerPosition == null) return;
        final diff = event.position - tab._lastPointerPosition!;
        if (diff.dy.abs() < _kPointerMoveMinDistance) return;
        if (diff.dx.abs() > diff.dy.abs()) return;
        _handleScroll(tab, -event.delta.dy);
        tab._lastPointerPosition = event.position;
      },
      onPointerUp: (_) {
        tab._lastPointerPosition = null;
      },
      onPointerCancel: (_) {
        tab._lastPointerPosition = null;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _handleScroll(tab, event.scrollDelta.dy);
        }
      },
      child: TerminalView(
        tab.terminal,
        controller: tab.controller,
        autofocus: true,
        deleteDetection: !_isDesktop,
        keyboardType: _isDesktop ? TextInputType.text : TextInputType.emailAddress,
        textStyle: const TerminalStyle(
          fontFamily: 'TerminalFont',
          fontFamilyFallback: ['TerminalFontJP'],
          locale: Locale('ja', 'JP'),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isDesktop && _splitController != null) {
      return SplitView(
        controller: _splitController!,
        tabCount: _tabs.length,
        paneBuilder: (tabIndex, leafId, focused) {
          return _buildTerminalPane(tabIndex);
        },
        onFocusChanged: (leafId) {
          final leaf = _splitController!.focusedLeaf();
          if (leaf != null) {
            setState(() => _currentIndex = leaf.tabIndex);
          }
        },
        onChanged: () => setState(() {}),
      );
    }

    final terminalView = _buildTerminalPane(_currentIndex);

    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    return Transform.translate(
      offset: Offset(0, -keyboardHeight),
      child: Column(
        children: [
          Expanded(child: terminalView),
          _buildAccessoryBar(),
        ],
      ),
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
              _divider(),
              _keyButton('Copy', _copySelection),
              _keyButton('Paste', _pasteClipboard),
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
