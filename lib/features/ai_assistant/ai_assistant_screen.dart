import 'package:flutter/material.dart';

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/command_risk_assessor.dart';
import '../../core/ssh/ssh_service.dart';

class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({
    super.key,
    required this.sshService,
    required this.apiKey,
  });

  final SshService sshService;
  final String apiKey;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  late AiCommandService _aiCommandService;
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();
  final TextEditingController _promptController = TextEditingController();

  bool _isGenerating = false;
  bool _connectionLost = false;
  int? _runningCommandIndex;
  List<TextEditingController> _commandControllers = [];
  final List<_ExecutionHistoryEntry> _history = [];
  String _status = 'Describe the issue, then generate suggested commands.';

  bool get _canExecuteCommands {
    return widget.sshService.isConnected && !_connectionLost;
  }

  String get _combinedOutput {
    if (_history.isEmpty) {
      return 'No command has been run yet.';
    }

    return _history.map((entry) {
      final stateLabel = entry.succeeded ? 'OK' : 'ERROR';
      return '[${_formatTimestamp(entry.executedAt)}] $stateLabel\n'
          'Command: ${entry.command}\n'
          '${entry.output}';
    }).join('\n\n------------------------------\n\n');
  }

  @override
  void initState() {
    super.initState();
    _aiCommandService = const AiCommandService().withApiKey(widget.apiKey);
  }

  @override
  void didUpdateWidget(covariant AiAssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey) {
      _aiCommandService = const AiCommandService().withApiKey(widget.apiKey);
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    for (final controller in _commandControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _generateCommands() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _status = 'Enter a prompt first';
      });
      return;
    }

    if (widget.apiKey.trim().isEmpty) {
      setState(() {
        _status = 'Set your API key in Settings before generating commands.';
      });
      return;
    }

    setState(() {
      _isGenerating = true;
      _status = 'Generating suggested commands';
    });

    try {
      final commands = await _aiCommandService.generateCommands(prompt);
      if (!mounted) {
        return;
      }

      for (final controller in _commandControllers) {
        controller.dispose();
      }

      setState(() {
        _commandControllers = commands
            .map((command) => TextEditingController(text: command))
            .toList();
        _status = 'Suggested commands ready';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to generate commands';
      });
      _appendHistory(
        command: 'Generate suggestions',
        output: error.toString(),
        succeeded: false,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _runCommand(int index) async {
    final command = _commandControllers[index].text.trim();
    await _runCommandText(command, index: index);
  }

  Future<void> _rerunCommand(String command) async {
    await _runCommandText(command);
  }

  Future<void> _runCommandText(String command, {int? index}) async {
    if (command.isEmpty) {
      setState(() {
        _status = 'Command cannot be empty';
      });
      return;
    }

    if (!_canExecuteCommands) {
      setState(() {
        _status = 'SSH connection lost. Return and reconnect before running commands.';
      });
      return;
    }

    final assessment = _riskAssessor.assess(command);
    final shouldRun = await _showConfirmationDialog(command, assessment);
    if (!shouldRun) {
      return;
    }

    setState(() {
      _runningCommandIndex = index;
      _status = 'Running command';
    });

    try {
      final output = await widget.sshService.execute(command);
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Command finished';
      });
      _appendHistory(
        command: command,
        output: output.isEmpty ? '(no output)' : output,
        succeeded: true,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      final message = error.toString();
      final disconnected = _looksLikeDisconnect(message);

      setState(() {
        if (disconnected) {
          _connectionLost = true;
          _status =
              'SSH connection lost. Return to the main screen and reconnect.';
        } else {
          _status = 'Command failed';
        }
      });

      _appendHistory(
        command: command,
        output: disconnected
            ? 'SSH connection lost while running the command.\n$message'
            : message,
        succeeded: false,
      );
    } finally {
      if (mounted) {
        setState(() {
          _runningCommandIndex = null;
        });
      }
    }
  }

  Future<bool> _showConfirmationDialog(
    String command,
    CommandRiskAssessment assessment,
  ) async {
    final color = _riskColor(assessment.level);

    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Confirm Command'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('This command will run on your server:'),
                  const SizedBox(height: 12),
                  SelectableText(command),
                  const SizedBox(height: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _riskLabel(assessment.level),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(assessment.explanation),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Run'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  void _appendHistory({
    required String command,
    required String output,
    required bool succeeded,
  }) {
    setState(() {
      _history.insert(
        0,
        _ExecutionHistoryEntry(
          command: command,
          output: output,
          executedAt: DateTime.now(),
          succeeded: succeeded,
        ),
      );

      if (_history.length > 8) {
        _history.removeLast();
      }
    });
  }

  String _formatTimestamp(DateTime time) {
    final year = time.year.toString().padLeft(4, '0');
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  String _riskLabel(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.safe:
        return 'SAFE';
      case CommandRiskLevel.warning:
        return 'WARNING';
      case CommandRiskLevel.dangerous:
        return 'DANGEROUS';
    }
  }

  Color _riskColor(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.safe:
        return const Color(0xFF15803D);
      case CommandRiskLevel.warning:
        return const Color(0xFFD97706);
      case CommandRiskLevel.dangerous:
        return const Color(0xFFDC2626);
    }
  }

  bool _looksLikeDisconnect(String message) {
    final normalized = message.toLowerCase();
    const patterns = [
      'not connected',
      'connection reset',
      'broken pipe',
      'socketexception',
      'connection closed',
      'channel is not open',
      'failed host handshake',
    ];

    return patterns.any(normalized.contains);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Assistant'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_canExecuteCommands)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'SSH is disconnected. You can still generate suggestions, but reconnect before running commands.',
                ),
              ),
            TextField(
              controller: _promptController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Ask anything about your server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _isGenerating ? null : _generateCommands,
              child: _isGenerating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Generate Fix'),
            ),
            const SizedBox(height: 12),
            Text(_status, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  Text('Suggested Commands', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (_commandControllers.isEmpty)
                    const Text('No suggestions yet.'),
                  ...List.generate(_commandControllers.length, (index) {
                    final controller = _commandControllers[index];
                    final command = controller.text;
                    final isRunning = _runningCommandIndex == index;
                    final assessment = _riskAssessor.assess(command);

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: controller,
                                maxLines: null,
                                onChanged: (_) {
                                  setState(() {});
                                },
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _riskColor(assessment.level)
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _riskLabel(assessment.level),
                                      style: TextStyle(
                                        color: _riskColor(assessment.level),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    assessment.explanation,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton(
                                  onPressed: _isGenerating ||
                                          isRunning ||
                                          !_canExecuteCommands
                                      ? null
                                      : () => _runCommand(index),
                                  child: isRunning
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Run'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  Text('Command Output', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _combinedOutput,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Recent Commands', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (_history.isEmpty)
                    const Text('No command history yet.'),
                  ..._history.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                entry.command,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${entry.succeeded ? 'Success' : 'Failed'} • ${_formatTimestamp(entry.executedAt)}',
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton(
                                  onPressed: _isGenerating || !_canExecuteCommands
                                      ? null
                                      : () => _rerunCommand(entry.command),
                                  child: const Text('Re-run'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExecutionHistoryEntry {
  const _ExecutionHistoryEntry({
    required this.command,
    required this.output,
    required this.executedAt,
    required this.succeeded,
  });

  final String command;
  final String output;
  final DateTime executedAt;
  final bool succeeded;
}
