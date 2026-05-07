import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const _panelColor = AppColors.panel;

  late final Terminal _terminal;
  final FocusNode _terminalFocusNode = FocusNode();
  SSHSession? _session;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  String _recentTerminalOutput = '';
  bool _isFullScreen = false;

  // Predictive Commands State
  String _currentLineBuffer = '';
  List<String> _suggestions = [];
  int _selectedSuggestionIndex = 0;

  static const Map<String, List<String>> _suggestionMap = {
    'git': ['status', 'add .', 'commit -m "', 'push', 'pull', 'log --oneline', 'checkout', 'branch', 'diff'],
    'docker': ['ps', 'images', 'logs -f', 'stop', 'start', 'restart', 'exec -it', 'system prune'],
    'systemctl': ['status', 'restart', 'start', 'stop', 'enable', 'disable', 'daemon-reload'],
    'apt': ['update', 'upgrade', 'install', 'remove', 'autoremove', 'search'],
    'ls': ['-la', '-lh', '-R'],
    'cd': ['..', '~', '/var/www', '/etc'],
    'npm': ['install', 'run dev', 'run build', 'start', 'test'],
    'pm2': ['status', 'logs', 'restart', 'stop', 'save'],
    'tail': ['-f', '-n 100'],
    'grep': ['-r', '-i'],
  };

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

    // Track the current line buffer for suggestions
    for (int i = 0; i < data.length; i++) {
      final char = data[i];
      if (char == '\r' || char == '\n') {
        _currentLineBuffer = '';
      } else if (char == '\x7f' || char == '\x08') {
        // Backspace
        if (_currentLineBuffer.isNotEmpty) {
          _currentLineBuffer =
              _currentLineBuffer.substring(0, _currentLineBuffer.length - 1);
        }
      } else if (char.codeUnitAt(0) >= 32 && char.codeUnitAt(0) <= 126) {
        _currentLineBuffer += char;
      }
    }

    _updateSuggestions();
    _session?.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _updateSuggestions() {
    if (!_isDesktop || _currentLineBuffer.isEmpty) {
      if (_suggestions.isNotEmpty) {
        setState(() {
          _suggestions = [];
          _selectedSuggestionIndex = 0;
        });
      }
      return;
    }

    final parts = _currentLineBuffer.trimLeft().split(' ');
    if (parts.isEmpty) return;

    final command = parts[0];
    final argumentPrefix = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    List<String> matches = [];
    if (parts.length == 1) {
      // Suggest command names
      matches =
          _suggestionMap.keys
              .where((k) => k.startsWith(command) && k != command)
              .toList();
    } else {
      // Suggest arguments for the current command
      final possibleArgs = _suggestionMap[command];
      if (possibleArgs != null) {
        matches = possibleArgs.where((a) => a.startsWith(argumentPrefix)).toList();
      }
    }

    if (!listEquals(_suggestions, matches)) {
      setState(() {
        _suggestions = matches;
        _selectedSuggestionIndex = 0;
      });
    }
  }

  void _acceptSuggestion() {
    if (_suggestions.isEmpty) return;
    final suggestion = _suggestions[_selectedSuggestionIndex];

    // Calculate what needs to be typed
    final parts = _currentLineBuffer.trimLeft().split(' ');
    String toAdd = '';
    
    if (parts.length == 1) {
      // Completing a command name
      toAdd = '${suggestion.substring(parts[0].length)} ';
    } else {
      // Completing an argument
      final argPrefix = parts.sublist(1).join(' ');
      toAdd = suggestion.substring(argPrefix.length);
    }

    if (toAdd.isNotEmpty) {
      _handleTerminalOutput(toAdd);
    }

    setState(() {
      _suggestions = [];
      _selectedSuggestionIndex = 0;
    });
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_suggestions.isEmpty) return KeyEventResult.ignored;

    final isControlPressed = HardwareKeyboard.instance.isControlPressed;

    if (isControlPressed && event.logicalKey == LogicalKeyboardKey.arrowRight) {
      setState(() {
        _selectedSuggestionIndex =
            (_selectedSuggestionIndex + 1) % _suggestions.length;
      });
      return KeyEventResult.handled;
    } else if (isControlPressed && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      setState(() {
        _selectedSuggestionIndex =
            (_selectedSuggestionIndex - 1 + _suggestions.length) %
            _suggestions.length;
      });
      return KeyEventResult.handled;
    } else if (isControlPressed && event.logicalKey == LogicalKeyboardKey.tab) {
      _acceptSuggestion();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _suggestions = [];
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: _handleKeyEvent,
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
              ),
              ValueListenableBuilder<ConnectionStatus>(
                valueListenable: widget.sshService.statusNotifier,
                builder: (context, status, _) => _buildToolbar(status.isConnected),
              ),
              if (_isDesktop) const SizedBox(height: 16),
            ],
          ),
          if (_isDesktop && _suggestions.isNotEmpty)
            Positioned(
              top: 0,
              right: 16,
              child: _buildPredictivePalette(),
            ),
        ],
      ),
    );
  }

  Widget _buildPredictivePalette() {
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: Colors.white,
            child: const Text(
              'COMMAND SUGGESTIONS',
              style: TextStyle(
                color: Colors.black,
                fontFamily: AppColors.monoFamily,
                fontWeight: FontWeight.w900,
                fontSize: 10,
                letterSpacing: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 4),
          ...List.generate(_suggestions.length, (index) {
            final isSelected = index == _selectedSuggestionIndex;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: isSelected ? Colors.white : Colors.transparent,
              child: Text(
                _suggestions[index],
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white,
                  fontFamily: AppColors.monoFamily,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            );
          }),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Colors.white24)),
            ),
            child: const Text(
              'CTRL+ARROWS TO NAV\nCTRL+TAB TO PICK',
              style: TextStyle(
                color: Colors.white54,
                fontFamily: AppColors.monoFamily,
                fontSize: 9,
                height: 1.4,
              ),
            ),
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
