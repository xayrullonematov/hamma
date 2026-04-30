import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/command_risk_assessor.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/storage/chat_history_storage.dart';
import 'widgets/interactive_command_block.dart';
import '../../core/theme/app_colors.dart';

class AiCopilotSheet extends StatefulWidget {
  const AiCopilotSheet({
    super.key,
    required this.serverId,
    required this.provider,
    required this.apiKeyStorage,
    required this.openRouterModel,
    this.initialPrompt,
    required this.executionTarget,
    required this.canRunCommands,
    required this.getContext,
    required this.onRunCommand,
    required this.executionUnavailableMessage,
  });

  final String serverId;
  final AiProvider provider;
  final ApiKeyStorage apiKeyStorage;
  final String? openRouterModel;
  final String? initialPrompt;
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
  static const _sheetBackground = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _primaryColor = AppColors.textPrimary;
  static const _mutedColor = AppColors.textMuted;
  static const _warningColor = AppColors.danger;
  static const _shadowColor = Color(0x22000000);
  static const _openRouterModelsUrl = 'https://openrouter.ai/api/v1/models';

  static const _quickActionPrompts = [
    "Analyze Logs",
    "Check Resource Hogs",
    "List Open Ports",
    "Update System",
    "Restart Service",
    "Prune Docker",
    "Firewall Audit",
  ];

  late AiCommandService _aiCommandService;
  final ChatHistoryStorage _chatHistoryStorage = const ChatHistoryStorage();
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();
  final TextEditingController _promptController = TextEditingController();

  late AiProvider _activeProvider;
  late String? _activeOpenRouterModel;
  String _activeApiKey = '';
  CopilotMode _mode = CopilotMode.commandHelper;
  bool _isGenerating = false;
  bool _isHistoryLoading = true;
  bool _isLoadingActiveApiKey = true;
  bool _isLoadingOpenRouterModels = false;
  bool _hasLoadedOpenRouterModels = false;
  int? _runningCommandIndex;
  List<_CopilotPlanStep> _planSteps = [];
  List<_ChatMessage> _chatMessages = const [];
  String? _openRouterModelsError;
  String _commandOutput = '';
  String _status = 'Describe the issue, then generate suggested commands.';
  List<String> _openRouterModels = const [];
  int _providerLoadGeneration = 0;
  bool _hasTriggeredInitialPrompt = false;

