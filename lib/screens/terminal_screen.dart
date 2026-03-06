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

      // Handle session done
      _session!.done.then((_) {
        if (mounted) {
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
            _session?.close();
            _client?.close();
            Navigator.pop(context);
          },
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    if (!_connected) {
      return const Center(child: CircularProgressIndicator());
    }
    return Listener(
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
    );
  }
}
