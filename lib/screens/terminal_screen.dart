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
import '../services/notification_service.dart';
import '../services/ssh_service.dart';
import '../services/tab_state_service.dart';
import '../widgets/split_view.dart';
import 'package:xterm/suggestion.dart';
import '../models/tmux_window.dart';

final _isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

const _kScrollThreshold = 20.0;
const _kSgrMouseUp = '\x1b[<65;1;1M';
const _kSgrMouseDown = '\x1b[<64;1;1M';
const _kMaxLines = 10000;
final _kSessionNamePattern = RegExp(r'^[a-zA-Z0-9_-]+$');
const _kPointerMoveMinDistance = 5.0;
const _kIdleSeconds = 5;

int _nextNotificationId = 0;

class _TerminalTab {
  final String sessionName;
  int? windowIndex; // null = アクティブウィンドウ
  final Terminal terminal;
  final TerminalController controller;
  SSHSession? session;
  bool connected = false;
  String? error;
  double scrollAccumulator = 0;
  bool _reconnecting = false;
  bool _intentionallyClosed = false;
  int _retryCount = 0;
  List<StreamSubscription> subscriptions = [];
  Offset? _lastPointerPosition;
  final GlobalKey<TerminalViewState> terminalKey = GlobalKey<TerminalViewState>();

  final FocusNode focusNode = FocusNode();

  // Idle通知用
  final int notificationId = _nextNotificationId++;
  Timer? _idleTimer;
  bool _idleNotified = false;
  DateTime? _connectedAt;
  String _lastContentSnapshot = '';

  _TerminalTab({required this.sessionName, this.windowIndex})
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
  SplitViewController? _splitController;
  _TerminalTab get _currentTab => _tabs[_currentIndex];

