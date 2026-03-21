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
import '../services/command_history_service.dart';
import '../services/ssh_service.dart';
import '../widgets/dock_view.dart';
import 'package:xterm/suggestion.dart';

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

  final GlobalKey terminalKey = GlobalKey();

  _TerminalTab({required this.sessionName})
      : terminal = Terminal(maxLines: _kMaxLines),
        controller = TerminalController();
}

class TerminalScreen extends StatefulWidget {
  final HostConfig host;
  final String? sessionName;

  const TerminalScreen({
    super.key,
    required this.host,
    this.sessionName,
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
  DockViewController? _dockController;
  _TerminalTab get _currentTab => _tabs[_currentIndex];

  // Sidebar
  bool _sidebarOpen = false;
  double _sidebarWidth = 220;
  List<String> _sidebarSessions = [];
  bool _sidebarLoading = false;

  // Autocomplete
  late final _historyService = CommandHistoryService(hostId: widget.host.id);
  final _suggestionController = SuggestionPortalController();
  List<String> _suggestions = [];
  String _lastInput = '';
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.sessionName != null) {
      _addTab(widget.sessionName!);
      if (_isDesktop) {
        _sidebarOpen = true;
        _loadSidebarSessions();
      }
    } else {
      // Desktop: open with sidebar, no initial tab
      _sidebarOpen = true;
      _loadSidebarSessions();
    }
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
      // 共有クライアントが死んでたらリセット
      if (_sharedClient != null && _sharedClient!.isClosed) {
        _sharedClient = null;
      }
      // 切断されたタブを再接続（エラー状態含む）
      for (final tab in _tabs) {
        if ((!tab.connected || tab.error != null) && !tab._reconnecting) {
          tab._retryCount = 0;
          tab.error = null;
          _reconnectTab(tab);
        }
      }
      if (mounted) setState(() {});
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
      // 共有クライアントが閉じていたらリセット
      if (_sharedClient != null && _sharedClient!.isClosed) {
        _sharedClient = null;
      }
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
        if (_dockController == null) {
          _dockController = DockViewController(initialTabIndex: _currentIndex);
        } else {
          final focused = _dockController!.focusedLeaf();
          if (focused != null) {
            _dockController!.addTabToLeaf(focused.id, _currentIndex);
          }
        }
      }
    });
    _connectTab(tab);
    if (_isDesktop && _sidebarOpen) {
      _loadSidebarSessions();
    }
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
        _onTerminalOutput(tab, data);
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

      if (mounted) setState(() => tab.connected = true);
      if (!_isDesktop && !FlutterBackground.isBackgroundExecutionEnabled) {
        _enableBackground();
      }
    } catch (e) {
      if (mounted) setState(() => tab.error = e.toString());
    }
  }

  void _reloadTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    for (final sub in tab.subscriptions) {
      sub.cancel();
    }
    tab.subscriptions.clear();
    tab.session?.close();
    tab.session = null;
    tab.error = null;
    tab.connected = false;
    tab._retryCount = 0;
    tab._reconnecting = false;
    tab.scrollAccumulator = 0;
    if (_sharedClient != null && _sharedClient!.isClosed) {
      _sharedClient = null;
    }
    setState(() {});
    _connectTab(tab);
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
      _dockController?.closeTab(index);
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _dockController = null;
        _currentIndex = 0;
      } else {
        if (index < _currentIndex) {
          _currentIndex--;
        } else if (_currentIndex >= _tabs.length) {
          _currentIndex = _tabs.length - 1;
        }
        if (_isDesktop && _dockController != null) {
          final focused = _dockController!.focusedLeaf();
          if (focused != null && focused.tabIndices.isNotEmpty) {
            _currentIndex = focused.activeTabIndex;
          }
        }
      }
    });
    if (_tabs.isEmpty && !_isDesktop) {
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

    final String? selected;
    if (_isDesktop) {
      selected = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Open session'),
          children: [
            if (available.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No other sessions available'),
              ),
            ...available.map((name) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, name),
                  child: Row(
                    children: [
                      const Icon(Icons.terminal, size: 20),
                      const SizedBox(width: 12),
                      Text(name),
                    ],
                  ),
                )),
          ],
        ),
      );
    } else {
      selected = await showModalBottomSheet<String>(
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
    }

    if (selected != null) {
      _addTab(selected);
    }
  }

  Future<void> _loadSidebarSessions() async {
    setState(() => _sidebarLoading = true);
    try {
      final client = await _getClient();
      final ssh = SshService();
      final (sessions, _) = await ssh.listTmuxSessions(client);
      if (mounted) {
        setState(() {
          _sidebarSessions = sessions;
          _sidebarLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sidebarLoading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error loading sessions: $e')));
      }
    }
  }

  Future<void> _sidebarCreateSession() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
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
    if (name == null || name.isEmpty) return;
    if (!_kSessionNamePattern.hasMatch(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid session name')),
      );
      return;
    }
    try {
      final client = await _getClient();
      final ssh = SshService();
      await ssh.createSession(client, name);
      _loadSidebarSessions();
      _addTab(name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _sidebarKillSession(String name) async {
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
    // Close the tab if open
    final tabIndex = _tabs.indexWhere((t) => t.sessionName == name);
    if (tabIndex >= 0) {
      _closeTab(tabIndex);
    }
    try {
      final client = await _getClient();
      final ssh = SshService();
      await ssh.killSession(client, name);
      _loadSidebarSessions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _sidebarTapSession(String name) {
    // If tab already open, find its pane and activate it
    final existingIndex = _tabs.indexWhere((t) => t.sessionName == name);
    if (existingIndex >= 0) {
      setState(() {
        _currentIndex = existingIndex;
        if (_isDesktop && _dockController != null) {
          final leaf = _dockController!.findLeafContaining(existingIndex);
          if (leaf != null) {
            _dockController!.activateTab(leaf.id, existingIndex);
          } else {
            // Tab exists but not in any leaf — add to focused leaf
            final focused = _dockController!.focusedLeaf();
            if (focused != null) {
              _dockController!.addTabToLeaf(focused.id, existingIndex);
            }
          }
        }
      });
      if (_isDesktop && _currentIndex < _tabs.length) {
        _tabs[_currentIndex].focusNode.requestFocus();
      }
      return;
    }
    // Otherwise open new tab
    _addTab(name);
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
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty && !_isDesktop) return const SizedBox.shrink();
    return SuggestionPortal(
      controller: _suggestionController,
      overlayBuilder: (_) => _buildSuggestionOverlay(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: _isDesktop
            ? null
            : AppBar(
                toolbarHeight: 0,
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(40),
                  child: _buildTabBar(),
                ),
              ),
        body: _buildBody(),
      ),
    );
  }

  void _navigateBack() {
    for (final tab in _tabs) {
      tab.session?.close();
    }
    _sharedClient?.close();
    Navigator.pop(context);
  }

  /// Mobile-only tab bar
  Widget _buildTabBar() {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: _navigateBack,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length + 1,
              itemBuilder: (context, i) {
                if (i == _tabs.length) {
                  return IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: _showAddTabDialog,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40),
                  );
                }
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
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: GestureDetector(
                            onTap: () => _reloadTab(i),
                            child: const Center(
                              child: Icon(Icons.refresh, size: 16),
                            ),
                          ),
                        ),
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
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Desktop toolbar shown when sidebar is collapsed
  Widget _buildDesktopToolbar() {
    return Container(
      height: 32,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu, size: 18),
            onPressed: () => setState(() => _sidebarOpen = true),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Show sidebar',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 18),
            onPressed: _navigateBack,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const Spacer(),
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
      _currentTab.terminal.paste(data.text!);
    }
  }

  // --- Autocomplete ---

  void _onTerminalOutput(_TerminalTab tab, String data) {
    if (data == '\r' || data == '\n') {
      // Enter pressed — save current input line as command
      final input = _getCurrentInput(tab);
      if (input.isNotEmpty) {
        _historyService.add(input);
      }
      _hideSuggestions();
      _lastInput = '';
      return;
    }
    // Escape sequences (arrows, ctrl, etc.) — hide suggestions
    if (data.startsWith('\x1b')) {
      _hideSuggestions();
      _lastInput = '';
      return;
    }
    // Ctrl-C
    if (data.codeUnitAt(0) < 0x20) {
      _hideSuggestions();
      _lastInput = '';
      return;
    }
    // Debounce search
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 200), () {
      _updateSuggestions(tab);
    });
  }

  String _getCurrentInput(_TerminalTab tab) {
    final buffer = tab.terminal.buffer;
    final cursorY = buffer.absoluteCursorY;
    if (cursorY < 0 || cursorY >= buffer.lines.length) return '';
    final line = buffer.lines[cursorY].toString().trimRight();
    // Try to strip prompt: find last $ or # or > or %
    final promptPattern = RegExp(r'[\$#>%]\s');
    final match = promptPattern.allMatches(line).lastOrNull;
    if (match != null) {
      return line.substring(match.end);
    }
    return line;
  }

  Future<void> _updateSuggestions(_TerminalTab tab) async {
    final input = _getCurrentInput(tab);
    if (input.isEmpty || input == _lastInput) {
      if (input.isEmpty) _hideSuggestions();
      return;
    }
    _lastInput = input;
    final results = await _historyService.search(input);
    if (!mounted) return;
    if (results.isEmpty) {
      _hideSuggestions();
      return;
    }
    setState(() => _suggestions = results);
    // Get cursor rect from terminal view for positioning
    final buffer = tab.terminal.buffer;
    final cursorX = buffer.cursorX;
    final cursorY = buffer.cursorY;
    // Approximate cell size (will be close enough for overlay positioning)
    final renderBox = tab.terminalKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    final cellWidth = size.width / tab.terminal.viewWidth;
    final cellHeight = size.height / tab.terminal.viewHeight;
    final rect = Rect.fromLTWH(
      cursorX * cellWidth,
      (cursorY + 1) * cellHeight,
      cellWidth,
      cellHeight,
    );
    // Convert to global coordinates
    final globalOffset = renderBox.localToGlobal(rect.topLeft);
    final globalRect = Rect.fromLTWH(
      globalOffset.dx, globalOffset.dy, rect.width, rect.height,
    );
    _suggestionController.update(globalRect);
  }

  void _hideSuggestions() {
    if (_suggestionController.isShowing) {
      _suggestionController.hide();
    }
    if (_suggestions.isNotEmpty) {
      setState(() => _suggestions = []);
    }
  }

  Widget _buildSuggestionOverlay() {
    if (_suggestions.isEmpty) return const SizedBox.shrink();
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300, maxHeight: 200),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _suggestions.length,
          itemBuilder: (context, index) {
            final suggestion = _suggestions[index];
            return InkWell(
              onTap: () => _acceptSuggestion(suggestion),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  suggestion,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'TerminalFont',
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _acceptSuggestion(String suggestion) {
    if (_tabs.isEmpty) return;
    final tab = _currentTab;
    final input = _getCurrentInput(tab);
    if (suggestion.length > input.length) {
      final remaining = suggestion.substring(input.length);
      tab.session?.write(Uint8List.fromList(utf8.encode(remaining)));
    }
    _hideSuggestions();
    _lastInput = '';
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
        key: tab.terminalKey,
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

  Widget _buildSidebar() {
    final openNames = _tabs.map((t) => t.sessionName).toSet();
    return Container(
      width: _sidebarWidth,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: Column(
        children: [
          // Host header with back + collapse
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, size: 18),
                    onPressed: _navigateBack,
                    padding: EdgeInsets.zero,
                    tooltip: 'Back to hosts',
                  ),
                ),
                Expanded(
                  child: Text(
                    widget.host.label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: const Icon(Icons.chevron_left, size: 18),
                    onPressed: () => setState(() => _sidebarOpen = false),
                    padding: EdgeInsets.zero,
                    tooltip: 'Collapse sidebar',
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Sessions header with refresh + add
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Sessions',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.grey,
                    ),
                  ),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    onPressed: _loadSidebarSessions,
                    padding: EdgeInsets.zero,
                  ),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: const Icon(Icons.add, size: 16),
                    onPressed: _sidebarCreateSession,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          // Session list
          Expanded(
            child: _sidebarLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _sidebarSessions.isEmpty
                    ? const Center(
                        child: Text(
                          'No sessions',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _sidebarSessions.length,
                        itemBuilder: (context, i) {
                          final name = _sidebarSessions[i];
                          final isOpen = openNames.contains(name);
                          final isActive = _tabs.isNotEmpty &&
                              _currentIndex < _tabs.length &&
                              _tabs[_currentIndex].sessionName == name;
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: Icon(
                              Icons.terminal,
                              size: 18,
                              color: isOpen
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            title: Text(
                              name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight:
                                    isActive ? FontWeight.bold : FontWeight.normal,
                                color: isOpen
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                            selected: isActive,
                            onTap: () => _sidebarTapSession(name),
                            trailing: SizedBox(
                              width: 28,
                              height: 28,
                              child: IconButton(
                                icon: const Icon(Icons.delete_outline, size: 16),
                                onPressed: () => _sidebarKillSession(name),
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isDesktop) {
      return _buildDesktopLayout();
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

  Widget _buildDesktopLayout() {
    Widget terminal;
    if (_dockController != null) {
      terminal = DockView(
        controller: _dockController!,
        tabCount: _tabs.length,
        tabBuilder: (tabIndex) {
          if (tabIndex < 0 || tabIndex >= _tabs.length) {
            return const SizedBox();
          }
          return Text(_tabs[tabIndex].sessionName);
        },
        paneBuilder: (tabIndex, leafId, focused) {
          return _buildTerminalPane(tabIndex);
        },
        onFocusChanged: (leafId) {
          final leaf = _dockController!.focusedLeaf();
          if (leaf != null && leaf.tabIndices.isNotEmpty) {
            setState(() => _currentIndex = leaf.activeTabIndex);
            if (_currentIndex >= 0 && _currentIndex < _tabs.length) {
              _tabs[_currentIndex].focusNode.requestFocus();
            }
          }
        },
        onTabClosed: (tabIndex) => _closeTab(tabIndex),
        onTabReloaded: (tabIndex) => _reloadTab(tabIndex),
        onChanged: () => setState(() {}),
      );
    } else {
      terminal = Container(
        color: Colors.black,
        child: const Center(
          child: Text(
            'Select a session from the sidebar',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return Row(
      children: [
        if (_sidebarOpen) ...[
          _buildSidebar(),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _sidebarWidth = (_sidebarWidth + details.delta.dx)
                      .clamp(150.0, 400.0);
                });
              },
              child: Container(
                width: 4,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
        ],
        Expanded(
          child: Column(
            children: [
              if (!_sidebarOpen) _buildDesktopToolbar(),
              Expanded(child: terminal),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccessoryBar() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _keyButton('Esc', () => _sendKey('\x1b')),
                    _divider(),
                    _keyButton('↑', () => _sendKey('\x1b[A')),
                    _keyButton('↓', () => _sendKey('\x1b[B')),
                    _keyButton('←', () => _sendKey('\x1b[D')),
                    _keyButton('→', () => _sendKey('\x1b[C')),
                    _divider(),
                    _keyButton('Enter', () => _sendKey('\r')),
                    _divider(),
                    _keyButton('Copy', _copySelection),
                    _keyButton('Paste', _pasteClipboard),
                  ],
                ),
              ),
            ),
            _divider(),
            Builder(builder: (context) {
              final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      if (keyboardVisible) {
                        FocusScope.of(context).unfocus();
                      } else {
                        // Re-focus the terminal to open the keyboard
                        final tab = _tabs[_currentIndex];
                        // Re-focus terminal to open keyboard
                        final context = tab.terminalKey.currentContext;
                        if (context != null) {
                          FocusScope.of(context).requestFocus();
                        }
                      }
                    },
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                      alignment: Alignment.center,
                      child: Icon(
                        keyboardVisible ? Icons.keyboard_hide : Icons.keyboard,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(width: 2),
          ],
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
