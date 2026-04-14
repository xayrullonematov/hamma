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
  static const _sheetBackground = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _primaryColor = Color(0xFF3B82F6);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _warningColor = Color(0xFFD97706);
  static const _shadowColor = Color(0x22000000);

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

  void _submitPrompt() {
    if (_isGenerating || _isRunningStep) {
      return;
    }

    if (_mode == CopilotMode.commandHelper) {
      _generateCommands();
    } else {
      _generateChatResponse();
    }
  }

  String _promptHintText() {
    if (_mode == CopilotMode.commandHelper) {
      return 'Describe the task, issue, or command plan you need';
    }
    return 'Ask about logs, Linux concepts, or debugging strategy';
  }

  BoxDecoration _surfaceDecoration() {
    return BoxDecoration(
      color: _surfaceColor,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: _shadowColor,
          blurRadius: 20,
          offset: Offset(0, 10),
        ),
      ],
    );
  }

  Widget _buildStatusBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 9,
            height: 9,
            margin: const EdgeInsets.only(top: 6),
            decoration: const BoxDecoration(
              color: _primaryColor,
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

  Widget _buildCommandHelperView(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        _buildStatusBanner(theme),
        const SizedBox(height: 16),
        if (_isGenerating && _planSteps.isEmpty)
          const _LoadingBubble(
            label: 'Building a step-by-step plan...',
          )
        else if (_planSteps.isEmpty)
          _EmptyMessageCard(
            title: 'No plan yet',
            message:
                'Describe the server task and the copilot will turn it into a safe step sequence.',
          ),
        ...List.generate(_planSteps.length, (index) {
          final step = _planSteps[index];
          final assessment = _riskAssessor.assess(step.controller.text);
          final pendingPrevious = _pendingPreviousStepNumbers(index);
          final isRunning = _runningCommandIndex == index;
          final isLast = index == _planSteps.length - 1;

          return Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 44,
                    child: Column(
                      children: [
                        _StepNode(number: index + 1),
                        if (!isLast)
                          Expanded(
                            child: Center(
                              child: Container(
                                width: 2,
                                margin: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: _panelColor,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StepTimelineCard(
                      title: step.title,
                      description: step.description,
                      controller: step.controller,
                      stateLabel: _stepStateLabel(step.state),
                      stateColor: _stepStateColor(step.state),
                      riskLabel: _riskLabel(assessment.level),
                      riskColor: _riskColor(assessment.level),
                      riskExplanation: assessment.explanation,
                      warningText: pendingPrevious.isEmpty
                          ? null
                          : 'Earlier steps are not completed yet.',
                      isRunning: isRunning,
                      isBusy: _isGenerating || _isRunningStep,
                      onChanged: () => setState(() {}),
                      onRun: () => _runCommand(index),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        if (widget.executionTarget == AiCopilotExecutionTarget.dashboard &&
            _commandOutput.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ExecutionOutputCard(output: _commandOutput),
        ],
      ],
    );
  }

  Widget _buildGeneralChatView(ThemeData theme) {
    final hasResponse = _chatResponse.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        _buildStatusBanner(theme),
        const SizedBox(height: 16),
        Text(
          'Response from ${widget.provider.label}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: _mutedColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _ChatBubble(
              child: _isGenerating
                  ? const _LoadingBubble(label: 'Thinking...')
                  : SelectableText(
                      hasResponse
                          ? _chatResponse
                          : 'Ask about logs, Linux concepts, or debugging strategy.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: hasResponse ? Colors.white : _mutedColor,
                        height: 1.5,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildComposer(ThemeData theme) {
    return Container(
      decoration: _surfaceDecoration(),
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _promptController,
              minLines: 1,
              maxLines: 4,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
              ),
              decoration: InputDecoration(
                hintText: _promptHintText(),
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: _mutedColor,
                ),
                filled: true,
                fillColor: _panelColor,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: const BorderSide(
                    color: _primaryColor,
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            decoration: BoxDecoration(
              color: _isGenerating || _isRunningStep
                  ? _panelColor
                  : _primaryColor,
              borderRadius: BorderRadius.circular(18),
            ),
            child: IconButton(
              onPressed: _isGenerating || _isRunningStep ? null : _submitPrompt,
              icon: _isGenerating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              color: Colors.white,
              tooltip: _mode == CopilotMode.commandHelper
                  ? 'Generate plan'
                  : 'Send prompt',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: _sheetBackground,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _mutedColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI Copilot',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _mode == CopilotMode.commandHelper
                            ? 'Command planning and safe execution'
                            : 'Explain logs, errors, and Linux concepts',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _mutedColor,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _surfaceColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      widget.provider.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _surfaceColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SegmentedButton<CopilotMode>(
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
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return _primaryColor;
                      }
                      return _surfaceColor;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return Colors.white;
                      }
                      return _mutedColor;
                    }),
                    side: const WidgetStatePropertyAll(BorderSide.none),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    ),
                  ),
                  onSelectionChanged:
                      _isRunningStep ? null : (selection) => _switchMode(selection.first),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _mode == CopilotMode.commandHelper
                    ? _buildCommandHelperView(theme)
                    : _buildGeneralChatView(theme),
              ),
              const SizedBox(height: 12),
              _buildComposer(theme),
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

class _StepNode extends StatelessWidget {
  const _StepNode({
    required this.number,
  });

  final int number;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xFF3B82F6).withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: const TextStyle(
          color: Color(0xFF3B82F6),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StepTimelineCard extends StatelessWidget {
  const _StepTimelineCard({
    required this.title,
    required this.description,
    required this.controller,
    required this.stateLabel,
    required this.stateColor,
    required this.riskLabel,
    required this.riskColor,
    required this.riskExplanation,
    required this.warningText,
    required this.isRunning,
    required this.isBusy,
    required this.onChanged,
    required this.onRun,
  });

  final String title;
  final String? description;
  final TextEditingController controller;
  final String stateLabel;
  final Color stateColor;
  final String riskLabel;
  final Color riskColor;
  final String riskExplanation;
  final String? warningText;
  final bool isRunning;
  final bool isBusy;
  final VoidCallback onChanged;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: _AiCopilotSheetState._shadowColor,
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                    color: stateColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (warningText != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFD97706).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                warningText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _AiCopilotSheetState._warningColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (description != null && description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _AiCopilotSheetState._mutedColor,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            maxLines: null,
            onChanged: (_) => onChanged(),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: _AiCopilotSheetState._panelColor,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(
                  color: _AiCopilotSheetState._primaryColor,
                  width: 1.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _RiskBadge(
                label: riskLabel,
                color: riskColor,
              ),
              Text(
                riskExplanation,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _AiCopilotSheetState._mutedColor,
                  height: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: isBusy ? null : onRun,
              style: FilledButton.styleFrom(
                backgroundColor: _AiCopilotSheetState._primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Run'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 7,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
          bottomRight: Radius.circular(24),
          bottomLeft: Radius.circular(8),
        ),
        boxShadow: const [
          BoxShadow(
            color: _AiCopilotSheetState._shadowColor,
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _LoadingBubble extends StatelessWidget {
  const _LoadingBubble({
    required this.label,
  });

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _AiCopilotSheetState._primaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _AiCopilotSheetState._mutedColor,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyMessageCard extends StatelessWidget {
  const _EmptyMessageCard({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _AiCopilotSheetState._mutedColor,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExecutionOutputCard extends StatelessWidget {
  const _ExecutionOutputCard({
    required this.output,
  });

  final String output;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Execution Output',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1120),
              borderRadius: BorderRadius.circular(18),
            ),
            child: SelectableText(
              output,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontFamily: 'monospace',
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
