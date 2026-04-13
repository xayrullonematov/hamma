import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/ssh/ssh_service.dart';
import '../ai_assistant/ai_copilot_sheet.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sshService,
    required this.serverName,
    required this.aiProvider,
    required this.apiKey,
  });

  final SshService sshService;
  final String serverName;
  final AiProvider aiProvider;
  final String apiKey;

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
          _session = null;
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
        _session = null;
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

  Future<void> _sendCommandToShell(String command) async {
    final session = _session;
    if (session == null) {
      throw StateError('Terminal shell is not connected.');
    }

    session.write(Uint8List.fromList(utf8.encode('$command\n')));
  }

  Future<void> _openCopilot() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) {
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: AiCopilotSheet(
            provider: widget.aiProvider,
            apiKey: widget.apiKey,
            canRunCommands: () => _session != null,
            onRunCommand: _sendCommandToShell,
            executionUnavailableMessage:
                'Terminal shell is disconnected. Reconnect before running commands.',
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Terminal: ${widget.serverName}'),
        actions: [
          IconButton(
            onPressed: _openCopilot,
            icon: const Icon(Icons.smart_toy_outlined),
            tooltip: 'AI Copilot',
          ),
        ],
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
      floatingActionButton: FloatingActionButton(
        onPressed: _openCopilot,
        child: const Icon(Icons.smart_toy_outlined),
      ),
    );
  }
}
