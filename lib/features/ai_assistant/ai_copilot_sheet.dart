import 'package:flutter/material.dart';

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/command_risk_assessor.dart';

class AiCopilotSheet extends StatefulWidget {
  const AiCopilotSheet({
    super.key,
    required this.provider,
    required this.apiKey,
    required this.executionTarget,
    required this.canRunCommands,
    required this.getContext,
    required this.onRunCommand,
    required this.executionUnavailableMessage,
  });

  final AiProvider provider;
  final String apiKey;
  final AiCopilotExecutionTarget executionTarget;
  final bool Function() canRunCommands;
  final String Function() getContext;
  final Future<String?> Function(String command) onRunCommand;
  final String executionUnavailableMessage;

  @override
  State<AiCopilotSheet> createState() => _AiCopilotSheetState();
}

class _AiCopilotSheetState extends State<AiCopilotSheet> {
  static const _maxPromptContextChars = 2200;
  static const _maxPromptContextLines = 24;

  late AiCommandService _aiCommandService;
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();
  final TextEditingController _promptController = TextEditingController();

  CopilotMode _mode = CopilotMode.commandHelper;
  bool _isGenerating = false;
  int? _runningCommandIndex;
  List<_CopilotPlanStep> _planSteps = [];
  String _chatResponse = '';
  String _commandOutput = '';
  String _status = 'Describe the issue, then generate suggested commands.';

