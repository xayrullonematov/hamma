import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xterm/xterm.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/ai/bundled_engine.dart';
import '../../core/ai/bundled_engine_controller.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/shell/shell_service.dart';
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

  final ShellService sshService;
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

class _TerminalScreenState extends State<TerminalScreen> with AutomaticKeepAliveClientMixin<TerminalScreen> {
  static const _maxContextChars = 3500;
  static final _panelColor = AppColors.panel;

  late final Terminal _terminal;
  final FocusNode _terminalFocusNode = FocusNode();
  dynamic _session;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  String _recentTerminalOutput = '';
  bool _isFullScreen = false;

  // FIX 1: live BundledEngine endpoint resolved asynchronously in initState.
  String? _resolvedLocalEndpoint;

  @override
  bool get wantKeepAlive => true;

  // Fish-shell style Tab Autocomplete State
  String _currentInput = '';
  List<String> _tabSuggestions = [];
  int _tabCycleIndex = -1;
  String _ghostText = '';

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

    // FIX 1: resolve the live BundledEngine loopback URL so _openCopilot
    // can hand the correct port to AiCopilotSheet / LocalEngineHealthMonitor.
    _resolveLocalEndpoint();

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

  /// Asks [BundledEngineController] for the live loopback URL the engine
  /// actually bound to (e.g. `http://127.0.0.1:54231`). Falls back to
  /// [widget.localEndpoint] (the value saved in Settings) when the engine
  /// hasn't been started or is unavailable on this build.
  ///
  /// Called once from [initState]; no-op if the engine returns null.
  Future<void> _resolveLocalEndpoint() async {
    if (widget.aiProvider != AiProvider.local) return;
    try {
      final engine = await BundledEngineController.instance;
      final live = engine.endpoint; // null while engine is stopped
      if (mounted && live != null && live.isNotEmpty) {
        setState(() => _resolvedLocalEndpoint = live);
      }
    } catch (_) {
      // BundledEngine unavailable on this build (e.g. no native binary).
      // Fall through: _effectiveLocalEndpoint returns widget.localEndpoint.
    }
  }

  /// The endpoint handed to [AiCopilotSheet] / [LocalEngineHealthMonitor].
  ///
  /// Priority:
  ///   1. Live BundledEngine URL (resolved asynchronously in [initState]).
  ///   2. Persisted value from Settings (covers external Ollama / LM Studio).
  String? get _effectiveLocalEndpoint =>
      (_resolvedLocalEndpoint?.isNotEmpty ?? false)
          ? _resolvedLocalEndpoint
          : widget.localEndpoint;

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
      // Ensure session is nulled if we transition to disconnected, failed,
      // or reconnecting states.
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
      final dynamic session = await widget.sshService.startShell(
        width: math.max(80, _terminal.viewWidth),
        height: math.max(24, _terminal.viewHeight),
      );