  bool get _isRunningStep => _runningCommandIndex != null;
  bool get _hasActiveApiKey => _activeApiKey.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _activeProvider = widget.provider;
    _activeOpenRouterModel = _normalizeOpenRouterModel(widget.openRouterModel);
    _seedInitialPrompt();
    _refreshAiCommandService();
    _loadChatHistory();
    _loadActiveProviderState();
  }

  @override
  void didUpdateWidget(covariant AiCopilotSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider ||
        oldWidget.apiKeyStorage != widget.apiKeyStorage) {
      _activeProvider = widget.provider;
      _loadActiveProviderState(widget.provider);
    }

    if (oldWidget.openRouterModel != widget.openRouterModel) {
      _activeOpenRouterModel = _normalizeOpenRouterModel(
        widget.openRouterModel,
      );
      _refreshAiCommandService();
    }

    if (oldWidget.serverId != widget.serverId) {
      _loadChatHistory();
    }

    if (oldWidget.initialPrompt != widget.initialPrompt) {
      _hasTriggeredInitialPrompt = false;
      _seedInitialPrompt();
      _scheduleInitialPromptIfReady();
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

  String _defaultStatusText() {
    return _mode == CopilotMode.commandHelper
        ? 'Describe the issue, then generate suggested commands.'
        : 'Ask for explanations, log analysis, or Linux help.';
  }

  String? _normalizeOpenRouterModel(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  String? _normalizeInitialPrompt(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  void _seedInitialPrompt() {
    final initialPrompt = _normalizeInitialPrompt(widget.initialPrompt);
    if (initialPrompt == null) {
      return;
    }

    _promptController.value = TextEditingValue(
      text: initialPrompt,
      selection: TextSelection.collapsed(offset: initialPrompt.length),
    );
    _mode = CopilotMode.commandHelper;
  }

  void _scheduleInitialPromptIfReady() {
    if (_hasTriggeredInitialPrompt ||
        _normalizeInitialPrompt(widget.initialPrompt) == null ||
        _isGenerating ||
        _isRunningStep ||
        _isHistoryLoading ||
        _isLoadingActiveApiKey ||
        !_hasActiveApiKey) {
      return;
    }

    _hasTriggeredInitialPrompt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _submitPrompt();
    });
  }

  void _refreshAiCommandService() {
    _aiCommandService = AiCommandService.forProvider(
      provider: _activeProvider,
      apiKey: _activeApiKey,
      openRouterModel: _activeOpenRouterModel,
    );
  }

  Future<void> _loadActiveProviderState([AiProvider? provider]) async {
    final targetProvider = provider ?? _activeProvider;
    final generation = ++_providerLoadGeneration;

    setState(() {
      _activeProvider = targetProvider;
      _isLoadingActiveApiKey = true;
      _status = 'Loading ${targetProvider.label} API key...';
    });

    if (targetProvider == AiProvider.openRouter) {
      unawaited(_loadOpenRouterModels());
    }

    try {
      final apiKey =
          await widget.apiKeyStorage.loadApiKey(targetProvider) ?? '';
      if (!mounted || generation != _providerLoadGeneration) {
        return;
      }

      _activeApiKey = apiKey.trim();
      _refreshAiCommandService();

      setState(() {
        _isLoadingActiveApiKey = false;
        _status =
            _hasActiveApiKey
                ? _defaultStatusText()
                : 'API key missing. Configure it in Settings.';
      });
      _scheduleInitialPromptIfReady();
    } catch (_) {
      if (!mounted || generation != _providerLoadGeneration) {
        return;
      }

      _activeApiKey = '';
      _refreshAiCommandService();

      setState(() {
        _isLoadingActiveApiKey = false;
        _status = 'API key missing. Configure it in Settings.';
      });
      _scheduleInitialPromptIfReady();
    }
  }

  Future<void> _handleProviderSelected(AiProvider provider) async {
    if (provider == _activeProvider) {
      return;
    }

    await _loadActiveProviderState(provider);
  }

  Future<void> _loadOpenRouterModels({bool forceRefresh = false}) async {
    if (_isLoadingOpenRouterModels) {
      return;
    }

    if (_hasLoadedOpenRouterModels && !forceRefresh) {
      return;
    }

    setState(() {
      _isLoadingOpenRouterModels = true;
      _openRouterModelsError = null;
    });

    try {
      final response = await http
          .get(Uri.parse(_openRouterModelsUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'OpenRouter model list request failed with status ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('OpenRouter model response was invalid.');
      }

      final data = decoded['data'];
      if (data is! List) {
        throw const FormatException('OpenRouter model response was invalid.');
      }

      final models =
          data
              .whereType<Map>()
              .map((item) => (item['id'] ?? '').toString().trim())
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      final selectedModel = _normalizeOpenRouterModel(_activeOpenRouterModel);
      if (selectedModel != null && !models.contains(selectedModel)) {
        models.insert(0, selectedModel);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _openRouterModels = models;
        _openRouterModelsError = null;
        _hasLoadedOpenRouterModels = true;
      });
    } on TimeoutException {
      if (!mounted) {
        return;
      }

      setState(() {
        _openRouterModelsError =
            'OpenRouter model list request timed out. Try again.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _openRouterModelsError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingOpenRouterModels = false;
        });
      }
    }
  }

  Future<void> _showOpenRouterModelPicker() async {
    if (_activeProvider != AiProvider.openRouter) {
      return;
    }

    if (!_hasLoadedOpenRouterModels) {
      await _loadOpenRouterModels();
    }

    if (!mounted) {
      return;
    }

    if (_openRouterModelsError != null) {
      final retry = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('OpenRouter Models'),
            content: Text(_openRouterModelsError!),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Retry'),
              ),
            ],
          );
        },
      );

      if (retry == true) {
        await _loadOpenRouterModels(forceRefresh: true);
        if (mounted) {
          await _showOpenRouterModelPicker();
        }
      }
      return;
    }

    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _surfaceColor,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.68,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'OpenRouter Models',
                          style: Theme.of(
                            context,
                          ).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    children: [
                      ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        title: const Text('Use Default Model'),
                        subtitle: const Text('meta-llama/llama-3-8b-instruct'),
                        trailing:
                            _activeOpenRouterModel == null
                                ? const Icon(
                                  Icons.check_rounded,
                                  color: _primaryColor,
                                )
                                : null,
                        onTap: () => Navigator.of(context).pop(''),
                      ),
                      const SizedBox(height: 8),
                      ..._openRouterModels.map((modelId) {
                        final isSelected = modelId == _activeOpenRouterModel;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.zero,
                            ),
                            tileColor: _panelColor,
                            title: Text(modelId),
                            trailing:
                                isSelected
                                    ? const Icon(
                                      Icons.check_rounded,
                                      color: _primaryColor,
                                    )
                                    : null,
                            onTap: () => Navigator.of(context).pop(modelId),
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
      },
    );

    if (!mounted || selected == null) {
      return;
    }

    _activeOpenRouterModel = _normalizeOpenRouterModel(selected);
    _refreshAiCommandService();

    setState(() {
      _status =
          _activeOpenRouterModel == null
              ? 'OpenRouter model reset to default.'
              : 'OpenRouter model updated.';
    });
  }

  Future<void> _loadChatHistory() async {
    setState(() {
      _isHistoryLoading = true;
    });

    try {
      final storedMessages = await _chatHistoryStorage.loadHistory(
        serverId: widget.serverId,
      );
      if (!mounted) {
        return;
      }

      final chatMessages =
          storedMessages
              .map(
                (message) => _ChatMessage(
                  role: message['role'] ?? '',
                  content: message['content'] ?? '',
                ),
              )
              .where(
                (message) =>
                    message.role.isNotEmpty && message.content.isNotEmpty,
              )
              .toList();

      setState(() {
        _chatMessages = chatMessages;
      });
      _scheduleInitialPromptIfReady();
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _chatMessages = const [];
      });
      _scheduleInitialPromptIfReady();
    } finally {
      if (mounted) {
        setState(() {
          _isHistoryLoading = false;
        });
        _scheduleInitialPromptIfReady();
      }
    }
  }

  void _appendChatMessage({required String role, required String content, CommandAnalysis? analysis}) {
    final normalizedContent = content.trim();
    if (normalizedContent.isEmpty && analysis == null) {
      return;
    }

    final updatedMessages = [
      ..._chatMessages,
      _ChatMessage(role: role, content: normalizedContent, analysis: analysis),
    ];

    setState(() {
      _chatMessages = updatedMessages;
    });

    _saveChatHistory(updatedMessages);
  }

  Future<void> _saveChatHistory(List<_ChatMessage> messages) async {
    try {
      await _chatHistoryStorage.saveHistory(
        serverId: widget.serverId,
        messages:
            messages
                .map(
                  (message) => {
                    'role': message.role,
                    'content': message.content,
                  },
                )
                .toList(),
      );
    } catch (_) {
      // Ignore persistence failures to avoid interrupting the chat flow.
    }
  }

  Future<void> _clearChatHistory() async {
    final shouldClear =
        await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Clear Chat'),
              content: const Text(
                'Delete the saved chat history for this server?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Clear'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldClear) {
      return;
    }

    setState(() {
      _chatMessages = const [];
    });

    try {
      await _chatHistoryStorage.clearHistory(serverId: widget.serverId);
    } catch (_) {
      // Ignore storage failures after clearing the local UI state.
    }
  }

  Future<void> _handleQuickAction(String actionPrompt) async {
    if (_isGenerating || _isRunningStep || !_hasActiveApiKey) return;
    
    _appendChatMessage(role: 'user', content: actionPrompt);
    
    setState(() {
      _isGenerating = true;
      _status = 'Generating analyzed command...';
    });

    try {
      final analysis = await _aiCommandService.generateCommand(
        actionPrompt,
        contextOutput: widget.getContext(),
      );
      
      if (!mounted) return;

      _appendChatMessage(
        role: 'assistant',
        content: analysis.explanation,
        analysis: analysis,
      );
      
      setState(() {
        _status = 'Suggestion ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _friendlyErrorMessage(
          error: error,
          fallbackPrefix: 'Failed to generate command',
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

  Future<void> _generateAnalyzedCommand(String prompt) async {
    setState(() {
      _isGenerating = true;
      _status = 'Analyzing...';
    });

    _appendChatMessage(role: 'user', content: prompt);

    try {
      final analysis = await _aiCommandService.generateCommand(
        prompt,
        contextOutput: widget.getContext(),
      );
      
      if (!mounted) return;

      _appendChatMessage(
        role: 'assistant',
        content: analysis.explanation,
        analysis: analysis,
      );
      
      setState(() {
        _status = 'Suggestion ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _friendlyErrorMessage(
          error: error,
          fallbackPrefix: 'Failed to generate analyzed command',
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

  Future<void> _generateCommands() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _status = 'Enter a prompt first';
      });
      return;
    }

    if (!_hasActiveApiKey) {
      setState(() {
        _status = 'API key missing. Configure it in Settings.';
      });
      return;
    }

    await _generateAnalyzedCommand(prompt);
    _promptController.clear();
  }

  Future<void> _generateChatResponse() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _status = 'Enter a prompt first';
      });
      return;
    }

    if (!_hasActiveApiKey) {
      setState(() {
        _status = 'API key missing. Configure it in Settings.';
      });
      return;
    }

    final existingChatMessages = List<_ChatMessage>.from(_chatMessages);
    _appendChatMessage(role: 'user', content: prompt);
    _promptController.clear();

    setState(() {
      _isGenerating = true;
      _status = 'Generating response';
    });

    try {
      final response = await _aiCommandService.generateChatResponse(
        _buildChatPrompt(prompt, historyMessages: existingChatMessages),
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Response ready';
      });
      _appendChatMessage(role: 'assistant', content: response);
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

  Future<void> _executeCommandWithRiskCheck(String command, CommandRiskLevel riskLevel, String explanation) async {
    if (riskLevel == CommandRiskLevel.low) {
      await widget.onRunCommand(command);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Execution'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: _riskColor(riskLevel), size: 20),
                const SizedBox(width: 8),
                Text(
                  riskLevel.name.toUpperCase(),
                  style: TextStyle(
                    color: _riskColor(riskLevel),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(explanation),
            const SizedBox(height: 16),
            const Text('Are you sure you want to run this command on the server?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Run Anyway'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.onRunCommand(command);
    }
  }

  Future<void> _explainCommand(String command) async {
    _appendChatMessage(role: 'user', content: 'Explain: $command');
    
    setState(() {
      _isGenerating = true;
      _status = 'Generating explanation...';
    });

    try {
      final response = await _aiCommandService.generateChatResponse(
        'Please provide a deep technical explanation of the following Linux command:\n\n$command',
        history: _chatMessages.map((m) => {'role': m.role, 'content': m.content}).toList(),
      );
      
      if (!mounted) return;

      _appendChatMessage(role: 'assistant', content: response);
      
      setState(() {
        _status = 'Explanation ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _friendlyErrorMessage(
          error: error,
          fallbackPrefix: 'Failed to generate explanation',
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
      warningText:
          pendingPreviousSteps.isEmpty
              ? null
              : 'Earlier steps are not completed: ${pendingPreviousSteps.join(', ')}. Running this step now may be misleading.',
    );
    if (!shouldRun) {
      return;
    }

    setState(() {
      _runningCommandIndex = index;
      _status =
          widget.executionTarget == AiCopilotExecutionTarget.terminal
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
        _status =
            widget.executionTarget == AiCopilotExecutionTarget.terminal
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
    required CommandAnalysis assessment,
    String? warningText,
  }) async {
    final color = _riskColor(assessment.riskLevel);
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
                        color: AppColors.danger,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      warningText,
                      style: const TextStyle(
                        color: AppColors.danger,
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
                      borderRadius: BorderRadius.zero,
                    ),
                    child: Text(
                      _riskLabel(assessment.riskLevel),
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
      case CommandRiskLevel.low:
        return 'LOW RISK';
      case CommandRiskLevel.moderate:
        return 'MODERATE RISK';
      case CommandRiskLevel.high:
        return 'HIGH RISK';
      case CommandRiskLevel.critical:
        return 'CRITICAL RISK';
    }
  }

  Color _riskColor(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.low:
        return AppColors.textPrimary;
      case CommandRiskLevel.moderate:
        return AppColors.textMuted;
      case CommandRiskLevel.high:
      case CommandRiskLevel.critical:
        return AppColors.danger;
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
        return AppColors.textMuted;
      case CopilotPlanStepState.sentToShell:
        return AppColors.textMuted;
      case CopilotPlanStepState.executed:
        return AppColors.textPrimary;
      case CopilotPlanStepState.failed:
        return AppColors.danger;
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
    final entry =
        StringBuffer()
          ..writeln('Step $stepNumber: $stepTitle')
          ..writeln('Command: $command')
          ..writeln('Result: ${succeeded ? 'Executed' : 'Failed'}')
          ..writeln('Output:')
          ..write(output);

    _commandOutput =
        _commandOutput.isEmpty
            ? entry.toString()
            : '$_commandOutput\n\n------------------------------\n\n${entry.toString()}';
  }

  String _friendlyErrorMessage({
    required Object error,
    required String fallbackPrefix,
  }) {
    final message = error.toString().trim();
    final normalized = message.toLowerCase();

    if (error is AiCommandServiceException && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }

    if (normalized.contains('api key is not set')) {
      return 'Set your ${_activeProvider.label} API key in Settings first.';
    }

    if (normalized.contains('timed out')) {
      return '${_activeProvider.label} took too long to respond. Try again.';
    }

    if (normalized.contains('network error') ||
        normalized.contains('socketexception')) {
      return 'Network error while contacting ${_activeProvider.label}. Check your connection and try again.';
    }

    if (normalized.contains('rejected the api key') ||
        normalized.contains('invalid api key') ||
        normalized.contains('incorrect api key') ||
        normalized.contains('authentication') ||
        normalized.contains('unauthorized')) {
      return '${_activeProvider.label} API key was rejected. Check the key in Settings and try again.';
    }

    if (_activeProvider == AiProvider.gemini &&
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
      return '${_activeProvider.label} returned an unreadable plan. Try again with a more specific request.';
    }

    return '$fallbackPrefix. Please try again.';
  }

  String _buildChatPrompt(
    String userPrompt, {
    List<_ChatMessage>? historyMessages,
  }) {
    final contextSection = _buildContextSection();
    final historySection = _buildChatHistorySection(
      historyMessages ?? _chatMessages,
    );
    return 'Explain the situation, logs, or errors based on the available session context.\n\n'
        '$contextSection'
        '$historySection'
        'User request:\n'
        '$userPrompt\n\n'
        'Reply in plain language only. Do not return JSON, shell commands, step plans, or command lists.';
  }

  String _buildChatHistorySection(List<_ChatMessage> historyMessages) {
    if (historyMessages.isEmpty) {
      return '';
    }

    final recentMessages =
        historyMessages.length > 10
            ? historyMessages.sublist(historyMessages.length - 10)
            : historyMessages;

    var historyText = recentMessages
        .map(
          (message) =>
              '${message.role == 'user' ? 'User' : 'Assistant'}: ${message.content}',
        )
        .join('\n');

    if (historyText.length > 1400) {
      historyText = historyText.substring(historyText.length - 1400);
    }

    return 'Conversation so far:\n'
        '--- BEGIN CHAT HISTORY ---\n'
        '$historyText\n'
        '--- END CHAT HISTORY ---\n\n';
  }

  String _buildContextSection() {
    final rawContext = widget.getContext().trim();
    if (rawContext.isEmpty ||
        rawContext.toLowerCase().startsWith(
          'no recent terminal context available',
        )) {
      return '';
    }

    final normalized = rawContext
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final lines =
        normalized
            .split('\n')
            .map((line) => line.trimRight())
            .where((line) => line.trim().isNotEmpty)
            .toList();
    final trimmedLines =
        lines.length > _maxPromptContextLines
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
      _status =
          _hasActiveApiKey
              ? _defaultStatusText()
              : 'API key missing. Configure it in Settings.';
      _runningCommandIndex = null;

      if (mode == CopilotMode.generalChat) {
        _disposePlanSteps();
        _commandOutput = '';
      }
    });
  }

  void _submitPrompt() {
    if (_isGenerating ||
        _isRunningStep ||
        _isHistoryLoading ||
        _isLoadingActiveApiKey ||
        !_hasActiveApiKey) {
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
      borderRadius: BorderRadius.zero,
      boxShadow: const [
        BoxShadow(color: _shadowColor, blurRadius: 20, offset: Offset(0, 10)),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      decoration: _surfaceDecoration(),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
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
              ),
              IconButton(
                onPressed:
                    _isHistoryLoading || _isGenerating || _chatMessages.isEmpty
                        ? null
                        : _clearChatHistory,
                icon: const Icon(Icons.delete_sweep_outlined),
                color: _mutedColor,
                tooltip: 'Clear chat',
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                color: _mutedColor,
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: PopupMenuButton<AiProvider>(
                  enabled: !_isGenerating && !_isRunningStep,
                  color: _surfaceColor,
                  onSelected:
                      (provider) =>
                          unawaited(_handleProviderSelected(provider)),
                  itemBuilder: (context) {
                    return AiProvider.values.map((provider) {
                      return PopupMenuItem<AiProvider>(
                        value: provider,
                        child: Row(
                          children: [
                            Expanded(child: Text(provider.label)),
                            if (provider == _activeProvider)
                              const Icon(
                                Icons.check_rounded,
                                color: _primaryColor,
                              ),
                          ],
                        ),
                      );
                    }).toList();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: _panelColor,
                      borderRadius: BorderRadius.zero,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.swap_horiz_rounded, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _activeProvider.label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (_isLoadingActiveApiKey)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.expand_more_rounded),
                      ],
                    ),
                  ),
                ),
              ),
              if (_activeProvider == AiProvider.openRouter) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: TextButton(
                    onPressed:
                        _isGenerating || _isRunningStep
                            ? null
                            : _showOpenRouterModelPicker,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      backgroundColor: _panelColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isLoadingOpenRouterModels)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.tune_rounded, size: 16),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _activeOpenRouterModel ?? 'Default model',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyBanner(ThemeData theme) {
    if (_isLoadingActiveApiKey) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _surfaceColor,
          borderRadius: BorderRadius.zero,
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Loading ${_activeProvider.label} API key...',
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

    if (_hasActiveApiKey) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _warningColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.zero,
      ),
      child: Text(
        'API key missing. Configure it in Settings.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: _warningColor,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _buildStatusBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.zero,
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
        if (_isLoadingActiveApiKey || !_hasActiveApiKey) ...[
          const SizedBox(height: 12),
          _buildApiKeyBanner(theme),
        ],
        const SizedBox(height: 16),
        if (_isGenerating && _planSteps.isEmpty)
          const _LoadingBubble(label: 'Building a step-by-step plan...')
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
                                  borderRadius: BorderRadius.zero,
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
                      controller: step.controller,
                      stateLabel: _stepStateLabel(step.state),
                      stateColor: _stepStateColor(step.state),
                      riskLabel: _riskLabel(assessment.riskLevel),
                      riskColor: _riskColor(assessment.riskLevel),
                      riskExplanation: assessment.explanation,
                      warningText:
                          pendingPrevious.isEmpty
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        _buildStatusBanner(theme),
        if (_isLoadingActiveApiKey || !_hasActiveApiKey) ...[
          const SizedBox(height: 12),
          _buildApiKeyBanner(theme),
        ],
        const SizedBox(height: 16),
        Text(
          'Conversation with ${_activeProvider.label}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: _mutedColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        if (_isHistoryLoading)
          const _LoadingBubble(label: 'Loading previous chat...')
        else if (_chatMessages.isEmpty && !_isGenerating)
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _ChatBubble(
                child: SelectableText(
                  'Ask about logs, Linux concepts, or debugging strategy.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _mutedColor,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          )
        else
          ..._chatMessages.map((message) {
            final isUser = message.role == 'user';

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(
                alignment:
                    isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child:
                      isUser
                          ? _UserChatBubble(
                            child: SelectableText(
                              message.content,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                                height: 1.5,
                              ),
                            ),
                          )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _ChatBubble(
                                  child: SelectableText(
                                    message.content,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: Colors.white,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                                if (message.analysis != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: InteractiveCommandBlock(
                                      analysis: message.analysis!,
                                      onRunCommand: (cmd) => _executeCommandWithRiskCheck(
                                        cmd,
                                        message.analysis!.riskLevel,
                                        message.analysis!.explanation,
                                      ),
                                      onExplainCommand: _explainCommand,
                                    ),
                                  ),
                              ],
                            ),
                ),
              ),
            );
          }),
        if (_isGenerating)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _LoadingBubble(label: 'Thinking...'),
            ),
          ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _quickActionPrompts.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final prompt = _quickActionPrompts[index];
          return ActionChip(
            label: Text(prompt, style: const TextStyle(fontSize: 12)),
            onPressed: () => _handleQuickAction(prompt),
            backgroundColor: _panelColor,
            labelStyle: const TextStyle(color: Colors.white),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          );
        },
      ),
    );
  }

  Widget _buildComposer(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildQuickActions(),
        const SizedBox(height: 8),
        Container(
          decoration: _surfaceDecoration(),
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _promptController,
                  enabled: !_isLoadingActiveApiKey && _hasActiveApiKey,
                  minLines: 1,
                  maxLines: 4,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
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
                      borderRadius: BorderRadius.zero,
                      borderSide: const BorderSide(color: AppColors.border, width: 1),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                      borderSide: const BorderSide(color: AppColors.border, width: 1),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                      borderSide: const BorderSide(
                        color: _primaryColor,
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Builder(builder: (context) {
                final bool isDisabled = _isGenerating ||
                    _isRunningStep ||
                    _isLoadingActiveApiKey ||
                    !_hasActiveApiKey;
                // When the button is enabled, its background is white
                // (_primaryColor) so the icon must be black to remain visible.
                // When disabled, the background is _panelColor (dark) so the
                // icon stays white.
                final Color iconColor = isDisabled
                    ? AppColors.textPrimary
                    : AppColors.scaffoldBackground;
                return Container(
                  decoration: BoxDecoration(
                    color: isDisabled ? _panelColor : _primaryColor,
                    borderRadius: BorderRadius.zero,
                  ),
                  child: IconButton(
                    onPressed: isDisabled || _isHistoryLoading
                        ? null
                        : _submitPrompt,
                    icon: _isGenerating
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: iconColor,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                    color: iconColor,
                    tooltip: _mode == CopilotMode.commandHelper
                        ? 'Generate plan'
                        : 'Send prompt',
                  ),
                );
              }),
            ],
          ),
        ),
      ],
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
                    borderRadius: BorderRadius.zero,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildHeader(theme),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _surfaceColor,
                  borderRadius: BorderRadius.zero,
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
                        return AppColors.scaffoldBackground;
                      }
                      return _mutedColor;
                    }),
                    side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border, width: 1)),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    ),
                  ),
                  onSelectionChanged:
                      _isRunningStep
                          ? null
                          : (selection) => _switchMode(selection.first),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child:
                    _mode == CopilotMode.commandHelper
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

