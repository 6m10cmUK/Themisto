import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/host_config.dart';
import '../services/ssh_service.dart';

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
  final _terminal = Terminal(maxLines: 10000);
  SSHClient? _client;
  SSHSession? _session;
  bool _connected = false;
  String? _error;
  bool _ctrlHeld = false;
  bool _manualClose = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final ssh = SshService();
      _client = await ssh.connect(widget.host);

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      // Enable mouse mode and attach to tmux session with UTF-8 mode
      _session!.write(Uint8List.fromList(
        '${SshService.pathPrefix} && tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t ${widget.sessionName}\n'
            .codeUnits,
      ));

      // SSH stdout -> terminal (UTF-8 streaming decoder handles chunk boundaries)
      _session!.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((data) {
        _terminal.write(data);
      });

      _session!.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((data) {
        _terminal.write(data);
      });

      // Terminal input -> SSH stdin (UTF-8)
      _terminal.onOutput = (data) {
        _session?.write(Uint8List.fromList(utf8.encode(data)));
      };

      // Terminal resize -> SSH pty resize
      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _session?.resizeTerminal(width, height);
      };

      // Handle session done (only auto-pop if not manually closed)
      _session!.done.then((_) {
        if (mounted && !_manualClose) {
          Navigator.pop(context);
        }
      });

      setState(() => _connected = true);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  double _scrollAccumulator = 0;

  void _handleScroll(double delta) {
    _scrollAccumulator += delta;
    const threshold = 20.0;
    // Send mouse wheel escape sequences (SGR mode)
    // \x1b[<65;1;1M = wheel down, \x1b[<64;1;1M = wheel up
    while (_scrollAccumulator >= threshold) {
      _session?.write(Uint8List.fromList('\x1b[<65;1;1M'.codeUnits));
      _scrollAccumulator -= threshold;
    }
    while (_scrollAccumulator <= -threshold) {
      _session?.write(Uint8List.fromList('\x1b[<64;1;1M'.codeUnits));
      _scrollAccumulator += threshold;
    }
  }

  @override
  void dispose() {
    _session?.close();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sessionName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            _manualClose = true;
            _session?.close();
            _client?.close();
            Navigator.pop(context);
          },
        ),
      ),
      body: _buildBody(),
    );
  }

  void _sendKey(String seq) {
    _session?.write(Uint8List.fromList(utf8.encode(seq)));
  }

  void _sendCtrlKey(String char) {
    // Ctrl+A = 0x01, Ctrl+B = 0x02, etc.
    final code = char.toUpperCase().codeUnitAt(0) - 0x40;
    if (code > 0 && code < 32) {
      _session?.write(Uint8List.fromList([code]));
    }
    setState(() => _ctrlHeld = false);
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    if (!_connected) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerMove: (event) {
              _handleScroll(-event.delta.dy);
            },
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _handleScroll(event.scrollDelta.dy);
              }
            },
            child: TerminalView(
              _terminal,
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
              _keyButton('Shift', () {
                // Shift is handled by the OS keyboard
              }),
              _keyButton('Cmd', () {
                // Cmd modifier - no direct terminal equivalent
              }),
              _keyButton('Opt', () {
                // Alt/Option - send ESC prefix for next key
                _sendKey('\x1b');
              }),
              _divider(),
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