      _stdoutSubscription?.cancel();
      _stdoutSubscription = (session.stdout as Stream<Uint8List>).listen((data) {
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
      _stderrSubscription = (session.stderr as Stream<Uint8List>).listen((data) {
        final text = _stderrRedactor.feed(
          utf8.decode(data, allowMalformed: true),
        );
        if (text.isEmpty) return;
        _terminal.write(text);
        _trackOutput(text);
      });

      (session.done as Future).then((_) {
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

    // Track the current input for suggestions
    for (int i = 0; i < data.length; i++) {
      final char = data[i];
      if (char == '\r' || char == '\n') {
        _currentInput = '';
      } else if (char == '\x7f' || char == '\x08') {
        // Backspace
        if (_currentInput.isNotEmpty) {
          _currentInput = _currentInput.substring(0, _currentInput.length - 1);
        }
      } else if (char == '\t') {
        // Tab - instructions say do NOT append to _currentInput
      } else if (char.codeUnitAt(0) >= 32 && char.codeUnitAt(0) <= 126) {
        _currentInput += char;
      }
    }

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

  void _sendToolbarKey(String data) {
    _handleTerminalOutput(data);
  }

  Future<void> _openCopilot() async {
    Widget buildBody(BuildContext _) => AiCopilotSheet(
          serverId: widget.serverName,
          provider: widget.aiProvider,
          apiKeyStorage: widget.apiKeyStorage,
          openRouterModel: widget.openRouterModel,
          localEndpoint: _effectiveLocalEndpoint, // FIX 1: was widget.localEndpoint
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
          isModal: !Breakpoints.isDesktop(context),
        );

    // Dock at desktop widths when a CopilotDock is installed; else modal.
    final dock = CopilotDock.maybeOf(context);
    if (dock != null && Breakpoints.isDesktop(context)) {
      dock.open(
        CopilotDockRequest(
          title: widget.serverName.toUpperCase(),
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

    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;

    if (event.logicalKey == LogicalKeyboardKey.tab) {
      // 1. Parse _currentInput
      final trimmedInput = _currentInput.trimLeft();
      if (trimmedInput.isEmpty) return KeyEventResult.ignored;

      final parts = trimmedInput.split(' ');
      final baseCommand = parts[0];
      final partialSuffix = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      // 2. Look up _suggestionMap[baseCommand]
      final suggestions = _suggestionMap[baseCommand];

      if (suggestions == null) {
        return KeyEventResult.ignored; // Let literal Tab through if no command match
      }

      // 3. Filter suggestions (case-insensitive)
      final filtered = suggestions
          .where((s) => s.toLowerCase().startsWith(partialSuffix.toLowerCase()))
          .toList();

      // 4. If no matches -> normal tab
      if (filtered.isEmpty) {
        return KeyEventResult.ignored;
      }

      // 5. If matches exist and _tabSuggestions is empty -> initialize
      if (_tabSuggestions.isEmpty) {
        _tabSuggestions = filtered;
        _tabCycleIndex = 0;
      } else {
        // 6. Else -> Cycle
        if (isShiftPressed) {
          _tabCycleIndex = (_tabCycleIndex - 1 + _tabSuggestions.length) % _tabSuggestions.length;
        } else {
          _tabCycleIndex = (_tabCycleIndex + 1) % _tabSuggestions.length;
        }
      }

      // 7. Set _ghostText
      setState(() {
        _ghostText = _tabSuggestions[_tabCycleIndex];
      });

      // 9. Return KeyEventResult.handled
      return KeyEventResult.handled;
    }

    if (_ghostText.isNotEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.space ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        // Calculate the suffix to type
        final parts = _currentInput.trimLeft().split(' ');
        final partialSuffix = parts.length > 1 ? parts.sublist(1).join(' ') : '';
        final suffix = _ghostText.substring(partialSuffix.length);

        // Send suffix to terminal
        _session?.write(Uint8List.fromList(utf8.encode(suffix)));

        // Reset
        setState(() {
          _ghostText = '';
          _tabSuggestions = [];
          _tabCycleIndex = -1;
          // Update _currentInput by simulating the suffix being typed
          _handleTerminalOutput(suffix);
        });

        return KeyEventResult.ignored;
      }

      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _ghostText = '';
          _tabSuggestions = [];
          _tabCycleIndex = -1;
        });
        return KeyEventResult.handled;
      }

      // On any other key when _ghostText is not empty
      setState(() {
        _ghostText = '';
        _tabSuggestions = [];
        _tabCycleIndex = -1;
      });
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
            tooltip: 'Copilot',
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
              if (_isDesktop && _ghostText.isNotEmpty)
                Container(
                  color: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      // Ghost text: dim accepted portion
                      Text(
                        _currentInput.split(' ').length > 1 ? _currentInput.split(' ').last : '',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontFamily: AppColors.monoFamily,
                          fontSize: 13,
                        ),
                      ),
                      // Active ghost suggestion in white
                      Text(
                        _ghostText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: AppColors.monoFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // All other suggestions dimmed
                      ..._tabSuggestions
                          .where((s) => s != _ghostText)
                          .take(5)
                          .map((s) => Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Text(
                                  s,
                                  style: const TextStyle(
                                    color: Colors.white24,
                                    fontFamily: AppColors.monoFamily,
                                    fontSize: 13,
                                  ),
                                ),
                              )),
                      const Spacer(),
                      // Key hint
                      const Text(
                        'TAB / SHIFT+TAB to cycle  ·  SPACE to accept',
                        style: TextStyle(
                          color: Colors.white24,
                          fontFamily: AppColors.monoFamily,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ValueListenableBuilder<ConnectionStatus>(
                valueListenable: widget.sshService.statusNotifier,
                builder: (context, status, _) => _buildToolbar(status.isConnected),
              ),
              if (_isDesktop) const SizedBox(height: 16),
            ],
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