enum CopilotMode { commandHelper, generalChat }

enum AiCopilotExecutionTarget { terminal, dashboard }

enum CopilotPlanStepState { pending, sentToShell, executed, failed }

class _CopilotPlanStep {
  _CopilotPlanStep({
    required this.title,
    required this.controller,
    required this.state,
  });

  final String title;
  final TextEditingController controller;
  CopilotPlanStepState state;
}

class _ChatMessage {
  const _ChatMessage({required this.role, required this.content, this.analysis});

  final String role;
  final String content;
  final CommandAnalysis? analysis;
}

class _StepNode extends StatelessWidget {
  const _StepNode({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.textPrimary.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StepTimelineCard extends StatelessWidget {
  const _StepTimelineCard({
    required this.title,
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
        borderRadius: BorderRadius.zero,
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
                  borderRadius: BorderRadius.zero,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.zero,
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
                borderRadius: BorderRadius.zero,
                borderSide: const BorderSide(color: AppColors.border, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: const BorderSide(color: AppColors.border, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
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
              _RiskBadge(label: riskLabel, color: riskColor),
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
                backgroundColor: AppColors.textPrimary,
                foregroundColor: AppColors.scaffoldBackground,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              icon:
                  isRunning
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.scaffoldBackground,
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
  const _RiskBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.zero,
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
  const _ChatBubble({required this.child});

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

class _UserChatBubble extends StatelessWidget {
  const _UserChatBubble({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._panelColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
          bottomRight: Radius.circular(8),
          bottomLeft: Radius.circular(24),
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
  const _LoadingBubble({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.zero,
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
  const _EmptyMessageCard({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.zero,
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
  const _ExecutionOutputCard({required this.output});

  final String output;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _AiCopilotSheetState._surfaceColor,
        borderRadius: BorderRadius.zero,
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
              color: AppColors.scaffoldBackground,
              borderRadius: BorderRadius.zero,
            ),
            child: SelectableText(
              output,
              style: const TextStyle(
                color: AppColors.textPrimary,
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
