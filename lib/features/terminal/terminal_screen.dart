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
  static const _maxContextLines = 30;
  static const _autoFixContextLines = 80;
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);
  static const _ctrlActiveColor = Color(0xFF3B82F6);
  static const _altActiveColor = Color(0xFFF59E0B);
  static final RegExp _ansiEscapePattern = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );
  static final RegExp _controlCharPattern = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',
  );
  static final RegExp _errorPattern = RegExp(
    r'(error|failed|exception|denied|not found|permission|timed out|refused|closed)',
    caseSensitive: false,
  );

  late final Terminal _terminal;

  SSHSession? _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  String _status = 'Opening shell...';
  String _recentTerminalOutput = '';
  String _currentInputBuffer = '';
  String? _lastUserCommand;
  String? _lastVisibleError;
  bool _ctrlEnabled = false;
  bool _altEnabled = false;
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();

    _terminal = Terminal(maxLines: 10000);

    _terminal.write('Connecting interactive shell...\r\n');
    _terminal.onOutput = _handleTerminalInput;
    _terminal.onResize = _handleTerminalResize;

    _connectionSubscription = widget.sshService.connectionState.listen((
      connected,
    ) {
      if (!connected && _session != null) {
        setState(() {
          _status = 'Connection lost';
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openShell();
    });
  }

  @override
  void dispose() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _connectionSubscription?.cancel();
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
          .listen(_handleStdoutChunk);

      _stderrSubscription = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_handleStderrChunk);

      session.done.then((_) {
        if (!mounted) {
          return;
        }

        setState(() {
          _session = null;
          _status = 'Shell closed';
          _ctrlEnabled = false;
          _altEnabled = false;
        });
        _handleTerminalChunk('\r\n[session closed]\r\n');
      });

      setState(() {
        _session = session;
        _status = 'Interactive shell connected';
        _isReconnecting = false;
      });

      _handleTerminalResize(_terminal.viewWidth, _terminal.viewHeight, 0, 0);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _session = null;
        _status = 'Failed to open shell';
        _ctrlEnabled = false;
        _altEnabled = false;
        _isReconnecting = false;
      });
      _handleTerminalChunk(
        'Failed to open shell.\r\n$error\r\n',
        isError: true,
      );
    }
  }

  Future<void> _handleReconnect() async {
    if (_isReconnecting) {
      return;
    }

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
      _handleTerminalChunk('Reconnection failed: $e\r\n', isError: true);
    }
  }

  void _handleTerminalInput(String data) {
    _dispatchInput(data, trackInput: true, applyPendingModifiers: true);
  }

  void _dispatchInput(
    String data, {
    required bool trackInput,
    required bool applyPendingModifiers,
  }) {
    final session = _session;
    if (session == null || data.isEmpty) {
      return;
    }

    final hasPendingModifier = _ctrlEnabled || _altEnabled;
    if (trackInput && !hasPendingModifier) {
      _trackUserInput(data);
    }

    final payload = applyPendingModifiers ? _applyPendingModifiers(data) : data;
    session.write(Uint8List.fromList(utf8.encode(payload)));
  }

  String _applyPendingModifiers(String data) {
    if (!_ctrlEnabled && !_altEnabled) {
      return data;
    }

    final firstRune = data.runes.first;
    final firstCharacter = String.fromCharCode(firstRune);
    final remainingCharacters = data.substring(firstCharacter.length);
    var payload = firstCharacter;

    if (_ctrlEnabled) {
      final ctrlPayload = _applyCtrlModifier(payload);
      if (ctrlPayload != null) {
        payload = ctrlPayload;
      }
    }

    if (_altEnabled) {
      payload = '\x1b$payload';
    }

    if (mounted) {
      setState(() {
        _ctrlEnabled = false;
        _altEnabled = false;
      });
    }

    return '$payload$remainingCharacters';
  }

  String? _applyCtrlModifier(String data) {
    if (data.length != 1) {
      return null;
    }

    final charCode = data.toLowerCase().codeUnitAt(0);

    if (charCode >= 97 && charCode <= 122) {
      return String.fromCharCode(charCode - 96);
    }

    switch (data) {
      case '@':
        return String.fromCharCode(0);
      case '[':
        return String.fromCharCode(27);
      case '\\':
        return String.fromCharCode(28);
      case ']':
        return String.fromCharCode(29);
      case '^':
      case '~':
        return String.fromCharCode(30);
      case '/':
      case '-':
      case '_':
        return String.fromCharCode(31);
      case '?':
        return String.fromCharCode(127);
      default:
        return null;
    }
  }

  void _toggleCtrl() {
    setState(() {
      _ctrlEnabled = !_ctrlEnabled;
    });
  }

  void _toggleAlt() {
    setState(() {
      _altEnabled = !_altEnabled;
    });
  }

  void _sendToolbarCharacter(String data) {
    _dispatchInput(data, trackInput: true, applyPendingModifiers: true);
  }

  void _sendToolbarControl(String data) {
    _dispatchInput(data, trackInput: false, applyPendingModifiers: false);
  }

  void _handleStdoutChunk(String data) {
    _handleTerminalChunk(data);
  }

  void _handleStderrChunk(String data) {
    _handleTerminalChunk(data, isError: true);
  }

  void _handleTerminalChunk(String data, {bool isError = false}) {
    _terminal.write(data);
    _appendRecentTerminalOutput(data, isError: isError);
  }

  void _appendRecentTerminalOutput(String chunk, {bool isError = false}) {
    final sanitizedChunk = _sanitizeTerminalText(chunk);
    if (sanitizedChunk.trim().isEmpty) {
      return;
    }

    _recentTerminalOutput += sanitizedChunk.replaceAll('\r', '\n');
    if (_recentTerminalOutput.length > _maxContextChars * 2) {
      _recentTerminalOutput = _recentTerminalOutput.substring(
        _recentTerminalOutput.length - (_maxContextChars * 2),
      );
    }

    final lines =
        _recentTerminalOutput
            .split('\n')
            .map((line) => line.trimRight())
            .where(_shouldKeepContextLine)
            .toList();
    final filteredLines = <String>[];
    for (final line in lines) {
      if (filteredLines.isEmpty || filteredLines.last != line) {
        filteredLines.add(line);
      }
    }

    final trimmedLines =
        filteredLines.length > _maxContextLines
            ? filteredLines.sublist(filteredLines.length - _maxContextLines)
            : filteredLines;

    _recentTerminalOutput = trimmedLines.join('\n');
    if (_recentTerminalOutput.length > _maxContextChars) {
      _recentTerminalOutput = _recentTerminalOutput.substring(
        _recentTerminalOutput.length - _maxContextChars,
      );
    }

    String? latestError;
    for (final line in trimmedLines.reversed) {
      final normalizedLine = line.trim();
      if (normalizedLine.isEmpty) {
        continue;
      }

      if (isError || _errorPattern.hasMatch(normalizedLine)) {
        latestError = normalizedLine;
        break;
      }
    }

    if (latestError != null) {
      _lastVisibleError = latestError;
    }
  }

  void _trackUserInput(String data) {
    for (final rune in data.runes) {
      if (rune == 13 || rune == 10) {
        final command = _currentInputBuffer.trim();
        if (command.isNotEmpty) {
          _lastUserCommand = command;
        }
        _currentInputBuffer = '';
        continue;
      }

      if (rune == 8 || rune == 127) {
        if (_currentInputBuffer.isNotEmpty) {
          _currentInputBuffer = _currentInputBuffer.substring(
            0,
            _currentInputBuffer.length - 1,
          );
        }
        continue;
      }

      if (rune == 27 || rune < 32) {
        continue;
      }

      _currentInputBuffer += String.fromCharCode(rune);
      if (_currentInputBuffer.length > 200) {
        _currentInputBuffer = _currentInputBuffer.substring(
          _currentInputBuffer.length - 200,
        );
      }
    }
  }

  String _sanitizeTerminalText(String text) {
    final withoutAnsi = text.replaceAll(_ansiEscapePattern, '');
    return withoutAnsi.replaceAll(_controlCharPattern, '');
  }

  bool _shouldKeepContextLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return false;
    }

    if (trimmed == 'Connecting interactive shell...' ||
        trimmed == '[session closed]') {
      return false;
    }

    if (_lastUserCommand != null && trimmed == _lastUserCommand!.trim()) {
      return false;
    }

    final looksLikePrompt =
        RegExp(r'^[^\s@]+@[^\s:]+:.*[#$]$').hasMatch(trimmed) ||
        RegExp(r'^[A-Za-z0-9._/-]+[#$>]$').hasMatch(trimmed);

    return !looksLikePrompt;
  }

  String _buildRecentTerminalContext({
    String? terminalTextOverride,
    bool useBufferLabel = false,
  }) {
    final parts = <String>[];

    if (_lastUserCommand != null && _lastUserCommand!.isNotEmpty) {
      parts.add('Last user command:\n$_lastUserCommand');
    }

    if (_lastVisibleError != null && _lastVisibleError!.isNotEmpty) {
      parts.add('Last visible error:\n$_lastVisibleError');
    }

    final recentOutput = (terminalTextOverride ?? _recentTerminalOutput).trim();
    if (recentOutput.isNotEmpty) {
      parts.add(
        '${useBufferLabel ? 'Recent terminal buffer' : 'Recent terminal output'}:\n$recentOutput',
      );
    }

    return parts.isEmpty
        ? 'No recent terminal context available.'
        : parts.join('\n\n');
  }

  String getRecentTerminalContext() {
    return _buildRecentTerminalContext();
  }

  String _extractRecentTerminalBuffer() {
    final normalizedBuffer = _sanitizeTerminalText(
      _terminal.buffer
          .getText()
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n'),
    );
    final lines =
        normalizedBuffer
            .split('\n')
            .map((line) => line.trimRight())
            .where((line) => line.trim().isNotEmpty)
            .toList();
    final trimmedLines =
        lines.length > _autoFixContextLines
            ? lines.sublist(lines.length - _autoFixContextLines)
            : lines;
    return trimmedLines.join('\n').trim();
  }

  void _handleTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _session?.resizeTerminal(width, height, pixelWidth, pixelHeight);
  }

  Future<void> _sendCommandToShell(String command, {bool addNewline = true}) async {
    final session = _session;
    if (session == null) {
      return;
    }

    final payload = addNewline ? '$command\n' : command;
    session.write(Uint8List.fromList(utf8.encode(payload)));
  }

  Future<String?> _runCopilotCommand(String command) async {
    await _sendCommandToShell(command);
    return null;
  }

  Future<void> _openCopilot({
    String? initialPrompt,
    String? contextOverride,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) {
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: AiCopilotSheet(
            serverId: widget.serverName,
            provider: widget.aiProvider,
            apiKeyStorage: widget.apiKeyStorage,
            openRouterModel: widget.openRouterModel,
            initialPrompt: initialPrompt,
            executionTarget: AiCopilotExecutionTarget.terminal,
            canRunCommands: () => _session != null,
            getContext:
                contextOverride == null
                    ? getRecentTerminalContext
                    : () => contextOverride,
            onRunCommand: _runCopilotCommand,
            executionUnavailableMessage:
                'Terminal shell is disconnected. Reconnect before running commands.',
          ),
        );
      },
    );
  }

  Future<void> _openAutoFixCopilot() async {
    final terminalBuffer = _extractRecentTerminalBuffer();
    final fallbackContext =
        terminalBuffer.isEmpty ? _recentTerminalOutput : terminalBuffer;
    final promptContext =
        terminalBuffer.isEmpty
            ? 'No recent terminal output was available.'
            : terminalBuffer;

    await _openCopilot(
      initialPrompt:
          'I am getting an error in my terminal. Analyze this recent output and provide the exact command to fix it:\n\n$promptContext',
      contextOverride: _buildRecentTerminalContext(
        terminalTextOverride: fallbackContext,
        useBufferLabel: true,
      ),
    );
  }

  List<_TerminalToolbarKey> _toolbarKeys() {
    return [
      _TerminalToolbarKey(
        label: 'ESC',
        onPressed: () => _sendToolbarControl('\x1b'),
      ),
      _TerminalToolbarKey(
        label: 'CTRL',
        isActive: _ctrlEnabled,
        activeColor: _ctrlActiveColor,
        onPressed: _toggleCtrl,
      ),
      _TerminalToolbarKey(
        label: 'ALT',
        isActive: _altEnabled,
        activeColor: _altActiveColor,
        onPressed: _toggleAlt,
      ),
      _TerminalToolbarKey(
        label: 'TAB',
        onPressed: () => _sendToolbarControl('\t'),
      ),
      _TerminalToolbarKey(
        label: '↑',
        semanticLabel: 'Up',
        onPressed: () => _sendToolbarControl('\x1b[A'),
      ),
      _TerminalToolbarKey(
        label: '↓',
        semanticLabel: 'Down',
        onPressed: () => _sendToolbarControl('\x1b[B'),
      ),
      _TerminalToolbarKey(
        label: '←',
        semanticLabel: 'Left',
        onPressed: () => _sendToolbarControl('\x1b[D'),
      ),
      _TerminalToolbarKey(
        label: '→',
        semanticLabel: 'Right',
        onPressed: () => _sendToolbarControl('\x1b[C'),
      ),
      _TerminalToolbarKey(
        label: '-',
        onPressed: () => _sendToolbarCharacter('-'),
      ),
      _TerminalToolbarKey(
        label: '/',
        onPressed: () => _sendToolbarCharacter('/'),
      ),
      _TerminalToolbarKey(
        label: '|',
        onPressed: () => _sendToolbarCharacter('|'),
      ),
    ];
  }

  Widget _buildStatusHeader(ThemeData theme) {
    final isConnected = _session != null;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: _shadowColor, blurRadius: 18, offset: Offset(0, 10)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: isConnected ? const Color(0xFF22C55E) : _mutedColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _mutedColor,
                height: 1.4,
              ),
            ),
          ),
          if (!isConnected && !_isReconnecting)
            TextButton.icon(
              onPressed: _handleReconnect,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reconnect'),
              style: TextButton.styleFrom(
                foregroundColor: _ctrlActiveColor,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSnippetBar() {
    final snippets = [
      'sudo ',
      '| grep ',
      ' -la',
      'tail -f ',
      'mkdir ',
      'rm -rf ',
      'cd ',
    ];

    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: _panelColor,
        border: Border(top: BorderSide(color: Color(0xFF1E293B))),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: snippets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final snippet = snippets[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _sendCommandToShell(snippet, addNewline: false),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _surfaceColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Center(
                  child: Text(
                    snippet,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildToolbar() {
    final keys = _toolbarKeys();

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSnippetBar(),
          Container(
            height: 78,
            decoration: const BoxDecoration(
              color: _panelColor,
              border: Border(top: BorderSide(color: Color(0xFF243247))),
              boxShadow: [
                BoxShadow(
                  color: _shadowColor,
                  blurRadius: 18,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              scrollDirection: Axis.horizontal,
              itemCount: keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final key = keys[index];
                return _TerminalToolbarButton(
                  label: key.label,
                  semanticLabel: key.semanticLabel,
                  isActive: key.isActive,
                  activeColor: key.activeColor,
                  onPressed: key.onPressed,
                );
              },
            ),
          ),
        ],
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
            onPressed: _openAutoFixCopilot,
            icon: const Icon(Icons.auto_fix_high, color: Color(0xFFF59E0B)),
            tooltip: 'AI Auto-Fix',
          ),
          IconButton(
            onPressed: _openCopilot,
            icon: const Icon(Icons.smart_toy_outlined),
            tooltip: 'AI Copilot',
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildStatusHeader(theme),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: ColoredBox(
                      color: _backgroundColor,
                      child: SafeArea(
                        top: false,
                        bottom: false,
                        child: TerminalView(
                          _terminal,
                          autofocus: true,
                          backgroundOpacity: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildToolbar(),
            ],
          ),
          if (_isReconnecting || (!widget.sshService.isConnected && _session != null))
            Positioned.fill(
              child: Container(
                color: _backgroundColor.withValues(alpha: 0.7),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: _ctrlActiveColor),
                      const SizedBox(height: 16),
                      Text(
                        _isReconnecting ? 'Reconnecting...' : 'Connection Lost',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
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

class _TerminalToolbarKey {
  const _TerminalToolbarKey({
    this.label,
    this.semanticLabel,
    this.isActive = false,
    this.activeColor,
    required this.onPressed,
  });

  final String? label;
  final String? semanticLabel;
  final bool isActive;
  final Color? activeColor;
  final VoidCallback onPressed;
}

class _TerminalToolbarButton extends StatelessWidget {
  const _TerminalToolbarButton({
    required this.label,
    required this.semanticLabel,
    required this.isActive,
    required this.activeColor,
    required this.onPressed,
  });

  final String? label;
  final String? semanticLabel;
  final bool isActive;
  final Color? activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final resolvedActiveColor =
        activeColor ?? _TerminalScreenState._ctrlActiveColor;

    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            width: 52,
            decoration: BoxDecoration(
              color:
                  isActive
                      ? resolvedActiveColor.withValues(alpha: 0.18)
                      : _TerminalScreenState._surfaceColor,
              border: Border.all(
                color:
                    isActive
                        ? resolvedActiveColor.withValues(alpha: 0.4)
                        : const Color(0xFF334155),
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                label!,
                style: TextStyle(
                  color:
                      isActive
                          ? resolvedActiveColor
                          : _TerminalScreenState._mutedColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
