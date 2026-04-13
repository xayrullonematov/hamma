import 'package:flutter/material.dart';

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/command_risk_assessor.dart';

class AiCopilotSheet extends StatefulWidget {
  const AiCopilotSheet({
    super.key,
    required this.provider,
    required this.apiKey,
    required this.canRunCommands,
    required this.onRunCommand,
    required this.executionUnavailableMessage,
  });

  final AiProvider provider;
  final String apiKey;
  final bool Function() canRunCommands;
  final Future<void> Function(String command) onRunCommand;
  final String executionUnavailableMessage;

  @override
  State<AiCopilotSheet> createState() => _AiCopilotSheetState();
}

class _AiCopilotSheetState extends State<AiCopilotSheet> {
  late AiCommandService _aiCommandService;
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();
  final TextEditingController _promptController = TextEditingController();

  bool _isGenerating = false;
  int? _runningCommandIndex;
  List<TextEditingController> _commandControllers = [];
  String _status = 'Describe the issue, then generate suggested commands.';

  @override
  void initState() {
    super.initState();
    _aiCommandService = AiCommandService.forProvider(
      provider: widget.provider,
      apiKey: widget.apiKey,
    );
  }

  @override
  void didUpdateWidget(covariant AiCopilotSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider ||
        oldWidget.apiKey != widget.apiKey) {
      _aiCommandService = AiCommandService.forProvider(
        provider: widget.provider,
        apiKey: widget.apiKey,
      );
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
        _status =
            'Set your ${widget.provider.label} API key in Settings before generating commands.';
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
        _status = 'Failed to generate commands: $error';
      });
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
    if (command.isEmpty) {
      setState(() {
        _status = 'Command cannot be empty';
      });
      return;
    }

    if (!widget.canRunCommands()) {
      setState(() {
        _status = widget.executionUnavailableMessage;
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
      _status = 'Sending command to terminal';
    });

    try {
      await widget.onRunCommand(command);
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Command sent to shell. Check terminal output.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Could not send command to shell: $error';
      });
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
                  const Text('This command will be sent to the active shell:'),
                  const SizedBox(height: 12),
                  SelectableText(command),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'AI Copilot',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      widget.provider.label,
                      style: TextStyle(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
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
                    Text(
                      'Suggested Commands',
                      style: theme.textTheme.titleMedium,
                    ),
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
                            border: Border.all(
                              color: const Color(0xFFCBD5E1),
                            ),
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
                                  crossAxisAlignment:
                                      WrapCrossAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _riskColor(assessment.level)
                                            .withValues(alpha: 0.12),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        _riskLabel(assessment.level),
                                        style: TextStyle(
                                          color:
                                              _riskColor(assessment.level),
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
                                    onPressed: _isGenerating || isRunning
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
