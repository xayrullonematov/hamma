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
import '../../core/storage/app_prefs_storage.dart';
import '../../core/vault/vault_change_bus.dart';
import '../../core/vault/vault_injector.dart';
import '../../core/vault/vault_redactor.dart';
import '../../core/vault/vault_secret.dart';
import '../../core/vault/vault_storage.dart';
import '../../core/responsive/breakpoints.dart';
import '../ai_assistant/ai_copilot_sheet.dart';
import '../ai_assistant/copilot_dock.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/terminal_themes.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sshService,
    required this.serverName,
    required this.aiProvider,
    required this.apiKeyStorage,
    this.appPrefsStorage = const AppPrefsStorage(),
    required this.openRouterModel,
    this.localEndpoint,
    this.localModel,
    this.serverId,
    this.vaultStorage,
  });

  final SshService sshService;
  final String serverName;
  final AiProvider aiProvider;
  final ApiKeyStorage apiKeyStorage;
  final AppPrefsStorage appPrefsStorage;
  final String? openRouterModel;
  final String? localEndpoint;
  final String? localModel;

  /// Used to scope vault-secret lookup. When null, only global
  /// (unscoped) secrets are visible to this terminal.
  final String? serverId;

  /// Injectable for tests. Defaults to `VaultStorage()` at runtime.
  final VaultStorage? vaultStorage;

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

  // Terminal Customization State
  double _fontSize = 13.0;
  String _fontFamily = 'JetBrains Mono';
  String _themeName = 'brutalist';

  late final VaultStorage _vaultStorage;
  // Snapshot of secrets visible to this server (global + scoped).
  // Refreshed whenever VaultChangeBus fires.
  List<VaultSecret> _vaultSecrets = const [];
  VaultRedactor _vaultRedactor = VaultRedactor.empty;
  // Carry-buffered redactors for the SSH stdout/stderr streams. SSH
  // chunks are arbitrary, so a secret can straddle two of them; a
  // per-chunk redact() would emit the leading half before the second
  // chunk arrived. See StreamingVaultRedactor.
  final StreamingVaultRedactor _stdoutRedactor =
      StreamingVaultRedactor(VaultRedactor.empty);
  final StreamingVaultRedactor _stderrRedactor =
      StreamingVaultRedactor(VaultRedactor.empty);
  StreamSubscription<void>? _vaultSub;

  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = _handleTerminalOutput;
    _terminal.onResize = _handleTerminalResize;

    _loadTerminalPreferences();

    widget.sshService.statusNotifier.addListener(_handleStatusChange);

    _vaultStorage = widget.vaultStorage ?? VaultStorage();
    _vaultSub = VaultChangeBus.instance.changes.listen(
      (_) => _refreshVaultSnapshot(),
    );
    // Best-effort: prime the snapshot. Failure here only means the
    // first few keystrokes won't be redacted; the change bus fires
    // again as soon as the vault loads.
    _refreshVaultSnapshot();

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

  Future<void> _loadTerminalPreferences() async {
    final size = await widget.appPrefsStorage.getTerminalFontSize();
    final family = await widget.appPrefsStorage.getTerminalFontFamily();
    final theme = await widget.appPrefsStorage.getTerminalTheme();
    if (!mounted) return;
    setState(() {
      _fontSize = size;
      _fontFamily = family;
      _themeName = theme;
    });
  }

  @override
  void dispose() {
    widget.sshService.statusNotifier.removeListener(_handleStatusChange);
    _vaultSub?.cancel();
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _session?.close();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  Future<void> _refreshVaultSnapshot() async {
    try {
      final loaded = await _vaultStorage.loadVisibleTo(widget.serverId);
      if (!mounted) return;
      _vaultSecrets = List.unmodifiable(loaded);
      _vaultRedactor = VaultRedactor.from(_vaultSecrets);
      _stdoutRedactor.updateRedactor(_vaultRedactor);
      _stderrRedactor.updateRedactor(_vaultRedactor);
    } catch (_) {
      // Vault unavailable (e.g. test harness with no secure-storage
      // plugin). Leave the empty redactor in place and carry on —
      // the terminal must keep working even if the vault is broken.
    }
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
        // Stream through a carry-buffered redactor so a secret split
        // across SSH chunks is still caught before either half is
        // emitted to xterm or the AI-context buffer.
        final text = _stdoutRedactor.feed(
          utf8.decode(data, allowMalformed: true),
        );
        if (text.isEmpty) return;
        _terminal.write(text);
        _trackOutput(text);
      });

      _stderrSubscription?.cancel();
      _stderrSubscription = session.stderr.listen((data) {
        final text = _stderrRedactor.feed(
          utf8.decode(data, allowMalformed: true),
        );
        if (text.isEmpty) return;
        _terminal.write(text);
        _trackOutput(text);
      });

      session.done.then((_) {
        if (!mounted) return;
        // Flush any held-back carry so a trailing secret at EOF is
        // still scrubbed before the closing banner.
        final tailOut = _stdoutRedactor.flush();
        final tailErr = _stderrRedactor.flush();
        if (tailOut.isNotEmpty) {
          _terminal.write(tailOut);
          _trackOutput(tailOut);
        }
        if (tailErr.isNotEmpty) {
          _terminal.write(tailErr);
          _trackOutput(tailErr);
        }
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
    Widget buildBody(BuildContext _) => AiCopilotSheet(
          serverId: widget.serverName,
          provider: widget.aiProvider,
          apiKeyStorage: widget.apiKeyStorage,
          openRouterModel: widget.openRouterModel,
          localEndpoint: widget.localEndpoint,
          localModel: widget.localModel,
          executionTarget: AiCopilotExecutionTarget.terminal,
          canRunCommands: () =>
              _session != null && widget.sshService.isConnected,
          getContext: () => _recentTerminalOutput,
          onRunCommand: (cmd) async {
            // Route through the non-interactive exec path so the
            // resolved command bytes never enter the TTY echo stream
            // or the remote shell history. The pane shows the
            // placeholder form + redacted output.
            _terminal.write('\r\n\$ $cmd\r\n');
            try {
              final out = await widget.sshService.execute(
                cmd,
                vaultSecrets: _vaultSecrets,
              );
              _terminal.write('${_vaultRedactor.redact(out)}\r\n');
              return out;
            } on VaultInjectionException catch (e) {
              _terminal.write('[vault: ${e.message}]\r\n');
              return null;
            } catch (e) {
              _terminal.write('[error: $e]\r\n');
              return null;
            }
          },
          executionUnavailableMessage:
              'Commands can only be run when the terminal is connected.',
        );

    // Dock at desktop widths when a CopilotDock is installed; else modal.
    final dock = CopilotDock.maybeOf(context);
    if (dock != null && Breakpoints.isDesktop(context)) {
      dock.open(
        CopilotDockRequest(
          title: 'AI COPILOT — ${widget.serverName.toUpperCase()}',
          builder: buildBody,
        ),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.82,
        child: buildBody(context),
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
    final terminalTheme = AppTerminalThemes.get(_themeName);

    return Scaffold(
      backgroundColor: terminalTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: null,
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
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _terminalFocusNode.requestFocus(),
              child: Container(
                margin: EdgeInsets.symmetric(
                  horizontal: _isDesktop ? 16 : 8,
                  vertical: _isDesktop ? 0 : 8,
                ),
                decoration: const BoxDecoration(
                  color: Colors.black,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.zero,
                  child: TerminalView(
                    _terminal,
                    focusNode: _terminalFocusNode,
                    autofocus: true,
                    theme: terminalTheme,
                    textStyle: TerminalStyle(
                      fontSize: _fontSize,
                      fontFamily: _fontFamily,
                    ),
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

  // Removed redundant _buildStatusHeader as information is in the sidebar.

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
