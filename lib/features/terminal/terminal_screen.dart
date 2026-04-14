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
  static const _maxContextChars = 3500;
  static const _maxContextLines = 30;
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);
  static final RegExp _ansiEscapePattern = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );
  static final RegExp _controlCharPattern =
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');
  static final RegExp _errorPattern = RegExp(
    r'(error|failed|exception|denied|not found|permission|timed out|refused|closed)',
    caseSensitive: false,
  );

  late final Terminal _terminal;

  SSHSession? _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  String _status = 'Opening shell...';
  String _recentTerminalOutput = '';
  String _currentInputBuffer = '';
  String? _lastUserCommand;
  String? _lastVisibleError;
  bool _ctrlEnabled = false;
  bool _altEnabled = false;

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
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _session = null;
        _status = 'Failed to open shell';
        _ctrlEnabled = false;
        _altEnabled = false;
      });
      _handleTerminalChunk('Failed to open shell.\r\n$error\r\n', isError: true);
    }
  }

  void _handleTerminalInput(String data) {
    _dispatchInput(data, trackInput: true);
  }

  void _dispatchInput(String data, {required bool trackInput}) {
    final session = _session;
    if (session == null || data.isEmpty) {
      return;
    }

    final hasPendingModifier = _ctrlEnabled || _altEnabled;
    if (trackInput && !hasPendingModifier) {
      _trackUserInput(data);
    }

    final payload = _applyPendingModifiers(data);
    session.write(Uint8List.fromList(utf8.encode(payload)));
  }

  String _applyPendingModifiers(String data) {
    if (!_ctrlEnabled && !_altEnabled) {
      return data;
    }

    var payload = data;

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

    return payload;
  }

  String? _applyCtrlModifier(String data) {
    if (data.length != 1) {
      return null;
    }

    final char = data.codeUnitAt(0);
    final symbol = data;

    if ((char >= 65 && char <= 90) || (char >= 97 && char <= 122)) {
      return String.fromCharCode(char & 0x1f);
    }

    switch (symbol) {
      case '@':
        return String.fromCharCode(0);
      case '[':
        return String.fromCharCode(27);
      case r'\':
        return String.fromCharCode(28);
      case ']':
        return String.fromCharCode(29);
      case '^':
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
      if (_ctrlEnabled) {
        _altEnabled = false;
      }
    });
  }

  void _toggleAlt() {
    setState(() {
      _altEnabled = !_altEnabled;
      if (_altEnabled) {
        _ctrlEnabled = false;
      }
    });
  }

  void _sendToolbarInput(String data, {bool trackInput = false}) {
    _dispatchInput(data, trackInput: trackInput);
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

    final lines = _recentTerminalOutput
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

    final trimmedLines = filteredLines.length > _maxContextLines
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

  String getRecentTerminalContext() {
    final parts = <String>[];

    if (_lastUserCommand != null && _lastUserCommand!.isNotEmpty) {
      parts.add('Last user command:\n$_lastUserCommand');
    }

    if (_lastVisibleError != null && _lastVisibleError!.isNotEmpty) {
      parts.add('Last visible error:\n$_lastVisibleError');
    }

    final recentOutput = _recentTerminalOutput.trim();
    if (recentOutput.isNotEmpty) {
      parts.add('Recent terminal output:\n$recentOutput');
    }

    return parts.isEmpty
        ? 'No recent terminal context available.'
        : parts.join('\n\n');
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

  Future<String?> _runCopilotCommand(String command) async {
    await _sendCommandToShell(command);
    return null;
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
            executionTarget: AiCopilotExecutionTarget.terminal,
            canRunCommands: () => _session != null,
            getContext: getRecentTerminalContext,
            onRunCommand: _runCopilotCommand,
            executionUnavailableMessage:
                'Terminal shell is disconnected. Reconnect before running commands.',
          ),
        );
      },
    );
  }

  List<_TerminalToolbarKey> _toolbarKeys() {
    return [
      _TerminalToolbarKey(
        label: 'Esc',
        onPressed: () => _sendToolbarInput('\x1b'),
      ),
      _TerminalToolbarKey(
        label: 'Tab',
        onPressed: () => _sendToolbarInput('\t'),
      ),
      _TerminalToolbarKey(
        label: 'Ctrl',
        isToggle: true,
        isActive: _ctrlEnabled,
        onPressed: _toggleCtrl,
      ),
      _TerminalToolbarKey(
        label: 'Alt',
        isToggle: true,
        isActive: _altEnabled,
        onPressed: _toggleAlt,
      ),
      _TerminalToolbarKey(
        label: '/',
        onPressed: () => _sendToolbarInput('/', trackInput: true),
      ),
      _TerminalToolbarKey(
        label: '-',
        onPressed: () => _sendToolbarInput('-', trackInput: true),
      ),
      _TerminalToolbarKey(
        icon: Icons.keyboard_arrow_up_rounded,
        semanticLabel: 'Up',
        onPressed: () => _sendToolbarInput('\x1b[A'),
      ),
      _TerminalToolbarKey(
        icon: Icons.keyboard_arrow_down_rounded,
        semanticLabel: 'Down',
        onPressed: () => _sendToolbarInput('\x1b[B'),
      ),
      _TerminalToolbarKey(
        icon: Icons.keyboard_arrow_left_rounded,
        semanticLabel: 'Left',
        onPressed: () => _sendToolbarInput('\x1b[D'),
      ),
      _TerminalToolbarKey(
        icon: Icons.keyboard_arrow_right_rounded,
        semanticLabel: 'Right',
        onPressed: () => _sendToolbarInput('\x1b[C'),
      ),
    ];
  }

  Widget _buildStatusHeader(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: _shadowColor,
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _session != null ? const Color(0xFF22C55E) : _mutedColor,
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
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final keys = _toolbarKeys();

    return SafeArea(
      top: false,
      child: Container(
        height: 72,
        decoration: const BoxDecoration(
          color: _surfaceColor,
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
              icon: key.icon,
              semanticLabel: key.semanticLabel,
              isActive: key.isActive,
              onPressed: key.onPressed,
            );
          },
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
            tooltip: 'AI Copilot',
          ),
        ],
      ),
      body: Column(
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
    this.icon,
    this.semanticLabel,
    this.isToggle = false,
    this.isActive = false,
    required this.onPressed,
  });

  final String? label;
  final IconData? icon;
  final String? semanticLabel;
  final bool isToggle;
  final bool isActive;
  final VoidCallback onPressed;
}

class _TerminalToolbarButton extends StatelessWidget {
  const _TerminalToolbarButton({
    required this.label,
    required this.icon,
    required this.semanticLabel,
    required this.isActive,
    required this.onPressed,
  });

  final String? label;
  final IconData? icon;
  final String? semanticLabel;
  final bool isActive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Ink(
            width: 56,
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF3B82F6).withValues(alpha: 0.18)
                  : _TerminalScreenState._panelColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: icon != null
                  ? Icon(
                      icon,
                      color: isActive
                          ? const Color(0xFF3B82F6)
                          : _TerminalScreenState._mutedColor,
                    )
                  : Text(
                      label!,
                      style: TextStyle(
                        color: isActive
                            ? const Color(0xFF3B82F6)
                            : _TerminalScreenState._mutedColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
