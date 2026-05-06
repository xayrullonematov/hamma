import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/command_risk_assessor.dart';
import '../../core/ai/local_engine_health_monitor.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/storage/chat_history_storage.dart';
import '../../core/voice/voice_backend_speech_to_text.dart';
import '../../core/voice/voice_mode_storage.dart';
import '../../core/voice/voice_recognizer.dart';
import '../../core/voice/voice_session.dart';
import '../../core/voice/voice_speaker.dart';
import 'copilot/widgets/copilot_chrome.dart';
import 'copilot/widgets/step_timeline_card.dart';
import 'widgets/interactive_command_block.dart';
import 'widgets/local_engine_status_pill.dart';
import 'widgets/voice_input_button.dart';
import 'widgets/voice_mode_toggle.dart';
import '../../core/theme/app_colors.dart';

class AiCopilotSheet extends StatefulWidget {
  const AiCopilotSheet({
    super.key,
    required this.serverId,
    required this.provider,
    required this.apiKeyStorage,
    required this.openRouterModel,
    this.localEndpoint,
    this.localModel,
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
  final String? localEndpoint;
  final String? localModel;
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

  // Voice — only constructed on iOS/Android. Desktop / web builds
  // never touch the speech_to_text or flutter_tts plugins.
  late final VoiceSession _voiceSession = VoiceSession();
  final VoiceModeStorage _voiceModeStorage = const VoiceModeStorage();
  VoiceRecognizer? _voiceRecognizer;
  VoiceSpeaker? _voiceSpeaker;
  bool _voiceMicActive = false;

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
  List<String> _openRouterModels = const [];
  int _providerLoadGeneration = 0;
  bool _hasTriggeredInitialPrompt = false;
  LocalEngineHealthMonitor? _localMonitor;
  String? _localMonitorEndpoint;

  bool get _isRunningStep => _runningCommandIndex != null;
  bool get _hasActiveApiKey =>
      _activeApiKey.trim().isNotEmpty || !_activeProvider.requiresApiKey;

  @override
  void initState() {
    super.initState();
    _activeProvider = widget.provider;
    _activeOpenRouterModel = _normalizeOpenRouterModel(widget.openRouterModel);
    _seedInitialPrompt();
    _refreshAiCommandService();
    _syncLocalEngineMonitor();
    _loadChatHistory();
    _loadActiveProviderState();
    _maybeInitVoice();
  }

  /// Builds the voice subsystem on iOS/Android only. Desktop / web
  /// skip — the mic button never renders so the speech_to_text
  /// plugin is never touched.
  void _maybeInitVoice() {
    if (kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    _voiceRecognizer = VoiceRecognizer(backend: SpeechToTextBackend());
    _voiceSpeaker = VoiceSpeaker();
    _voiceSession.addListener(_onVoiceSessionChanged);
    // Restore the user's last voice mode for this server so an
    // on-call engineer who enabled conversational mode keeps it on
    // across app restarts.
    unawaited(() async {
      final saved = await _voiceModeStorage.load(widget.serverId);
      if (mounted && saved != VoiceMode.off) {
        _voiceSession.setMode(saved);
      }
    }());
  }

  void _onVoiceSessionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onVoiceTranscript(String text) {
    _promptController.text = text;
    _submitPrompt();
  }

  void _onVoiceListeningChanged(bool listening) {
    if (_voiceMicActive == listening) return;
    setState(() => _voiceMicActive = listening);
    _voiceSession.setAudioActive(listening);
  }

  Future<void> _maybeSpeakReply(String reply) async {
    final speaker = _voiceSpeaker;
    if (speaker == null || !_voiceSession.isConversational) return;
    if (reply.trim().isEmpty) return;
    _voiceSession.setAudioActive(true);
    try {
      await speaker.speak(reply);
    } finally {
      if (mounted && !_voiceMicActive) {
        _voiceSession.setAudioActive(false);
      }
    }
  }

  @override
  void didUpdateWidget(covariant AiCopilotSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider ||
        oldWidget.apiKeyStorage != widget.apiKeyStorage) {
      _activeProvider = widget.provider;
      _loadActiveProviderState(widget.provider);
      _syncLocalEngineMonitor();
    }

    if (oldWidget.openRouterModel != widget.openRouterModel) {
      _activeOpenRouterModel = _normalizeOpenRouterModel(
        widget.openRouterModel,
      );
      _refreshAiCommandService();
    }

    if (oldWidget.localEndpoint != widget.localEndpoint) {
      _syncLocalEngineMonitor();
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
    unawaited(_localMonitor?.dispose());
    _localMonitor = null;
    _voiceSession.removeListener(_onVoiceSessionChanged);
    unawaited(_voiceSpeaker?.stop());
    unawaited(_voiceRecognizer?.cancel());
    _voiceRecognizer?.dispose();
    _voiceSession.dispose();
    super.dispose();
  }

  /// Spin up (or tear down) the local engine health monitor whenever
  /// the active provider or configured endpoint changes. Reuses the
  /// existing monitor if the endpoint is unchanged so we don't reset
  /// the polling clock on every rebuild.
  void _syncLocalEngineMonitor() {
    final endpoint = widget.localEndpoint?.trim();
    final shouldRun = _activeProvider == AiProvider.local &&
        endpoint != null &&
        endpoint.isNotEmpty;
    if (shouldRun && _localMonitorEndpoint == endpoint) return;
    unawaited(_localMonitor?.dispose());
    _localMonitor = null;
    _localMonitorEndpoint = null;
    if (!shouldRun) return;
    _localMonitor = LocalEngineHealthMonitor(endpoint: endpoint);
    _localMonitorEndpoint = endpoint;
  }

  void _disposePlanSteps() {
    for (final step in _planSteps) {
      step.controller.dispose();
    }
    _planSteps = [];
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
      localEndpoint: widget.localEndpoint,
      localModel: widget.localModel,
    );
  }

  Future<void> _loadActiveProviderState([AiProvider? provider]) async {
    final targetProvider = provider ?? _activeProvider;
    final generation = ++_providerLoadGeneration;

    setState(() {
      _activeProvider = targetProvider;
      _isLoadingActiveApiKey = true;
      // Spin the monitor up/down here so the header pill appears the
      // instant the user picks Local AI from the in-sheet provider
      // picker — `didUpdateWidget` only fires for prop changes, but
      // the picker mutates state internally.
      _syncLocalEngineMonitor();
    });

    if (targetProvider == AiProvider.openRouter) {
      unawaited(_loadOpenRouterModels());
    }

    if (!targetProvider.requiresApiKey) {
      if (!mounted || generation != _providerLoadGeneration) return;
      _activeApiKey = '';
      _refreshAiCommandService();
      setState(() {
        _isLoadingActiveApiKey = false;
      });
      _scheduleInitialPromptIfReady();
      return;
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
              .whereType<Map<dynamic, dynamic>>()
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
        return _OpenRouterModelPickerSheet(
          models: _openRouterModels,
          activeModel: _activeOpenRouterModel,
        );
      },
    );

    if (!mounted || selected == null) {
      return;
    }

    _activeOpenRouterModel = _normalizeOpenRouterModel(selected);
    _refreshAiCommandService();

    setState(() {});
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

    // Speak assistant replies aloud when conversational voice mode is
    // on. No-op on desktop / web (speaker is null) and when the user
    // hasn't enabled conversational mode.
    if (role == 'assistant' && normalizedContent.isNotEmpty) {
      unawaited(_maybeSpeakReply(normalizedContent));
    }
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

    if (_mode == CopilotMode.commandHelper) {
      _promptController.text = actionPrompt;
      await _generateCommands();
      return;
    }

    _appendChatMessage(role: 'user', content: actionPrompt);
    
    setState(() {
      _isGenerating = true;
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
      
    } catch (error) {
      if (!mounted) return;
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
      return;
    }

    if (!_hasActiveApiKey) {
      return;
    }

    setState(() {
      _isGenerating = true;
    });

    _appendChatMessage(role: 'user', content: prompt);
    _promptController.clear();

    try {
      final steps = await _aiCommandService.generateCommandPlan(prompt);

      if (!mounted) return;

      _disposePlanSteps();
      setState(() {
        _planSteps =
            steps
                .map(
                  (s) => _CopilotPlanStep(
                    title: s.title,
                    controller: TextEditingController(text: s.command),
                    state: CopilotPlanStepState.pending,
                  ),
                )
                .toList();
      });

      _appendChatMessage(
        role: 'assistant',
        content: 'I have generated a ${steps.length}-step plan for your request.',
      );
    } catch (error) {
      if (!mounted) return;
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
      return;
    }

    if (!_hasActiveApiKey) {
      return;
    }

    final existingChatMessages = List<_ChatMessage>.from(_chatMessages);
    _appendChatMessage(role: 'user', content: prompt);
    _promptController.clear();

    setState(() {
      _isGenerating = true;
    });

    try {
      final placeholder = _ChatMessage(role: 'assistant', content: '');
      setState(() {
        _chatMessages = [..._chatMessages, placeholder];
      });
      final placeholderIndex = _chatMessages.length - 1;

      final buffer = StringBuffer();
      await for (final delta in _aiCommandService.streamChatResponse(
        _buildChatPrompt(prompt, historyMessages: existingChatMessages),
      )) {
        if (!mounted) return;
        buffer.write(delta);
        final updated = List<_ChatMessage>.from(_chatMessages);
        updated[placeholderIndex] = _ChatMessage(
          role: 'assistant',
          content: buffer.toString(),
        );
        setState(() {
          _chatMessages = updated;
        });
      }

      if (!mounted) {
        return;
      }

      _saveChatHistory(_chatMessages);
      final finalReply = buffer.toString();
      if (finalReply.trim().isNotEmpty) {
        unawaited(_maybeSpeakReply(finalReply));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      if (_chatMessages.isNotEmpty &&
          _chatMessages.last.role == 'assistant' &&
          _chatMessages.last.content.isEmpty) {
        setState(() {
          _chatMessages = _chatMessages.sublist(0, _chatMessages.length - 1);
        });
      }

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
    });

    try {
      final response = await _aiCommandService.generateChatResponse(
        'Please provide a deep technical explanation of the following Linux command:\n\n$command',
        history: _chatMessages.map((m) => {'role': m.role, 'content': m.content}).toList(),
      );
      
      if (!mounted) return;

      _appendChatMessage(role: 'assistant', content: response);
      
    } catch (error) {
      if (!mounted) return;
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
      return;
    }

    if (!widget.canRunCommands()) {
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
    });

    try {
      final output = await widget.onRunCommand(command);
      if (!mounted) {
        return;
      }

      setState(() {
        if (widget.executionTarget == AiCopilotExecutionTarget.terminal) {
          step.state = CopilotPlanStepState.sentToShell;
        } else {
          step.state = CopilotPlanStepState.executed;
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
      return 'Describe a task or issue...';
    }
    return 'Ask a question...';
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
                  ],
                ),
              ),
              if (_voiceRecognizer != null) ...[
                OnDeviceVoiceChip(active: _voiceSession.audioActive),
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
                  child: VoiceModeToggle(
                    session: _voiceSession,
                    onChanged: (mode) {
                      _voiceSession.setMode(mode);
                      unawaited(
                        _voiceModeStorage.save(widget.serverId, mode),
                      );
                      if (mode == VoiceMode.off) {
                        unawaited(_voiceSpeaker?.stop());
                        unawaited(_voiceRecognizer?.cancel());
                      }
                    },
                  ),
                ),
              ],
              if (_activeProvider == AiProvider.local &&
                  _localMonitor != null) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 2),
                  child: LocalEngineStatusPill(
                    monitor: _localMonitor!,
                    compact: true,
                  ),
                ),
              ],
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

  Widget _buildCommandHelperView(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (_isLoadingActiveApiKey || !_hasActiveApiKey) ...[
          const SizedBox(height: 12),
          _buildApiKeyBanner(theme),
        ],
        const SizedBox(height: 16),
        if (_isGenerating && _planSteps.isEmpty)
          const LoadingBubble(label: 'Building a step-by-step plan...')
        else if (_planSteps.isEmpty)
          const EmptyMessageCard(
            title: 'No Active Plan',
            message: 'Describe a task to generate a step-by-step execution plan.',
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
                        StepNode(number: index + 1),
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
                    child: StepTimelineCard(
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
                      onChanged: (_) => setState(() {}),
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
          ExecutionOutputCard(output: _commandOutput),
        ],
      ],
    );
  }

  Widget _buildGeneralChatView(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (_isLoadingActiveApiKey || !_hasActiveApiKey) ...[
          const SizedBox(height: 12),
          _buildApiKeyBanner(theme),
        ],
        const SizedBox(height: 16),
        if (_isHistoryLoading)
          const LoadingBubble(label: 'Loading previous chat...')
        else if (_chatMessages.isEmpty && !_isGenerating)
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ChatBubble(
                child: SelectableText(
                  'Ask about logs, errors, or Linux concepts.',
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
                          ? UserChatBubble(
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
                                ChatBubble(
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
              child: LoadingBubble(label: 'Thinking...'),
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
              if (_voiceRecognizer != null && _voiceSession.isVoiceEnabled) ...[
                const SizedBox(width: 8),
                VoiceInputButton(
                  recognizer: _voiceRecognizer!,
                  onTranscript: _onVoiceTranscript,
                  onListeningChanged: _onVoiceListeningChanged,
                ),
              ],
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

/// Modal bottom-sheet picker for OpenRouter models.
///
/// Splits the long flat list with a top search field that filters by
/// substring match against the model id (case-insensitive). The
/// "Use Default Model" row sits above the filterable list and is
/// always visible regardless of the query so users can fall back to
/// the bundled default with one tap.
class _OpenRouterModelPickerSheet extends StatefulWidget {
  const _OpenRouterModelPickerSheet({
    required this.models,
    required this.activeModel,
  });

  final List<String> models;
  final String? activeModel;

  @override
  State<_OpenRouterModelPickerSheet> createState() =>
      _OpenRouterModelPickerSheetState();
}

class _OpenRouterModelPickerSheetState
    extends State<_OpenRouterModelPickerSheet> {
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _primaryColor = AppColors.primary;

  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    if (_query.isEmpty) return widget.models;
    final q = _query.toLowerCase();
    return widget.models
        .where((id) => id.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'OpenRouter Models',
                      style: theme.textTheme.titleMedium?.copyWith(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: TextField(
                controller: _searchController,
                autofocus: false,
                decoration: InputDecoration(
                  hintText: 'Search models',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  filled: true,
                  fillColor: _panelColor,
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  final filtered = _filtered;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    children: [
                      ListTile(
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        tileColor: _surfaceColor,
                        title: const Text('Use Default Model'),
                        subtitle: const Text('meta-llama/llama-3-8b-instruct'),
                        trailing: widget.activeModel == null
                            ? const Icon(
                                Icons.check_rounded,
                                color: _primaryColor,
                              )
                            : null,
                        onTap: () => Navigator.of(context).pop(''),
                      ),
                      const SizedBox(height: 8),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 24,
                          ),
                          child: Text(
                            'No models match "$_query"',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.textMuted,
                            ),
                          ),
                        )
                      else
                        ...filtered.map((modelId) {
                          final isSelected = modelId == widget.activeModel;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.zero,
                              ),
                              tileColor: _panelColor,
                              title: Text(modelId),
                              trailing: isSelected
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
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
