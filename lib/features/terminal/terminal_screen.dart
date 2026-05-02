import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
import '../../core/theme/app_colors.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sshService,
    required this.serverName,
    required this.aiProvider,
    required this.apiKeyStorage,
    required this.openRouterModel,
    this.localEndpoint,
    this.localModel,
  });

  final SshService sshService;
  final String serverName;
  final AiProvider aiProvider;
  final ApiKeyStorage apiKeyStorage;
  final String? openRouterModel;
  final String? localEndpoint;
  final String? localModel;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _maxContextChars = 3500;
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _mutedColor = AppColors.textMuted;

  late final Terminal _terminal;
  final FocusNode _terminalFocusNode = FocusNode();
  SSHSession? _session;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
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
    
    if (status.isConnected && _session == null) {
      _openShell();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _terminalFocusNode.requestFocus();
      });
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
      // Use fallback dimensions if the terminal hasn't been laid out yet.
      // Starting with 0x0 can cause some shells to freeze or ignore input.
      final session = await widget.sshService.startShell(
        width: math.max(80, _terminal.viewWidth),
        height: math.max(24, _terminal.viewHeight),
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
          localEndpoint: widget.localEndpoint,
          localModel: widget.localModel,
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
        automaticallyImplyLeading: false,
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
            builder: (context, status, _) => _buildStatusHeader(status),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => _terminalFocusNode.requestFocus(),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(
                  color: Colors.black,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.zero,
                  child: TerminalView(
                    _terminal,
                    focusNode: _terminalFocusNode,
                    autofocus: true,
                    // On desktop, use hardware keyboard events directly.
                    // The default IME/CustomTextEdit path is unreliable on
                    // Linux (and Windows) and causes keyboard input to be
                    // silently dropped.
                    hardwareKeyboardOnly: _isDesktop,
                    onTapUp: (details, position) {
                      _terminalFocusNode.requestFocus();
                    },
                  ),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<ConnectionStatus>(
            valueListenable: widget.sshService.statusNotifier,
            builder: (context, status, _) => _buildToolbar(status.isConnected),
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
        indicatorColor = AppColors.textPrimary;
        label = 'Connected';
        subLabel = 'Last sync: ${_formatTime(status.lastSuccessfulConnection)}';
        break;
      case SshConnectionState.connecting:
        indicatorColor = AppColors.textMuted;
        label = 'Connecting...';
        showLoading = true;
        break;
      case SshConnectionState.reconnecting:
        indicatorColor = AppColors.textMuted;
        label = 'Reconnecting (Attempt ${status.reconnectAttempts}/${status.maxReconnectAttempts})...';
        showLoading = true;
        break;
      case SshConnectionState.failed:
        indicatorColor = AppColors.danger;
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
      decoration: const BoxDecoration(
        color: _surfaceColor,
      ),
      child: Row(
        children: [
          if (showLoading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textMuted),
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
                    padding: const EdgeInsets.only(top: 2),
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
                foregroundColor: AppColors.textPrimary,
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
            color: AppColors.surface,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: AppColors.border),
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
