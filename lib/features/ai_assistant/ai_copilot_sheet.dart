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
import 'copilot/widgets/copilot_chrome.dart';
import 'copilot/widgets/step_timeline_card.dart';
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
    this.isModal = true,
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
  final bool isModal;

  @override
  State<AiCopilotSheet> createState() => _AiCopilotSheetState();
}

class _AiCopilotSheetState extends State<AiCopilotSheet> {
  static const _sheetBackground = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _primaryColor = AppColors.textPrimary;
  static const _mutedColor = AppColors.textMuted;
  static const _warningColor = AppColors.danger;
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

  late final VoiceSession _voiceSession = VoiceSession();
  final VoiceModeStorage _voiceModeStorage = const VoiceModeStorage();
  VoiceRecognizer? _voiceRecognizer;

  late AiProvider _activeProvider;
  late String? _activeOpenRouterModel;
  String _activeApiKey = '';
  CopilotMode _mode = CopilotMode.commandHelper;
  bool _isGenerating = false;
  bool _isHistoryLoading = true;
  bool _isLoadingActiveApiKey = true;
  bool _hasLoadedOpenRouterModels = false;
  int? _runningCommandIndex;
  List<_CopilotPlanStep> _planSteps = [];
  List<_ChatMessage> _chatMessages = const [];
  String _commandOutput = '';
  List<String> _openRouterModels = const [];
  int _providerLoadGeneration = 0;
  LocalEngineHealthMonitor? _localMonitor;

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

  void _maybeInitVoice() {
    if (kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    _voiceRecognizer = VoiceRecognizer(backend: SpeechToTextBackend());
    _voiceSession.addListener(_onVoiceSessionChanged);
    unawaited(() async {
      final saved = await _voiceModeStorage.load(widget.serverId);
      if (mounted && saved != VoiceMode.off) {
        _voiceSession.setMode(saved);
      }
    }());
  }

  @override
  void dispose() {
    _voiceSession.removeListener(_onVoiceSessionChanged);
    _promptController.dispose();
    _localMonitor?.dispose();
    _disposePlanSteps();
    super.dispose();
  }

  void _disposePlanSteps() {
    for (final step in _planSteps) {
      step.controller.dispose();
    }
    _planSteps = [];
  }

  void _onVoiceSessionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _seedInitialPrompt() {
    if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
      _promptController.text = widget.initialPrompt!;
    }
  }

  void _syncLocalEngineMonitor() {
    final endpoint = widget.localEndpoint;
    if (endpoint == null || endpoint.isEmpty) {
      _localMonitor = null;
      return;
    }
    _localMonitor = LocalEngineHealthMonitor(endpoint: endpoint);
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

  Future<void> _loadChatHistory() async {
    setState(() => _isHistoryLoading = true);
    final history = await _chatHistoryStorage.loadHistory(serverId: widget.serverId);
    if (mounted) {
      setState(() {
        _chatMessages = history.map((e) => _ChatMessage(
          role: e['role'] ?? 'user',
          content: e['content'] ?? '',
        )).toList();
        _isHistoryLoading = false;
      });
    }
  }

  Future<void> _loadActiveProviderState() async {
    final generation = ++_providerLoadGeneration;
    setState(() => _isLoadingActiveApiKey = true);

    final key = await widget.apiKeyStorage.loadApiKey(_activeProvider);
    if (generation != _providerLoadGeneration || !mounted) return;

    setState(() {
      _activeApiKey = key ?? '';
      _isLoadingActiveApiKey = false;
      _refreshAiCommandService();
    });
  }

  Future<void> _handleProviderSelected(AiProvider provider) async {
    if (provider == _activeProvider) return;
    setState(() {
      _activeProvider = provider;
      _isLoadingActiveApiKey = true;
    });
    await _loadActiveProviderState();
  }

  String? _normalizeOpenRouterModel(String? model) {
    if (model == null || model.trim().isEmpty) return null;
    return model.trim();
  }

  void _showOpenRouterModelPicker() {
    unawaited(showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _OpenRouterModelPickerSheet(
        models: _openRouterModels,
        activeModel: _activeOpenRouterModel,
      ),
    ).then((selected) {
      if (selected != null && mounted) {
        setState(() {
          _activeOpenRouterModel = selected.isEmpty ? null : selected;
          _refreshAiCommandService();
        });
      }
    }));

    if (!_hasLoadedOpenRouterModels) {
      unawaited(_fetchOpenRouterModels());
    }
  }

