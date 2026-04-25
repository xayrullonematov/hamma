import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xterm/xterm.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/ssh/connection_status.dart';
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
  final FocusNode _terminalFocusNode = FocusNode();
  SSHSession? _session;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  String _recentTerminalOutput = '';
  bool _isFullScreen = false;

  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = _handleTerminalOutput;
    _terminal.onResize = _handleTerminalResize;

    widget.sshService.statusNotifier.addListener(_handleStatusChange);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.sshService.isConnected) {
        _openShell();
      }
      if (_isDesktop) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _terminalFocusNode.requestFocus();
        });
      }
    });
  }

  @override
  void dispose() {
    widget.sshService.statusNotifier.removeListener(_handleStatusChange);
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _session?.close();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  void _handleStatusChange() {
    if (!mounted) return;
    final status = widget.sshService.currentStatus;
    
    // Auto-reopen shell if we just got connected and don't have a session
    if (status.isConnected && _session == null) {
      _openShell();
    } else if (!status.isConnected && _session != null) {
      _session = null;
      setState(() {});
    }
  }

  Future<void> _toggleFullScreen() async {
    if (!_isDesktop) return;
    final isFull = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFull);
    setState(() {
      _isFullScreen = !isFull;
    });
  }

  Future<void> _openShell() async {
    if (!widget.sshService.isConnected) return;
    
    try {
      final session = await widget.sshService.startShell(
        width: _terminal.viewWidth,
        height: _terminal.viewHeight,
      );

      _stdoutSubscription?.cancel();
      _stdoutSubscription = session.stdout.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _terminal.write(text);
        _trackOutput(text);
      });

      _stderrSubscription?.cancel();
      _stderrSubscription = session.stderr.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _terminal.write(text);
        _trackOutput(text);
      });

      session.done.then((_) {
        if (!mounted) return;
        setState(() {
          _session = null;
        });
        _terminal.write('\r\n[session closed]\r\n');
      });

      setState(() {
        _session = session;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _session = null;
      });
      _terminal.write('Failed to open shell: $e\r\n');
    }
  }

  void _handleTerminalOutput(String data) {
    if (!widget.sshService.isConnected) return;
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
    final status = widget.sshService.currentStatus;
    if (status.isConnecting) return;

    try {
      await widget.sshService.reconnect();
      // _openShell will be called by the status listener
    } catch (e) {
      if (mounted) {
        _terminal.write('Reconnection failed: $e\r\n');
      }
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
          canRunCommands: () => _session != null && widget.sshService.isConnected,
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

  String _formatTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: Text('Terminal: ${widget.serverName}'),
        actions: [
          if (_isDesktop)
            IconButton(
              onPressed: _toggleFullScreen,
              icon: Icon(_isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
              tooltip: 'Toggle Full Screen',
            ),
          IconButton(
            onPressed: _openCopilot,
            icon: const Icon(Icons.smart_toy_outlined),
            tooltip: 'AI Copilot',
          ),
        ],
      ),
      body: Column(
        children: [
          ValueListenableBuilder<ConnectionStatus>(
            valueListenable: widget.sshService.statusNotifier,
            builder: (context, status, _) {
              return _buildStatusHeader(status);
            },
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (mounted) _terminalFocusNode.requestFocus();
              },
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
                    focusNode: _terminalFocusNode,
                    autofocus: true,
                    enabled: widget.sshService.isConnected,
                  ),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<ConnectionStatus>(
            valueListenable: widget.sshService.statusNotifier,
            builder: (context, status, _) {
              return _buildToolbar(status.isConnected);
            },
          ),
          if (_isDesktop) const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildStatusHeader(ConnectionStatus status) {
    Color indicatorColor;
    String label;
    String? subLabel;
    bool showLoading = false;

    switch (status.state) {
      case SshConnectionState.connected:
        indicatorColor = Colors.green;
        label = 'Connected';
        subLabel = 'Last sync: ${_formatTime(status.lastSuccessfulConnection)}';
        break;
      case SshConnectionState.connecting:
        indicatorColor = Colors.orange;
        label = 'Connecting...';
        showLoading = true;
        break;
      case SshConnectionState.reconnecting:
        indicatorColor = Colors.orange;
        label = 'Reconnecting (Attempt ${status.reconnectAttempts}/${status.maxReconnectAttempts})...';
        showLoading = true;
        break;
      case SshConnectionState.failed:
        indicatorColor = Colors.red;
        label = status.exception?.userMessage ?? 'Connection Failed';
        subLabel = status.exception?.suggestedAction;
        break;
      case SshConnectionState.disconnected:
        indicatorColor = Colors.grey;
        label = 'Disconnected';
        break;
    }

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (showLoading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
            )
          else
            CircleAvatar(
              radius: 4,
              backgroundColor: indicatorColor,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (subLabel != null)
                  Padding(
                    padding: const EdgeInsets.top(2),
                    child: Text(
                      subLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _mutedColor, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          if (!status.isConnected && !status.isConnecting)
            TextButton(
              onPressed: _handleReconnect,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: Colors.blue,
              ),
              child: const Text('Reconnect'),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar(bool isConnected) {
    if (_isDesktop) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(8),
      color: _panelColor,
      child: SafeArea(
        top: false,
        child: Opacity(
          opacity: isConnected ? 1.0 : 0.5,
          child: AbsorbPointer(
            absorbing: !isConnected,
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
