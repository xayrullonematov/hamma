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
  static final RegExp _ansiEscapePattern = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );
  static final RegExp _controlCharPattern = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');
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
      });
      _handleTerminalChunk('Failed to open shell.\r\n$error\r\n', isError: true);
    }
  }

  void _handleTerminalInput(String data) {
    _trackUserInput(data);

    final session = _session;
    if (session == null) {
      return;
    }

    session.write(Uint8List.fromList(utf8.encode(data)));
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

    final looksLikePrompt = RegExp(r'^[^\s@]+@[^\s:]+:.*[#$]$').hasMatch(trimmed) ||
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

    return parts.isEmpty ? 'No recent terminal context available.' : parts.join('\n\n');
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