  // Autocomplete
  late final _historyService = CommandHistoryService(hostId: widget.host.id);
  final _suggestionController = SuggestionPortalController();
  List<String> _suggestions = [];
  String _lastInput = '';
  Timer? _debounceTimer;
  Timer? _watchdogTimer;
  bool _isInBackground = false;
  StreamSubscription<String>? _notificationTapSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.init();
    _notificationTapSub = NotificationService.onTap.listen(_onNotificationTap);
    if (widget.sessionName != null) {
      _addTab(widget.sessionName!);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreOrShowPanel();
      });
    }
    _startWatchdog();
  }

  void _onNotificationTap(String sessionName) {
    final index = _tabs.indexWhere((t) => t.sessionName == sessionName);
    if (index >= 0 && index < _tabs.length) {
      setState(() => _currentIndex = index);
      final tab = _tabs[index];
      if (tab._idleNotified) {
        tab._idleNotified = false;
        NotificationService.cancel(tab.notificationId);
      }
    }
  }

  void _startWatchdog() {
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkConnection();
    });
  }

  Future<void> _checkConnection() async {
    if (_sharedClient == null || _sharedClient!.isClosed) {
      _sharedClient = null;
      for (final tab in _tabs) {
        if (tab.connected && !tab._intentionallyClosed && !tab._reconnecting) {
          if (mounted) {
            setState(() {
              tab.connected = false;
              tab.error = 'Connection lost';
            });
          }
          _reconnectTab(tab);
        }
      }
      return;
    }
    // ping で生存確認
    try {
      await _sharedClient!.ping().timeout(const Duration(seconds: 5));
    } catch (_) {
      _sharedClient?.close();
      _sharedClient = null;
      for (final tab in _tabs) {
        if (tab.connected && !tab._intentionallyClosed && !tab._reconnecting) {
          if (mounted) {
            setState(() {
              tab.connected = false;
              tab.error = 'Connection lost';
            });
          }
          _reconnectTab(tab);
        }
      }
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
    debugPrint('[lifecycle] state=$state');
    if (state != AppLifecycleState.resumed) {
      if (!_isInBackground) {
        _isInBackground = true;
        // バックグラウンドに入った時、接続中タブのidleタイマーをセット
        for (final tab in _tabs) {
          if (tab.connected && !tab._intentionallyClosed) {
            _resetIdleTimer(tab);
          }
        }
      }
      return;
    }
    // resumed
    _isInBackground = false;
    // 現在表示中のタブの通知だけ消す
    if (_tabs.isNotEmpty) {
      final tab = _currentTab;
      if (tab._idleNotified) {
        tab._idleNotified = false;
        NotificationService.cancel(tab.notificationId);
      }
    }
    // 共有クライアントが死んでたらリセット
    if (_sharedClient != null && _sharedClient!.isClosed) {
      _sharedClient = null;
    }
    // 切断されたタブを再接続（エラー状態含む）
    for (final tab in _tabs) {
      if ((!tab.connected || tab.error != null) && !tab._reconnecting && !tab._intentionallyClosed) {
        tab._retryCount = 0;
        tab.error = null;
        _reconnectTab(tab);
      }
    }
    if (mounted) setState(() {});
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

  void _addTab(String sessionName, {int? windowIndex}) {
    if (!_kSessionNamePattern.hasMatch(sessionName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('無効なセッション名')),
      );
      return;
    }
    final tab = _TerminalTab(sessionName: sessionName, windowIndex: windowIndex);
    setState(() {
      _tabs.add(tab);
      _currentIndex = _tabs.length - 1;
      if (_isDesktop) {
        _splitController ??= SplitViewController(initialTabIndex: 0);
      }
    });
    _connectTab(tab);
    _saveTabState();
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

      final target = tab.windowIndex != null
          ? '${SshService.sanitizeSessionName(tab.sessionName)}:${tab.windowIndex}'
          : SshService.sanitizeSessionName(tab.sessionName);
      tab.session!.write(Uint8List.fromList(
        "${SshService.pathPrefix} && tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t $target\n"
            .codeUnits,
      ));

      tab.subscriptions.add(
        tab.session!.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .listen((data) {
          tab.terminal.write(data);
          _checkContentAndResetIdle(tab);
        }),
      );

      tab.subscriptions.add(
        tab.session!.stderr
            .cast<List<int>>()
            .transform(utf8.decoder)
            .listen((data) {
          tab.terminal.write(data);
          _checkContentAndResetIdle(tab);
        }),
      );

      tab.terminal.onOutput = (data) {
        if (_sharedClient != null && _sharedClient!.isClosed) {
          // 接続が死んでる — 再接続トリガー
          _sharedClient = null;
          if (tab.connected && !tab._intentionallyClosed && !tab._reconnecting) {
            if (mounted) {
              setState(() {
                tab.connected = false;
                tab.error = 'Connection lost';
              });
            }
            _reconnectTab(tab);
          }
          return;
        }
        tab.session?.write(Uint8List.fromList(utf8.encode(data)));
        _onTerminalOutput(tab, data);
      };

      tab.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        tab.session?.resizeTerminal(width, height);
      };

      tab.session!.done.then((_) {
        if (mounted && !tab._intentionallyClosed) {
          setState(() {
            tab.connected = false;
            tab.error = 'Connection lost';
          });
          _reconnectTab(tab);
        }
      });

      if (!mounted) return;
      tab._connectedAt = DateTime.now();
      setState(() => tab.connected = true);
      if (!_isDesktop && !FlutterBackground.isBackgroundExecutionEnabled) {
        _enableBackground();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => tab.error = e.toString());
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
    tab._intentionallyClosed = true;
    tab._idleTimer?.cancel();
    NotificationService.cancel(tab.notificationId);
    for (final sub in tab.subscriptions) {
      sub.cancel();
    }
    tab.subscriptions.clear();
    tab.session?.close();
    tab.controller.dispose();
    tab.focusNode.dispose();
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
        if (mounted) _showAddTabDialog();
      });
    }
    _saveTabState();
  }

  Future<void> _restoreOrShowPanel() async {
    final saved = await TabStateService.load(widget.host.id);
    if (!mounted) return;
    if (saved.isEmpty) {
      _showAddTabDialog();
      return;
    }
    for (final id in saved) {
      _addTab(id.sessionName, windowIndex: id.windowIndex);
    }
  }

  void _saveTabState() {
    unawaited(TabStateService.save(
      widget.host.id,
      _tabs.map((t) => TabIdentifier(
        sessionName: t.sessionName,
        windowIndex: t.windowIndex,
      )).toList(),
    ));
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

    final openNames = _tabs.map((t) => t.sessionName).toSet();
    // 既に開いてるセッションも表示（ウィンドウ選択のため）
    final allSessions = sessions;

    if (!mounted) return;

    final result = await showGeneralDialog<({String session, int? windowIndex})>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, anim, secondaryAnimation) => _SessionSelectorPanel(
        sessions: allSessions,
        openSessionNames: openNames,
        ssh: ssh,
        getClient: _getClient,
      ),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
    );

    if (result != null) {
      _addTab(result.session, windowIndex: result.windowIndex);
    }
  }

  String _getLastVisibleLine(_TerminalTab tab) {
    final buffer = tab.terminal.buffer;
    final cursorY = buffer.absoluteCursorY;
    // カーソル行から上に探して、空でない行を返す
    for (var y = cursorY; y >= 0 && y > cursorY - 5; y--) {
      if (y >= buffer.lines.length) continue;
      final text = buffer.lines[y].toString().trimRight();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /// stdoutから呼ばれる: 表示内容が変わった時だけidleタイマーをリセット
  void _checkContentAndResetIdle(_TerminalTab tab) {
    final content = _getLastVisibleLine(tab);
    if (content == tab._lastContentSnapshot) return;
    tab._lastContentSnapshot = content;
    _resetIdleTimer(tab);
  }

  void _resetIdleTimer(_TerminalTab tab) {
    tab._idleTimer?.cancel();
    // 出力が来た → まだ動いてるのでidle通知をリセット
    if (tab._idleNotified) {
      tab._idleNotified = false;
      NotificationService.cancel(tab.notificationId);
    }
    tab._idleTimer = Timer(const Duration(seconds: _kIdleSeconds), () {
      // 再接続直後10秒はスキップ（tmux再描画後の誤通知防止）
      if (tab._connectedAt == null ||
          DateTime.now().difference(tab._connectedAt!).inSeconds < 10) {
        debugPrint('[idle] skipped: cooldown (connectedAt=${tab._connectedAt})');
        return;
      }
      final isCurrentTab = _tabs.indexOf(tab) == _currentIndex;
      final shouldNotify = tab.connected &&
          !tab._intentionallyClosed &&
          (_isInBackground || !isCurrentTab);
      debugPrint('[idle] timer fired: bg=$_isInBackground, currentTab=$isCurrentTab, connected=${tab.connected}, intentionallyClosed=${tab._intentionallyClosed} → notify=$shouldNotify');
      if (shouldNotify) {
        tab._idleNotified = true;
        final lastLine = _getLastVisibleLine(tab);
        debugPrint('[idle] showing notification: "$lastLine"');
        NotificationService.showIdle(
          tabId: tab.notificationId,
          sessionName: tab.sessionName,
          hostLabel: widget.host.label,
          lastLine: lastLine,
        );
      }
    });
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
      tab._idleTimer?.cancel();
      for (final sub in tab.subscriptions) {
        sub.cancel();
      }
      tab.subscriptions.clear();
      tab.session?.close();
      tab.controller.dispose();
      tab.focusNode.dispose();
    }
    NotificationService.cancelAll();
    _sharedClient?.close();
    _debounceTimer?.cancel();
    _watchdogTimer?.cancel();
    _notificationTapSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    return SuggestionPortal(
      controller: _suggestionController,
      overlayBuilder: (_) => _buildSuggestionOverlay(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
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

  Widget _buildTabBar() {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () {
              for (final tab in _tabs) {
                tab._intentionallyClosed = true;
                for (final sub in tab.subscriptions) {
                  sub.cancel();
                }
                tab.subscriptions.clear();
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
                  onTap: () {
                    setState(() => _currentIndex = i);
                    if (tab._idleNotified) {
                      tab._idleNotified = false;
                      NotificationService.cancel(tab.notificationId);
                    }
                  },
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
                          tab.windowIndex != null
                              ? '${tab.sessionName}[${tab.windowIndex}]'
                              : tab.sessionName,
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
                      child: Text(
                          tab.windowIndex != null
                              ? '${tab.sessionName}[${tab.windowIndex}]'
                              : tab.sessionName,
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
      _currentTab.controller.clearSelection();
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
    final renderBox = tab.focusNode.context?.findRenderObject() as RenderBox?;
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
        if (tab.controller.selection != null) return;
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
      child: Stack(
        children: [
          TerminalView(
            tab.terminal,
            key: tab.terminalKey,
            controller: tab.controller,
            focusNode: tab.focusNode,
            autofocus: true,
            deleteDetection: !_isDesktop,
            keyboardType: _isDesktop ? TextInputType.text : TextInputType.emailAddress,
            textStyle: const TerminalStyle(
              fontFamily: 'TerminalFont',
              fontFamilyFallback: ['TerminalFontJP'],
              locale: Locale('ja', 'JP'),
            ),
          ),
          if (!_isDesktop)
            ListenableBuilder(
              listenable: tab.controller,
              builder: (context, _) {
                if (tab.controller.selection == null) {
                  return const SizedBox.shrink();
                }
                return _buildSelectionHandles(tab);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionHandles(_TerminalTab tab) {
    final state = tab.terminalKey.currentState;
    if (state == null) return const SizedBox.shrink();
    final render = state.renderTerminal;

    final baseOffset = tab.controller.selectionBaseOffset;
    final extentOffset = tab.controller.selectionExtentOffset;
    if (baseOffset == null || extentOffset == null) {
      return const SizedBox.shrink();
    }

    final basePixel = render.getOffset(baseOffset);
    final extentPixel = render.getOffset(extentOffset);
    final cellHeight = render.lineHeight;

    return LayoutBuilder(builder: (context, constraints) {
      final parentSize = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        children: [
          _buildHandle(tab, basePixel, cellHeight, true, parentSize),
          _buildHandle(tab, extentPixel, cellHeight, false, parentSize),
        ],
      );
    });
  }

  Widget _buildHandle(
    _TerminalTab tab, Offset position, double cellHeight, bool isBase,
    Size parentSize,
  ) {
    const handleSize = 20.0;
    const hitSize = 44.0;
    const hitPad = (hitSize - handleSize) / 2;

    final left = (position.dx - hitSize / 2).clamp(0.0, parentSize.width - hitSize);
    final top = isBase
        ? (position.dy - handleSize - hitPad).clamp(0.0, parentSize.height - hitSize)
        : (position.dy + cellHeight - hitPad).clamp(0.0, parentSize.height - hitSize);

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          final state = tab.terminalKey.currentState;
          if (state == null) return;
          final render = state.renderTerminal;
          final box = render as RenderBox;
          final local = box.globalToLocal(details.globalPosition);
          final cellOffset = render.getCellOffset(local);
          // Guard against out-of-range y
          final lines = tab.terminal.buffer.lines;
          if (cellOffset.y < 0 || cellOffset.y >= lines.length) return;
          final baseOffset = tab.controller.selectionBaseOffset;
          final extentOffset = tab.controller.selectionExtentOffset;
          if (baseOffset == null || extentOffset == null) return;
          final buffer = tab.terminal.buffer;
          if (isBase) {
            tab.controller.setSelection(
              buffer.createAnchorFromOffset(cellOffset),
              buffer.createAnchorFromOffset(extentOffset),
            );
          } else {
            tab.controller.setSelection(
              buffer.createAnchorFromOffset(baseOffset),
              buffer.createAnchorFromOffset(cellOffset),
            );
          }
        },
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: Container(
              width: handleSize,
              height: handleSize,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
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
          // 同じタブが複数ペインに割り当てられている場合、
          // GlobalKeyの重複を避けるため最初のリーフのみ描画する
          final leaves = _splitController!.allLeaves();
          final firstLeaf = leaves.firstWhere((l) => l.tabIndex == tabIndex);
          if (firstLeaf.id != leafId) {
            return Container(
              color: Colors.black,
              child: const Center(
                child: Text(
                  'このタブは別のペインで表示中',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            );
          }
          return _buildTerminalPane(tabIndex);
        },
        onFocusChanged: (leafId) {
          final leaf = _splitController!.focusedLeaf();
          if (leaf != null) {
            setState(() => _currentIndex = leaf.tabIndex);
            final tab = _tabs[leaf.tabIndex];
            if (tab._idleNotified) {
              tab._idleNotified = false;
              NotificationService.cancel(tab.notificationId);
            }
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
        child: Row(
          children: [
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
                        final tab = _tabs[_currentIndex];
                        tab.terminalKey.currentState?.requestKeyboard();
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
            _divider(),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _keyButton('Esc', () => _sendKey('\x1b')),
                    _keyButton('Tab', () => _sendKey('\t')),
                    _divider(),
                    _keyButton('↑', () => _sendKey('\x1b[A')),
                    _keyButton('↓', () => _sendKey('\x1b[B')),
                    _divider(),
                    _keyButton('Enter', () => _sendKey('\r')),
                    _keyButton('\\\u23CE', () => _sendKey('\\\r')),
                    _divider(),
                    _keyButton('Copy', _copySelection),
                    _keyButton('Paste', _pasteClipboard),
                  ],
                ),
              ),
            ),
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

class _SessionSelectorPanel extends StatefulWidget {
  final List<String> sessions;
  final Set<String> openSessionNames;
  final SshService ssh;
  final Future<SSHClient> Function() getClient;

  const _SessionSelectorPanel({
    required this.sessions,
    required this.openSessionNames,
    required this.ssh,
    required this.getClient,
  });

  @override
  State<_SessionSelectorPanel> createState() => _SessionSelectorPanelState();
}

class _SessionSelectorPanelState extends State<_SessionSelectorPanel> {
  // セッション名 → ウィンドウリスト(null=未ロード)
  final Map<String, List<TmuxWindow>?> _windowsCache = {};
  final Set<String> _expanding = {};
  final Set<String> _expanded = {}; // 展開状態（ロードと分離）

  @override
  void initState() {
    super.initState();
    // 全セッションのウィンドウ数を並列先読み
    for (final s in widget.sessions) {
      _loadWindows(s);
    }
  }

  Future<void> _loadWindows(String sessionName) async {
    if (_windowsCache.containsKey(sessionName)) return;
    setState(() => _expanding.add(sessionName));
    try {
      final client = await widget.getClient();
      final windows = await widget.ssh.listTmuxWindows(client, sessionName);
      if (mounted) {
        setState(() {
          _windowsCache[sessionName] = windows;
          _expanding.remove(sessionName);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _windowsCache[sessionName] = [];
          _expanding.remove(sessionName);
        });
      }
    }
  }

  Future<void> _createWindow(String sessionName) async {
    try {
      final client = await widget.getClient();
      await widget.ssh.createTmuxWindow(client, sessionName);
      // キャッシュを無効化して再ロード
      setState(() => _windowsCache.remove(sessionName));
      await _loadWindows(sessionName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _killWindow(String sessionName, int windowIndex) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kill window?'),
        content: Text('Kill window $windowIndex of "$sessionName"?'),
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
    if (ok != true) return;
    try {
      final client = await widget.getClient();
      await widget.ssh.killTmuxWindow(client, sessionName, windowIndex);
      setState(() => _windowsCache.remove(sessionName));
      await _loadWindows(sessionName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          child: SizedBox(
            width: 280,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Open session', style: TextStyle(fontSize: 18)),
                ),
                const Divider(height: 1),
                Expanded(
                  child: widget.sessions.isEmpty
                      ? const Center(child: Text('No sessions available'))
                      : ListView.builder(
                          itemCount: widget.sessions.length,
                          itemBuilder: (ctx, i) {
                            final name = widget.sessions[i];
                            final windows = _windowsCache[name];
                            final isExpanding = _expanding.contains(name);
                            final isExpanded = _expanded.contains(name);

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.terminal),
                                  title: Text(name),
                                  subtitle: isExpanding
                                      ? const Text('...')
                                      : windows != null
                                          ? Text('${windows.length} window${windows.length == 1 ? '' : 's'}')
                                          : null,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isExpanding)
                                        const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      else if (windows != null)
                                        IconButton(
                                          icon: Icon(
                                            isExpanded
                                                ? Icons.expand_less
                                                : Icons.expand_more,
                                            size: 20,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              if (isExpanded) {
                                                _expanded.remove(name);
                                              } else {
                                                _expanded.add(name);
                                              }
                                            });
                                          },
                                        ),
                                    ],
                                  ),
                                  onTap: () {
                                    // ウィンドウ未ロードの場合はアクティブウィンドウで接続
                                    Navigator.pop(
                                      ctx,
                                      (session: name, windowIndex: null),
                                    );
                                  },
                                ),
                                if (isExpanded && windows != null) ...[
                                  ...windows.map((w) => ListTile(
                                        contentPadding: const EdgeInsets.only(left: 40, right: 8),
                                        leading: Icon(
                                          w.isActive
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          size: 16,
                                        ),
                                        title: Text(w.displayName),
                                        subtitle: Text('Window ${w.index}'),
                                        trailing: IconButton(
                                          icon: const Icon(Icons.close, size: 16),
                                          onPressed: () => _killWindow(name, w.index),
                                        ),
                                        onTap: () => Navigator.pop(
                                          ctx,
                                          (session: name, windowIndex: w.index),
                                        ),
                                      )),
                                  ListTile(
                                    contentPadding: const EdgeInsets.only(left: 40, right: 8),
                                    leading: const Icon(Icons.add, size: 16),
                                    title: const Text('New window'),
                                    onTap: () => _createWindow(name),
                                  ),
                                ],
                                const Divider(height: 1),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
