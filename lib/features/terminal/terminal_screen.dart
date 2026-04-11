import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../core/ssh/ssh_service.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sshService,
    required this.serverName,
  });

  final SshService sshService;
  final String serverName;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final Terminal _terminal;

  SSHSession? _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  String _status = 'Opening shell...';

  @override
  void initState() {
    super.initState();

    _terminal = Terminal(
      maxLines: 10000,
    );

    _terminal.write('Connecting interactive shell...\r\n');
    _terminal.onOutput = _handleTerminalInput;
    _terminal.onResize = _handleTerminalResize;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openShell();
    });
  }

  @override
  void dispose() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _session?.close();
    super.dispose();
  }

  Future<void> _openShell() async {
    try {
      final session = await widget.sshService.startShell(
        width: _terminal.viewWidth,
        height: _terminal.viewHeight,
      );

      _stdoutSubscription = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);

      _stderrSubscription = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);

      session.done.then((_) {
        if (!mounted) {
          return;
        }

        setState(() {
          _status = 'Shell closed';
        });
        _terminal.write('\r\n[session closed]\r\n');
      });

      setState(() {
        _session = session;
        _status = 'Interactive shell connected';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to open shell';
      });
      _terminal.write('Failed to open shell.\r\n$error\r\n');
    }
  }

  void _handleTerminalInput(String data) {
    final session = _session;
    if (session == null) {
      return;
    }

    session.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _handleTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _session?.resizeTerminal(width, height, pixelWidth, pixelHeight);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Terminal: ${widget.serverName}'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(_status),
          ),
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF0F172A),
              child: SafeArea(
                top: false,
                child: TerminalView(
                  _terminal,
                  autofocus: true,
                  backgroundOpacity: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