  bool get _isRunningStep => _runningCommandIndex != null;

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
    _disposePlanSteps();
    _promptController.dispose();
    super.dispose();
  }

  void _disposePlanSteps() {
    for (final step in _planSteps) {
      step.controller.dispose();
    }
    _planSteps = [];
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
      _status = 'Generating step plan';
      if (widget.executionTarget == AiCopilotExecutionTarget.dashboard) {
        _commandOutput = '';
      }
    });

    try {
      final plan = await _aiCommandService.generateCommandPlan(
        _buildCommandPrompt(prompt),
      );
      if (!mounted) {
        return;
      }

      _disposePlanSteps();

      setState(() {
        _planSteps = plan
            .map(
              (step) => _CopilotPlanStep(
                title: step.title,
                description: step.description,
                controller: TextEditingController(text: step.command),
                state: CopilotPlanStepState.pending,
              ),
            )
            .toList();
        _status = 'Step plan ready';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = _friendlyErrorMessage(
          error: error,
          fallbackPrefix: 'Failed to generate step plan',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _generateChatResponse() async {
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
            'Set your ${widget.provider.label} API key in Settings before using chat.';
      });
      return;
    }

    setState(() {
      _isGenerating = true;
      _status = 'Generating response';
    });

    try {
      final response = await _aiCommandService.generateChatResponse(
        _buildChatPrompt(prompt),
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _chatResponse = response;
        _status = 'Response ready';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = _friendlyErrorMessage(
          error: error,
          fallbackPrefix: 'Failed to generate response',
        );
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
    final step = _planSteps[index];
    final command = step.controller.text.trim();
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

    final pendingPreviousSteps = _pendingPreviousStepNumbers(index);
    final assessment = _riskAssessor.assess(command);
    final shouldRun = await _showConfirmationDialog(
      stepNumber: index + 1,
      stepTitle: step.title,
      command: command,
      assessment: assessment,
      warningText: pendingPreviousSteps.isEmpty
          ? null
          : 'Earlier steps are not completed: ${pendingPreviousSteps.join(', ')}. Running this step now may be misleading.',
    );
    if (!shouldRun) {
      return;
    }

    setState(() {
      _runningCommandIndex = index;
      _status = widget.executionTarget == AiCopilotExecutionTarget.terminal
          ? 'Sending Step ${index + 1} to shell'
          : 'Running Step ${index + 1}';
    });

    try {
      final output = await widget.onRunCommand(command);
      if (!mounted) {
        return;
      }

      setState(() {
        if (widget.executionTarget == AiCopilotExecutionTarget.terminal) {
          step.state = CopilotPlanStepState.sentToShell;
          _status = 'Step ${index + 1} sent to shell. Check terminal output.';
        } else {
          step.state = CopilotPlanStepState.executed;
          _status = 'Step ${index + 1} executed. Output below.';
          _appendExecutionOutput(
            stepNumber: index + 1,
            stepTitle: step.title,
            command: command,
            output: (output == null || output.isEmpty) ? '(no output)' : output,
            succeeded: true,
          );
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        step.state = CopilotPlanStepState.failed;
        _status = widget.executionTarget == AiCopilotExecutionTarget.terminal
            ? 'Step ${index + 1} could not be sent to shell.'
            : 'Step ${index + 1} failed. Output below.';
        if (widget.executionTarget == AiCopilotExecutionTarget.dashboard) {
          _appendExecutionOutput(
            stepNumber: index + 1,
            stepTitle: step.title,
            command: command,
            output: error.toString(),
            succeeded: false,
          );
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningCommandIndex = null;
        });
      }
    }
  }

  Future<bool> _showConfirmationDialog({
    required int stepNumber,
    required String stepTitle,
    required String command,
    required CommandRiskAssessment assessment,
    String? warningText,
  }) async {
    final color = _riskColor(assessment.level);
    final targetLabel =
        widget.executionTarget == AiCopilotExecutionTarget.terminal
            ? 'sent to the active shell'
            : 'run on the server';

    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Confirm Command'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Step $stepNumber: $stepTitle'),
                  const SizedBox(height: 12),
                  Text('This command will be $targetLabel:'),
                  const SizedBox(height: 12),
                  SelectableText(command),
                  if (warningText != null && warningText.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Step order warning',
                      style: TextStyle(
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      warningText,
                      style: const TextStyle(
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
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

  String _stepStateLabel(CopilotPlanStepState state) {
    switch (state) {
      case CopilotPlanStepState.pending:
        return 'Pending';
      case CopilotPlanStepState.sentToShell:
        return 'Sent to shell';
      case CopilotPlanStepState.executed:
        return 'Executed';
      case CopilotPlanStepState.failed:
        return 'Failed';
    }
  }

  Color _stepStateColor(CopilotPlanStepState state) {
    switch (state) {
      case CopilotPlanStepState.pending:
        return const Color(0xFF64748B);
      case CopilotPlanStepState.sentToShell:
        return const Color(0xFF0F766E);
      case CopilotPlanStepState.executed:
        return const Color(0xFF15803D);
      case CopilotPlanStepState.failed:
        return const Color(0xFFDC2626);
    }
  }

  List<int> _pendingPreviousStepNumbers(int index) {
    final pending = <int>[];
    for (var i = 0; i < index; i++) {
      final state = _planSteps[i].state;
      if (state != CopilotPlanStepState.sentToShell &&
          state != CopilotPlanStepState.executed) {
        pending.add(i + 1);
      }
    }
    return pending;
  }

  void _appendExecutionOutput({
    required int stepNumber,
    required String stepTitle,
    required String command,
    required String output,
    required bool succeeded,
  }) {
    final entry = StringBuffer()
      ..writeln('Step $stepNumber: $stepTitle')
      ..writeln('Command: $command')
      ..writeln('Result: ${succeeded ? 'Executed' : 'Failed'}')
      ..writeln('Output:')
      ..write(output);

    _commandOutput = _commandOutput.isEmpty
        ? entry.toString()
        : '$_commandOutput\n\n------------------------------\n\n${entry.toString()}';
  }

  String _friendlyErrorMessage({
    required Object error,
    required String fallbackPrefix,
  }) {
    final message = error.toString().trim();
    final normalized = message.toLowerCase();

    if (normalized.contains('api key is not set')) {
      return 'Set your ${widget.provider.label} API key in Settings first.';
    }

    if (normalized.contains('timed out')) {
      return '${widget.provider.label} took too long to respond. Try again.';
    }

    if (normalized.contains('network error') ||
        normalized.contains('socketexception')) {
      return 'Network error while contacting ${widget.provider.label}. Check your connection and try again.';
    }

    if (normalized.contains('rejected the api key') ||
        normalized.contains('invalid api key') ||
        normalized.contains('incorrect api key') ||
        normalized.contains('authentication') ||
        normalized.contains('unauthorized')) {
      return '${widget.provider.label} API key was rejected. Check the key in Settings and try again.';
    }

    if (widget.provider == AiProvider.gemini &&
        (normalized.contains('free-tier') ||
            normalized.contains('quota') ||
            normalized.contains('overload') ||
            normalized.contains('overloaded') ||
            normalized.contains('resource exhausted') ||
            normalized.contains('try again later'))) {
      return 'Gemini is temporarily unavailable or out of quota. Try again later or switch providers in Settings.';
    }

    if (normalized.contains('valid json') ||
        normalized.contains('json array') ||
        normalized.contains('parsed') ||
        normalized.contains('empty response') ||
        normalized.contains('unsupported plan step entry') ||
        normalized.contains('plan step without a command') ||
        normalized.contains('no commands')) {
      return '${widget.provider.label} returned an unreadable plan. Try again with a more specific request.';
    }

    return '$fallbackPrefix. Please try again.';
  }

  String _buildCommandPrompt(String userPrompt) {
    final contextSection = _buildContextSection();
    final sessionType =
        widget.executionTarget == AiCopilotExecutionTarget.terminal
            ? 'a live Linux terminal session'
            : 'a Linux server dashboard session';

    return 'You are helping with $sessionType.\n\n'
        '$contextSection'
        'User request:\n'
        '$userPrompt\n\n'
        'Return ONLY a JSON array of steps. '
        'Each step must be either:\n'
        '1. a string command, or\n'
        '2. an object with "title", "command", and optional "description".\n'
        'Use one shell command per step. No markdown. No code fences. No explanation outside JSON.';
  }

  String _buildChatPrompt(String userPrompt) {
    final contextSection = _buildContextSection();
    return 'Explain the situation, logs, or errors based on the available session context.\n\n'
        '$contextSection'
        'User request:\n'
        '$userPrompt\n\n'
        'Reply in plain language only. Do not return JSON, shell commands, step plans, or command lists.';
  }

  String _buildContextSection() {
    final rawContext = widget.getContext().trim();
    if (rawContext.isEmpty ||
        rawContext.toLowerCase().startsWith('no recent terminal context available')) {
      return '';
    }

    final normalized = rawContext
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final lines = normalized
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final trimmedLines = lines.length > _maxPromptContextLines
        ? lines.sublist(lines.length - _maxPromptContextLines)
        : lines;
    var trimmedContext = trimmedLines.join('\n').trim();

    if (trimmedContext.length > _maxPromptContextChars) {
      trimmedContext = trimmedContext.substring(
        trimmedContext.length - _maxPromptContextChars,
      );
    }

    if (trimmedContext.isEmpty) {
      return '';
    }

    return 'Context:\n'
        '--- BEGIN CONTEXT ---\n'
        '$trimmedContext\n'
        '--- END CONTEXT ---\n\n';
  }

  void _switchMode(CopilotMode mode) {
    _promptController.clear();

    setState(() {
      _mode = mode;
      _status = mode == CopilotMode.commandHelper
          ? 'Describe the issue, then generate suggested commands.'
          : 'Ask for explanations, log analysis, or Linux help.';
      _runningCommandIndex = null;

      if (mode == CopilotMode.generalChat) {
        _disposePlanSteps();
        _commandOutput = '';
      } else {
        _chatResponse = '';
      }
    });
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
              SegmentedButton<CopilotMode>(
                segments: const [
                  ButtonSegment<CopilotMode>(
                    value: CopilotMode.commandHelper,
                    label: Text('Command Helper'),
                  ),
                  ButtonSegment<CopilotMode>(
                    value: CopilotMode.generalChat,
                    label: Text('General Chat'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged:
                    _isRunningStep ? null : (selection) => _switchMode(selection.first),
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
                onPressed: _isGenerating || _isRunningStep
                    ? null
                    : (_mode == CopilotMode.commandHelper
                        ? _generateCommands
                        : _generateChatResponse),
                child: _isGenerating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _mode == CopilotMode.commandHelper
                            ? 'Generate Fix'
                            : 'Ask AI',
                      ),
              ),
              const SizedBox(height: 12),
              Text(_status, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 16),
              Expanded(
                child: _mode == CopilotMode.commandHelper
                    ? ListView(
                        children: [
                          Text(
                            'Suggested Steps',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          if (_planSteps.isEmpty)
                            const Text('No suggestions yet.'),
                          ...List.generate(_planSteps.length, (index) {
                            final step = _planSteps[index];
                            final command = step.controller.text;
                            final isRunning = _runningCommandIndex == index;
                            final assessment = _riskAssessor.assess(command);
                            final pendingPrevious =
                                _pendingPreviousStepNumbers(index);

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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'Step ${index + 1}',
                                        style: theme.textTheme.labelLarge,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        step.title,
                                        style: theme.textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _stepStateLabel(step.state),
                                        style: TextStyle(
                                          color: _stepStateColor(step.state),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (pendingPrevious.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        const Text(
                                          'Earlier steps are not completed yet.',
                                          style: TextStyle(
                                            color: Color(0xFFD97706),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                      if (step.description != null &&
                                          step.description!.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          step.description!,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      TextField(
                                        controller: step.controller,
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
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: _riskColor(
                                                assessment.level,
                                              ).withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              _riskLabel(assessment.level),
                                              style: TextStyle(
                                                color: _riskColor(
                                                  assessment.level,
                                                ),
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
                                          onPressed: _isGenerating || _isRunningStep
                                              ? null
                                              : () => _runCommand(index),
                                          child: isRunning
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
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
                          if (widget.executionTarget ==
                                  AiCopilotExecutionTarget.dashboard &&
                              _commandOutput.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Execution Output',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText(
                                  _commandOutput,
                                  style: const TextStyle(
                                    color: Color(0xFFE2E8F0),
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      )
                    : ListView(
                        children: [
                          Text(
                            'General Chat',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Response from ${widget.provider.label}',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFFCBD5E1),
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                _chatResponse.isEmpty
                                    ? 'No response yet.'
                                    : _chatResponse,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ),
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

enum CopilotMode {
  commandHelper,
  generalChat,
}

enum AiCopilotExecutionTarget {
  terminal,
  dashboard,
}

enum CopilotPlanStepState {
  pending,
  sentToShell,
  executed,
  failed,
}

class _CopilotPlanStep {
  _CopilotPlanStep({
    required this.title,
    required this.controller,
    required this.state,
    this.description,
  });

  final String title;
  final String? description;
  final TextEditingController controller;
  CopilotPlanStepState state;
}
