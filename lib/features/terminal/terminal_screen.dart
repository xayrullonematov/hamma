import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../ai_assistant/ai_copilot_sheet.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sshService,
    required this.serverName,
    required this.aiProvider,
    required this.apiKeyStorage,
    required this.openRouterModel,
  });

  final SshService sshService;
  final String serverName;
  final AiProvider aiProvider;
  final ApiKeyStorage apiKeyStorage;
  final String? openRouterModel;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _maxContextChars = 3500;
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);

  late final Terminal _terminal;
  SSHSession? _session;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  String _status = 'Opening shell...';
  bool _isReconnecting = false;
  String _recentTerminalOutput = '';

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = _handleTerminalOutput;
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

      _stdoutSubscription = session.stdout.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _terminal.write(text);
        _trackOutput(text);
      });

      _stderrSubscription = session.stderr.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _terminal.write(text);
        _trackOutput(text);
      });

      session.done.then((_) {
        if (!mounted) return;
        setState(() {
          _session = null;
          _status = 'Shell closed';
        });
        _terminal.write('\r\n[session closed]\r\n');
      });

      setState(() {
        _session = session;
        _status = 'Interactive shell connected';
        _isReconnecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _session = null;
        _status = 'Failed to open shell';
        _isReconnecting = false;
      });
      _terminal.write('Failed to open shell: $e\r\n');
    }
  }

  void _handleTerminalOutput(String data) {
    _session?.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _handleTerminalResize(int width, int height, int pixelWidth, int pixelHeight) {
    _session?.resizeTerminal(width, height);
  }

  void _trackOutput(String data) {
    _recentTerminalOutput += data;
    if (_recentTerminalOutput.length > _maxContextChars) {
      _recentTerminalOutput = _recentTerminalOutput.substring(_recentTerminalOutput.length - _maxContextChars);
    }
  }

  Future<void> _handleReconnect() async {
    if (_isReconnecting) return;
    setState(() {
      _isReconnecting = true;
      _status = 'Reconnecting...';
    });

    try {
      if (!widget.sshService.isConnected) {
        await widget.sshService.reconnect();
      }
      await _openShell();
    } catch (e) {
      setState(() {
        _isReconnecting = false;
        _status = 'Reconnection failed';
      });
      _terminal.write('Reconnection failed: $e\r\n');
    }
  }

  void _sendToolbarKey(String data) {
    _handleTerminalOutput(data);
  }

  Future<void> _openCopilot() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.82,
        child: AiCopilotSheet(
          serverId: widget.serverName,
          provider: widget.aiProvider,
          apiKeyStorage: widget.apiKeyStorage,
          openRouterModel: widget.openRouterModel,
          executionTarget: AiCopilotExecutionTarget.terminal,
          canRunCommands: () => _session != null,
          getContext: () => _recentTerminalOutput,
          onRunCommand: (cmd) async {
            _handleTerminalOutput('$cmd\n');
            return null;
          },
          executionUnavailableMessage:
              'Commands can only be run when the terminal is connected.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: Text('Terminal: ${widget.serverName}'),
        actions: [
          IconButton(
            onPressed: _openCopilot,
            icon: const Icon(Icons.smart_toy_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusHeader(theme),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: TerminalView(
                  _terminal,
                  autofocus: true,
                ),
              ),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildStatusHeader(ThemeData theme) {
    final isConnected = _session != null;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 4,
            backgroundColor: isConnected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
            ),
          ),
          if (!isConnected && !_isReconnecting)
            TextButton(
              onPressed: _handleReconnect,
              child: const Text('Reconnect'),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.all(8),
      color: _panelColor,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _ToolbarButton(label: 'ESC', onTap: () => _sendToolbarKey('\x1b')),
              _ToolbarButton(label: 'TAB', onTap: () => _sendToolbarKey('\t')),
              _ToolbarButton(label: 'CTRL+C', onTap: () => _sendToolbarKey('\x03')),
              _ToolbarButton(label: '↑', onTap: () => _sendToolbarKey('\x1b[A')),
              _ToolbarButton(label: '↓', onTap: () => _sendToolbarKey('\x1b[B')),
              _ToolbarButton(label: '←', onTap: () => _sendToolbarKey('\x1b[D')),
              _ToolbarButton(label: '→', onTap: () => _sendToolbarKey('\x1b[C')),
              _ToolbarButton(label: '|', onTap: () => _sendToolbarKey('|')),
              _ToolbarButton(label: '-', onTap: () => _sendToolbarKey('-')),
              _ToolbarButton(label: '_', onTap: () => _sendToolbarKey('_')),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}
