import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/command_risk_assessor.dart';
import '../../core/ai/local_engine_health_monitor.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/chat_history_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../core/voice/voice_backend_speech_to_text.dart';
import '../../core/voice/voice_mode_storage.dart';
import '../../core/voice/voice_recognizer.dart';
import '../../core/voice/voice_session.dart';
import '../../core/voice/voice_speaker.dart';
import 'widgets/chat_avatar.dart';
import 'widgets/chat_session_drawer.dart';
import 'widgets/local_engine_status_pill.dart';
import 'widgets/typing_indicator.dart';
import 'widgets/voice_input_button.dart';
import 'widgets/voice_mode_toggle.dart';

class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({
    super.key,
    required this.sshService,
    required this.provider,
    required this.apiKey,
    required this.serverId,
    this.localEndpoint,
    this.localModel,
  });

  final SshService sshService;
  final AiProvider provider;
  final String apiKey;
  final String serverId;

  /// Base URL of the configured local AI engine. Required for the
  /// status pill to render in the header when [provider] is
  /// [AiProvider.local]; also forwarded to [AiCommandService] so chat
  /// requests reach the same engine the pill is monitoring (no
  /// split-brain between header and chat).
  final String? localEndpoint;

  /// Default local model to use for chat (e.g. `gemma3`). Forwarded to
  /// [AiCommandService.forProvider]; ignored when [provider] is not
  /// [AiProvider.local].
  final String? localModel;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _mutedColor = AppColors.textMuted;
  static const _primaryColor = AppColors.textPrimary;
  static const _dangerColor = AppColors.danger;

  late AiCommandService _aiCommandService;
  final ChatHistoryStorage _storage = const ChatHistoryStorage();
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Map<String, String>> _sessions = [];
  String? _currentSessionId;
  List<Map<String, dynamic>> _messages = [];
  bool _isLoading = false;
  LocalEngineHealthMonitor? _localMonitor;

  // Voice — only constructed on iOS/Android. Keeps desktop builds
  // unaffected by the speech_to_text / flutter_tts platform plugins.
  late final VoiceSession _voiceSession = VoiceSession();
  VoiceRecognizer? _voiceRecognizer;
  VoiceSpeaker? _voiceSpeaker;
  // Per-server persistence of VoiceMode so on-call engineers who
  // enable conversational mode for a critical server keep it on
  // across app restarts.
  final VoiceModeStorage _voiceModeStorage = const VoiceModeStorage();
  bool _voiceMicActive = false;

  @override
  void initState() {
    super.initState();
    _aiCommandService = AiCommandService.forProvider(
      provider: widget.provider,
      apiKey: widget.apiKey,
      localEndpoint: widget.localEndpoint,
      localModel: widget.localModel,
    );
    final endpoint = widget.localEndpoint?.trim();
    if (widget.provider == AiProvider.local &&
        endpoint != null &&
        endpoint.isNotEmpty) {
      _localMonitor = LocalEngineHealthMonitor(endpoint: endpoint);
    }
    _maybeInitVoice();
    _initChat();
  }

  /// Constructs the voice subsystem on supported mobile platforms.
  /// Desktop / web simply skip — the mic button never renders so
  /// the speech_to_text plugin is never touched.
  void _maybeInitVoice() {
    if (kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    _voiceRecognizer = VoiceRecognizer(backend: SpeechToTextBackend());
    _voiceSpeaker = VoiceSpeaker();
    _voiceSession.addListener(_onVoiceSessionChanged);
    // Restore the user's last voice mode for this server.
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
    _inputController.text = text;
    _sendMessage();
  }

  void _onVoiceListeningChanged(bool listening) {
    if (_voiceMicActive == listening) return;
    setState(() => _voiceMicActive = listening);
    _voiceSession.setAudioActive(listening);
  }

  Future<void> _maybeSpeakReply(String reply) async {
    final speaker = _voiceSpeaker;
    if (speaker == null || !_voiceSession.isConversational) return;
    _voiceSession.setAudioActive(true);
    try {
      await speaker.speak(reply);
    } finally {
      if (mounted && !_voiceMicActive) {
        _voiceSession.setAudioActive(false);
      }
    }
  }

  Future<void> _initChat() async {
    final sessions = await _storage.listSessions(serverId: widget.serverId);
    setState(() => _sessions = sessions);
    if (sessions.isNotEmpty) {
      _loadSession(sessions.first['id']!);
    } else {
      _createNewChat();
    }
  }

  Future<void> _loadSession(String sessionId) async {
    final messages = await _storage.loadMessages(
      serverId: widget.serverId,
      sessionId: sessionId,
    );
    setState(() {
      _currentSessionId = sessionId;
      _messages = messages;
    });
    _scrollToBottom();
  }

  Future<void> _createNewChat() async {
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    final newSession = {
      'id': sessionId,
      'title': 'New Chat',
      'timestamp': DateTime.now().toIso8601String(),
    };
    final sessions = [newSession, ..._sessions];
    await _storage.saveSessions(serverId: widget.serverId, sessions: sessions);
    setState(() {
      _sessions = sessions;
      _currentSessionId = sessionId;
      _messages = [];
    });
    if (!mounted) return;
    if (Navigator.canPop(context)) Navigator.pop(context); // Close drawer
  }

  Future<void> _deleteSession(String sessionId) async {
    await _storage.deleteSession(
      serverId: widget.serverId,
      sessionId: sessionId,
    );
    if (_currentSessionId == sessionId) {
      _initChat();
    } else {
      final sessions = await _storage.listSessions(serverId: widget.serverId);
      setState(() => _sessions = sessions);
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    unawaited(_localMonitor?.dispose());
    _localMonitor = null;
    _voiceSession.removeListener(_onVoiceSessionChanged);
    unawaited(_voiceSpeaker?.stop());
    unawaited(_voiceRecognizer?.cancel());
    _voiceRecognizer?.dispose();
    _voiceSession.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isLoading || _currentSessionId == null) return;

    _inputController.clear();
    final userMsg = {
      'role': 'user',
      'content': text,
      'timestamp': DateTime.now().toIso8601String(),
    };

    setState(() {
      _messages.add(userMsg);
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      // Prepare history (limit to last 10 for context window)
      final history =
          _messages
              .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
              .take(_messages.length - 1)
              .map(
                (m) => {
                  'role': m['role'] as String,
                  'content': m['content'] as String,
                },
              )
              .toList();

      // Streaming path: insert an empty assistant message and append
      // tokens as they arrive. For non-local providers, the stream emits
      // the full reply once, so the UX is identical (just no token-by-token
      // animation). For local providers (Ollama / LM Studio / llama.cpp),
      // the user sees a real typewriter effect.
      final assistantMsg = <String, dynamic>{
        'role': 'assistant',
        'content': '',
        'timestamp': DateTime.now().toIso8601String(),
        'outputs': <String, String>{},
      };
      if (mounted) {
        setState(() {
          _messages.add(assistantMsg);
        });
        _scrollToBottom();
      }
      final assistantIndex = _messages.length - 1;
      final buffer = StringBuffer();

      await for (final delta in _aiCommandService.streamChatResponse(
        text,
        history: history,
      )) {
        if (!mounted) return;
        buffer.write(delta);
        setState(() {
          _messages[assistantIndex]['content'] = buffer.toString();
        });
        _scrollToBottom();
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _scrollToBottom();
        _saveCurrentMessages();
        _updateSessionTitleIfNeeded(text);
        unawaited(_maybeSpeakReply(buffer.toString()));
      }
    } catch (e) {
      if (mounted) {
        // Drop the placeholder assistant bubble if it was inserted but
        // never received any content; surface a system error instead.
        if (_messages.isNotEmpty &&
            _messages.last['role'] == 'assistant' &&
            ((_messages.last['content'] as String?) ?? '').isEmpty) {
          _messages.removeLast();
        }
        setState(() {
          _messages.add({
            'role': 'system',
            'content': 'Error: $e',
            'timestamp': DateTime.now().toIso8601String(),
          });
          _isLoading = false;
        });
        _scrollToBottom();
      }
    }
  }

  void _saveCurrentMessages() {
    if (_currentSessionId != null) {
      _storage.saveMessages(
        serverId: widget.serverId,
        sessionId: _currentSessionId!,
        messages: _messages,
      );
    }
  }

  void _updateSessionTitleIfNeeded(String firstMessage) {
    if (_messages.length <= 2) {
      final title =
          firstMessage.length > 30
              ? '${firstMessage.substring(0, 27)}...'
              : firstMessage;
      final sessionIndex = _sessions.indexWhere(
        (s) => s['id'] == _currentSessionId,
      );
      if (sessionIndex != -1) {
        setState(() {
          _sessions[sessionIndex]['title'] = title;
        });
        _storage.saveSessions(serverId: widget.serverId, sessions: _sessions);
      }
    }
  }

  Future<void> _runCommand(int msgIndex, String command) async {
    if (!widget.sshService.isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('SSH not connected')));
      return;
    }

    final assessment = _riskAssessor.assess(command);
    final confirmed = await _showRiskDialog(command, assessment);
    if (!confirmed) return;

    try {
      final output = await widget.sshService.execute(command);
      if (mounted) {
        setState(() {
          final outputs = Map<String, dynamic>.from(
            (_messages[msgIndex]['outputs'] as Map?) ?? <String, dynamic>{},
          );
          outputs[command] = output.isEmpty ? '(No output)' : output;
          _messages[msgIndex]['outputs'] = outputs;
        });
        _saveCurrentMessages();
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          final outputs = Map<String, dynamic>.from(
            (_messages[msgIndex]['outputs'] as Map?) ?? <String, dynamic>{},
          );
          outputs[command] = 'Error: $e';
          _messages[msgIndex]['outputs'] = outputs;
        });
        _saveCurrentMessages();
        _scrollToBottom();
      }
    }
  }

  Future<void> _reportAndAnalyzeError(String command, String error) async {
    setState(() => _isLoading = true);

    try {
      // 1. Send to Sentry
      Sentry.addBreadcrumb(
        Breadcrumb(
          message: 'User initiated Smart Error Analysis',
          category: 'ai_assistant',
          data: {'command': command, 'error': error},
        ),
      );
      Sentry.captureMessage(
        'SSH Command Execution Failure: $command',
        level: SentryLevel.error,
        withScope: (scope) {
          scope.setContexts('Execution Details', {
            'command': command,
            'error': error,
          });
        },
      );

      // 2. Prompt AI for analysis
      final analysisPrompt =
          'The following Linux command failed with an error. Please provide a deep technical explanation of why this specific error occurred and how to resolve it.\n\nCommand: $command\nError: $error';
      final history =
          _messages
              .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
              .map(
                (m) => {
                  'role': m['role'] as String,
                  'content': m['content'] as String,
                },
              )
              .toList();

      final response = await _aiCommandService.generateChatResponse(
        analysisPrompt,
        history: history,
      );

      if (mounted) {
        setState(() {
          _messages.add({
            'role': 'assistant',
            'content': '### Smart Error Analysis\n\n$response',
            'timestamp': DateTime.now().toIso8601String(),
          });
          _isLoading = false;
        });
        _scrollToBottom();
        _saveCurrentMessages();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add({
            'role': 'system',
            'content': 'Analysis failed: $e',
            'timestamp': DateTime.now().toIso8601String(),
          });
          _isLoading = false;
        });
        _scrollToBottom();
      }
    }
  }

  Future<bool> _showRiskDialog(
    String command,
    CommandAnalysis assessment,
  ) async {
    final color = _riskColor(assessment.riskLevel);
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Run Command'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.zero,
                  ),
                  child: Text(
                    command,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: color, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      _riskLabel(assessment.riskLevel),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  assessment.explanation,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Run'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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

  List<String> _extractCommands(String content) {
    final regex = RegExp(
      r'```(?:bash|sh|shell|linux|)\n([\s\S]*?)\n```',
      multiLine: true,
    );
    return regex
        .allMatches(content)
        .map((m) => m.group(1)!.trim())
        .where((cmd) => cmd.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: const Text('AI Assistant'),
        elevation: 0,
        actions: [
          if (_voiceRecognizer != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: OnDeviceVoiceChip(active: _voiceSession.audioActive),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 12,
              ),
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
          if (_localMonitor != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: LocalEngineStatusPill(monitor: _localMonitor!),
            ),
        ],
      ),
      drawer: ChatSessionDrawer(
        sessions: _sessions,
        currentSessionId: _currentSessionId,
        onCreateNewChat: _createNewChat,
        onLoadSession: _loadSession,
        onDeleteSession: _deleteSession,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              itemCount: _messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length) return const TypingIndicator();
                return _buildMessageBubble(index);
              },
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(int index) {
    final msg = _messages[index];
    final isUser = msg['role'] == 'user';
    final isSystem = msg['role'] == 'system';
    // _messages is List<Map<String, dynamic>>; values arrive as `dynamic`
    // (often from jsonDecode). Coerce once here so the rest of the widget
    // can treat them as proper Strings.
    final content = (msg['content'] as String?) ?? '';

    if (isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            content,
            style: const TextStyle(
              color: _dangerColor,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final commands = isUser ? <String>[] : _extractCommands(content);
    final timestamp = DateTime.parse(
      (msg['timestamp'] as String?) ?? DateTime.now().toIso8601String(),
    );
    final timeStr =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) const ChatAvatar(isUser: false),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isUser ? _primaryColor : _surfaceColor,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 0),
                      bottomRight: Radius.circular(isUser ? 0 : 16),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkdownBody(
                        data: content,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(
                            color: Colors.white,
                            height: 1.5,
                            fontSize: 14,
                          ),
                          code: const TextStyle(
                            backgroundColor: Colors.black26,
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                          codeblockDecoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        timeStr,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                if (commands.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...commands.map((cmd) => _buildCommandCard(index, cmd)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (isUser) const ChatAvatar(isUser: true),
        ],
      ),
    );
  }

  Widget _buildCommandCard(int msgIndex, String command) {
    // outputs map is also dynamic-typed; cast at the source so
    // downstream conditions (`isError`) and Text widgets get a proper
    // String? instead of dynamic.
    final outputsRaw = _messages[msgIndex]['outputs'];
    final output = (outputsRaw is Map) ? outputsRaw[command] as String? : null;
    final assessment = _riskAssessor.assess(command);
    final color = _riskColor(assessment.riskLevel);
    final isError = output?.startsWith('Error:') ?? false;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.terminal, color: _primaryColor, size: 14),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Suggested Command',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (output == null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.play_arrow,
                          color: _primaryColor,
                          size: 20,
                        ),
                        onPressed: () => _runCommand(msgIndex, command),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  command,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
                if (output == null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: color, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        _riskLabel(assessment.riskLevel),
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (output != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Result:',
                        style: TextStyle(
                          color: _mutedColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (isError)
                        TextButton.icon(
                          onPressed: () => _reportAndAnalyzeError(command, output),
                          icon: const Icon(
                            Icons.analytics_outlined,
                            size: 14,
                          ),
                          label: const Text(
                            'Report & Analyze',
                            style: TextStyle(fontSize: 10),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: _primaryColor,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    output,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: _backgroundColor,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                onSubmitted: (_) => _sendMessage(),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Ask your assistant...',
                  hintStyle: const TextStyle(color: _mutedColor),
                  filled: true,
                  fillColor: _surfaceColor,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: const BorderSide(color: AppColors.border, width: 1),
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
            const SizedBox(width: 12),
            IconButton.filled(
              onPressed: _isLoading ? null : _sendMessage,
              icon:
                  _isLoading
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(
                            AppColors.scaffoldBackground,
                          ),
                        ),
                      )
                      : const Icon(Icons.arrow_upward),
              style: IconButton.styleFrom(
                backgroundColor: _primaryColor,
                foregroundColor: AppColors.scaffoldBackground,
              ),
            ),
          ],
        ),
      ),
    );
  }

}