  Future<void> _fetchOpenRouterModels() async {
    try {
      final resp = await http.get(Uri.parse(_openRouterModelsUrl));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final models = (data['data'] as List)
            .map((m) => m['id'] as String)
            .toList();
        models.sort();
        if (mounted) {
          setState(() {
            _openRouterModels = models;
            _hasLoadedOpenRouterModels = true;
          });
        }
      } else {
        throw Exception('HTTP ${resp.statusCode}');
      }
    } catch (_) {
      // Silently fail or show error if needed
    }
  }

  void _clearChatHistory() {
    unawaited(_chatHistoryStorage.clearHistory(serverId: widget.serverId));
    setState(() {
      _chatMessages = [];
      _disposePlanSteps();
      _commandOutput = '';
    });
  }

  void _handleQuickAction(String prompt) {
    _promptController.text = prompt;
    _submitPrompt();
  }

  Future<void> _generateCommands() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    _promptController.clear();
    _disposePlanSteps();
    setState(() {
      _isGenerating = true;
      _commandOutput = '';
    });

    try {
      final plan = await _aiCommandService.generateCommandPlan(prompt);

      if (mounted) {
        setState(() {
          _planSteps = plan.map((s) => _CopilotPlanStep(
            title: s.title,
            controller: TextEditingController(text: s.command),
            state: CopilotPlanStepState.pending,
          )).toList();
          _isGenerating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        _showError(e.toString());
      }
    }
  }

  Future<void> _generateChatResponse() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    _promptController.clear();
    final userMessage = _ChatMessage(role: 'user', content: prompt);
    setState(() {
      _chatMessages = [..._chatMessages, userMessage];
      _isGenerating = true;
    });

    try {
      final response = await _aiCommandService.generateChatResponse(
        prompt,
        history: _chatMessages.map((m) => {'role': m.role, 'content': m.content}).toList(),
      );

      if (mounted) {
        setState(() {
          _chatMessages = [
            ..._chatMessages,
            _ChatMessage(
              role: 'assistant',
              content: response,
            ),
          ];
          _isGenerating = false;
        });
        unawaited(_chatHistoryStorage.saveHistory(
          serverId: widget.serverId, 
          messages: _chatMessages.map((m) => {'role': m.role, 'content': m.content}).toList(),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        _showError(e.toString());
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: _warningColor),
    );
  }

  Future<bool> _confirmHighRiskCommand(String command, CommandRiskLevel level) async {
    final isCritical = level == CommandRiskLevel.critical;
    final title = isCritical ? 'CRITICAL RISK COMMAND' : 'HIGH RISK COMMAND';
    final confirmWord = isCritical ? 'CONFIRM' : null;
    
    final controller = TextEditingController();
    
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isValid = confirmWord == null || controller.text == confirmWord;
            return AlertDialog(
              backgroundColor: AppColors.panel,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: isCritical ? Colors.purple : Colors.red, width: 2),
                borderRadius: BorderRadius.zero,
              ),
              title: Text(title, style: TextStyle(color: isCritical ? Colors.purple : Colors.red, fontWeight: FontWeight.bold, fontFamily: AppColors.monoFamily)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('You are about to execute a dangerous command. Please review it carefully:', style: TextStyle(color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    color: AppColors.surface,
                    width: double.infinity,
                    child: SelectableText(command, style: const TextStyle(color: Colors.white, fontFamily: AppColors.monoFamily, fontSize: 12)),
                  ),
                  if (confirmWord != null) ...[
                    const SizedBox(height: 16),
                    Text('Type "$confirmWord" to proceed:', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      onChanged: (_) => setDialogState(() {}),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide.none),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('CANCEL', style: TextStyle(color: AppColors.textMuted)),
                ),
                FilledButton(
                  onPressed: isValid ? () => Navigator.of(context).pop(true) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: isCritical ? Colors.purple : Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('EXECUTE'),
                ),
              ],
            );
          }
        );
      }
    ) ?? false;
  }

  Future<void> _runCommand(int index) async {
    if (!widget.canRunCommands()) {
      _showError(widget.executionUnavailableMessage);
      return;
    }

    final step = _planSteps[index];
    final command = step.controller.text;
    final assessment = _riskAssessor.assess(command);

    if (assessment.riskLevel == CommandRiskLevel.critical || assessment.riskLevel == CommandRiskLevel.high) {
      final confirmed = await _confirmHighRiskCommand(command, assessment.riskLevel);
      if (!confirmed) return;
    }

    setState(() {
      _runningCommandIndex = index;
      step.state = CopilotPlanStepState.sentToShell;
    });

    try {
      final output = await widget.onRunCommand(step.controller.text);
      if (mounted) {
        setState(() {
          step.state = output == null ? CopilotPlanStepState.failed : CopilotPlanStepState.executed;
          _commandOutput = output ?? 'Command failed or produced no output.';
          _runningCommandIndex = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          step.state = CopilotPlanStepState.failed;
          _commandOutput = e.toString();
          _runningCommandIndex = null;
        });
      }
    }
  }

  void _onVoiceTranscript(String text) {
    _promptController.text = text;
  }

  void _onVoiceListeningChanged(bool listening) {
    setState(() {});
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
    if (_isGenerating || _isRunningStep || _isHistoryLoading || _isLoadingActiveApiKey || !_hasActiveApiKey) {
      return;
    }
    if (_mode == CopilotMode.commandHelper) {
      _generateCommands();
    } else {
      _generateChatResponse();
    }
  }

  String _promptHintText() {
    return _mode == CopilotMode.commandHelper ? 'Describe a task...' : 'Ask a question...';
  }

  Widget _buildModeTab(String label, CopilotMode mode) {
    final bool isSelected = _mode == mode;
    return GestureDetector(
      onTap: _isRunningStep ? null : () => _switchMode(mode),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: isSelected ? Colors.white : _mutedColor,
            ),
          ),
          const SizedBox(height: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 2,
            width: 16,
            decoration: BoxDecoration(
              color: isSelected ? _primaryColor : Colors.transparent,
              borderRadius: BorderRadius.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
      child: Row(
        children: [
          if (_voiceRecognizer != null) ...[
            OnDeviceVoiceChip(active: _voiceSession.audioActive),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4),
              child: VoiceModeToggle(
                session: _voiceSession,
                onChanged: (mode) {
                  _voiceSession.setMode(mode);
                  unawaited(_voiceModeStorage.save(widget.serverId, mode));
                },
              ),
            ),
          ],
          if (_activeProvider == AiProvider.local && _localMonitor != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: LocalEngineStatusPill(monitor: _localMonitor!, compact: true),
            ),
          ],
          const Spacer(),
          PopupMenuButton<dynamic>(
            enabled: !_isGenerating && !_isRunningStep,
            color: _surfaceColor,
            icon: Icon(
              Icons.tune_rounded,
              color: _hasActiveApiKey ? _mutedColor : _warningColor,
              size: 20,
            ),
            tooltip: 'Model Settings',
            onSelected: (value) async {
              if (value is AiProvider) {
                await _handleProviderSelected(value);
              } else if (value == 'select_model') {
                _showOpenRouterModelPicker();
              }
            },
            itemBuilder: (context) {
              return [
                const PopupMenuItem<void>(
                  enabled: false,
                  child: Text(
                    'AI PROVIDER',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: AppColors.textFaint),
                  ),
                ),
                ...AiProvider.values.map((provider) => PopupMenuItem<AiProvider>(
                  value: provider,
                  child: Row(
                    children: [
                      Expanded(child: Text(provider.label)),
                      if (provider == _activeProvider) const Icon(Icons.check_rounded, color: _primaryColor, size: 18),
                    ],
                  ),
                )),
                if (_activeProvider == AiProvider.openRouter) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem<void>(
                    enabled: false,
                    child: Text(
                      'ACTIVE MODEL',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: AppColors.textFaint),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'select_model',
                    child: Row(
                      children: [
                        Expanded(child: Text(_activeOpenRouterModel ?? 'Default model', maxLines: 1, overflow: TextOverflow.ellipsis)),
                        const Icon(Icons.chevron_right_rounded, size: 18),
                      ],
                    ),
                  ),
                ],
              ];
            },
          ),
          IconButton(
            onPressed: _isHistoryLoading || _isGenerating || _chatMessages.isEmpty ? null : _clearChatHistory,
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            color: _mutedColor,
            tooltip: 'Clear chat',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            color: _mutedColor,
            tooltip: 'Close',
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
        child: Row(
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text('Loading ${_activeProvider.label} API key...', style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor))),
          ],
        ),
      );
    }
    if (_hasActiveApiKey) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: _warningColor.withValues(alpha: 0.12)),
      child: Text('API key missing. Configure it in Settings.', style: theme.textTheme.bodySmall?.copyWith(color: _warningColor, fontWeight: FontWeight.w700)),
    );
  }

  Widget _buildCommandHelperView(ThemeData theme) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (_isLoadingActiveApiKey || !_hasActiveApiKey) ...[
          const SizedBox(height: 12),
          _buildApiKeyBanner(theme),
        ],
        if (_isGenerating && _planSteps.isEmpty)
          const LoadingBubble(label: 'Building plan...')
        else if (_planSteps.isEmpty)
          const EmptyMessageCard(title: 'No Active Plan', message: 'Describe a task to generate a plan.'),
        ...List.generate(_planSteps.length, (index) {
          final step = _planSteps[index];
          final assessment = _riskAssessor.assess(step.controller.text);
          final pendingPrevious = _planSteps.sublist(0, index).any((s) => s.state != CopilotPlanStepState.executed);
          final isRunning = _runningCommandIndex == index;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(children: [const SizedBox(height: 4), StepNode(number: index + 1)]),
                const SizedBox(width: 16),
                Expanded(
                  child: StepTimelineCard(
                    title: step.title,
                    controller: step.controller,
                    stateLabel: step.state.name.toUpperCase(),
                    stateColor: step.state == CopilotPlanStepState.executed ? Colors.green : _mutedColor,
                    riskLabel: assessment.riskLevel.name.toUpperCase(),
                    riskColor: _riskColor(assessment.riskLevel),
                    riskExplanation: assessment.explanation,
                    warningText: pendingPrevious ? 'Previous steps incomplete.' : null,
                    isRunning: isRunning,
                    isBusy: _isGenerating || _isRunningStep,
                    onChanged: (_) => setState(() {}),
                    onRun: () => _runCommand(index),
                  ),
                ),
              ],
            ),
          );
        }),
        if (widget.executionTarget == AiCopilotExecutionTarget.dashboard && _commandOutput.isNotEmpty)
          ExecutionOutputCard(output: _commandOutput),
      ],
    );
  }

  Color _riskColor(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.low: return Colors.green;
      case CommandRiskLevel.moderate: return Colors.orange;
      case CommandRiskLevel.high: return Colors.red;
      case CommandRiskLevel.critical: return Colors.purple;
    }
  }

  Widget _buildGeneralChatView(ThemeData theme) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (_isLoadingActiveApiKey || !_hasActiveApiKey) ...[
          const SizedBox(height: 12),
          _buildApiKeyBanner(theme),
        ],
        if (_isHistoryLoading)
          const LoadingBubble(label: 'Loading chat...')
        else if (_chatMessages.isEmpty && !_isGenerating)
          const ChatBubble(child: Text('Ask about logs, errors, or Linux concepts.', style: TextStyle(color: AppColors.textMuted, height: 1.5)))
        else
          ..._chatMessages.map((message) {
            final isUser = message.role == 'user';
            return isUser
                ? UserChatBubble(child: SelectableText(message.content, style: const TextStyle(color: Colors.white, height: 1.5)))
                : ChatBubble(
                  child: SelectableText(message.content, style: const TextStyle(color: Colors.white, height: 1.5)),
                );
          }),
        if (_isGenerating) const LoadingBubble(label: 'Thinking...'),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Container(
      height: 34,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        itemCount: _quickActionPrompts.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final prompt = _quickActionPrompts[index];
          return ActionChip(
            label: Text(prompt.toUpperCase(), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
            onPressed: () => _handleQuickAction(prompt),
            backgroundColor: _panelColor,
            labelStyle: const TextStyle(color: AppColors.textMuted),
            side: const BorderSide(color: AppColors.border, width: 0.5),
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
        },
      ),
    );
  }

  Widget _buildComposer(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildQuickActions(),
          Container(
            decoration: const BoxDecoration(color: _surfaceColor, border: Border.symmetric(horizontal: BorderSide(color: AppColors.border, width: 0.5))),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _promptController,
                    enabled: !_isLoadingActiveApiKey && _hasActiveApiKey,
                    minLines: 1,
                    maxLines: 8,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: _promptHintText().toUpperCase(),
                      hintStyle: const TextStyle(color: AppColors.textFaint, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2),
                      filled: true,
                      fillColor: Colors.transparent,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_voiceRecognizer != null && _voiceSession.isVoiceEnabled) ...[
                  VoiceInputButton(recognizer: _voiceRecognizer!, onTranscript: _onVoiceTranscript, onListeningChanged: _onVoiceListeningChanged),
                  const SizedBox(width: 4),
                ],
                Builder(builder: (context) {
                  final bool isDisabled = _isGenerating || _isRunningStep || _isLoadingActiveApiKey || !_hasActiveApiKey;
                  final Color iconColor = isDisabled ? AppColors.textFaint : Colors.white;
                  return IconButton(
                    onPressed: isDisabled || _isHistoryLoading ? null : _submitPrompt,
                    icon: _isGenerating
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5, color: iconColor))
                        : const Icon(Icons.arrow_upward_rounded, size: 20),
                    color: iconColor,
                    tooltip: _mode == CopilotMode.commandHelper ? 'Generate plan' : 'Send prompt',
                  );
                }),
              ],
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
      borderRadius: widget.isModal
          ? const BorderRadius.vertical(top: Radius.circular(30))
          : BorderRadius.zero,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(0, widget.isModal ? 12 : 0, 0, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isModal)
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(color: _mutedColor.withValues(alpha: 0.5), borderRadius: BorderRadius.zero),
                  ),
                ),
              const SizedBox(height: 8),
              _buildHeader(theme),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    _buildModeTab('PLAN', CopilotMode.commandHelper),
                    const SizedBox(width: 24),
                    _buildModeTab('CHAT', CopilotMode.generalChat),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(child: _mode == CopilotMode.commandHelper ? _buildCommandHelperView(theme) : _buildGeneralChatView(theme)),
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
  _CopilotPlanStep({required this.title, required this.controller, required this.state});
  final String title;
  final TextEditingController controller;
  CopilotPlanStepState state;
}

class _ChatMessage {
  const _ChatMessage({required this.role, required this.content});
  final String role;
  final String content;
}

class _OpenRouterModelPickerSheet extends StatefulWidget {
  const _OpenRouterModelPickerSheet({required this.models, required this.activeModel});
  final List<String> models;
  final String? activeModel;
  @override
  State<_OpenRouterModelPickerSheet> createState() => _OpenRouterModelPickerSheetState();
}

class _OpenRouterModelPickerSheetState extends State<_OpenRouterModelPickerSheet> {
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _primaryColor = AppColors.primary;
  final _searchController = TextEditingController();
  String _query = '';
  @override
  void dispose() { _searchController.dispose(); super.dispose(); }
  List<String> get _filtered {
    if (_query.isEmpty) return widget.models;
    final q = _query.toLowerCase();
    return widget.models.where((id) => id.toLowerCase().contains(q)).toList(growable: false);
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
                  Expanded(child: Text('OpenRouter Models', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700))),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
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
                  border: const OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  suffixIcon: _query.isEmpty ? null : IconButton(icon: const Icon(Icons.close_rounded, size: 16), tooltip: 'Clear search', onPressed: () { _searchController.clear(); setState(() => _query = ''); }),
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
            Expanded(
              child: Builder(builder: (context) {
                final filtered = _filtered;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: [
                    ListTile(
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      tileColor: _surfaceColor,
                      title: const Text('Use Default Model'),
                      subtitle: const Text('meta-llama/llama-3-8b-instruct'),
                      trailing: widget.activeModel == null ? const Icon(Icons.check_rounded, color: _primaryColor) : null,
                      onTap: () => Navigator.of(context).pop(''),
                    ),
                    const SizedBox(height: 8),
                    if (filtered.isEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), child: Text('No models match "$_query"', style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textMuted)))
                    else ...filtered.map((modelId) {
                      final isSelected = modelId == widget.activeModel;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                          tileColor: _panelColor,
                          title: Text(modelId),
                          trailing: isSelected ? const Icon(Icons.check_rounded, color: _primaryColor) : null,
                          onTap: () => Navigator.of(context).pop(modelId),
                        ),
                      );
                    }),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
