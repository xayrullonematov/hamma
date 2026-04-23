import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/command_risk_assessor.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/chat_history_storage.dart';

class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({
    super.key,
    required this.sshService,
    required this.provider,
    required this.apiKey,
    required this.serverId,
  });

  final SshService sshService;
  final AiProvider provider;
  final String apiKey;
  final String serverId;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _primaryColor = Color(0xFF3B82F6);
  static const _dangerColor = Color(0xFFEF4444);

  late AiCommandService _aiCommandService;
  final ChatHistoryStorage _storage = const ChatHistoryStorage();
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Map<String, String>> _sessions = [];
  String? _currentSessionId;
  List<Map<String, dynamic>> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _aiCommandService = AiCommandService.forProvider(
      provider: widget.provider,
      apiKey: widget.apiKey,
    );
    _initChat();
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

      final response = await _aiCommandService.generateChatResponse(
        text,
        history: history,
      );

      final assistantMsg = {
        'role': 'assistant',
        'content': response,
        'timestamp': DateTime.now().toIso8601String(),
        'outputs': <String, String>{},
      };

      if (mounted) {
        setState(() {
          _messages.add(assistantMsg);
          _isLoading = false;
        });
        _scrollToBottom();
        _saveCurrentMessages();
        _updateSessionTitleIfNeeded(text);
      }
    } catch (e) {
      if (mounted) {
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
            _messages[msgIndex]['outputs'] ?? {},
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
            _messages[msgIndex]['outputs'] ?? {},
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
    CommandRiskAssessment assessment,
  ) async {
    final color = _riskColor(assessment.level);
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
                    borderRadius: BorderRadius.circular(8),
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
                      _riskLabel(assessment.level),
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
        return const Color(0xFF22C55E);
      case CommandRiskLevel.warning:
        return const Color(0xFFF59E0B);
      case CommandRiskLevel.dangerous:
        return const Color(0xFFEF4444);
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
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              itemCount: _messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length) return _buildTypingIndicator();
                return _buildMessageBubble(index);
              },
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: _backgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: _createNewChat,
                icon: const Icon(Icons.add),
                label: const Text('New Chat'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  backgroundColor: _primaryColor,
                ),
              ),
            ),
            const Divider(color: Colors.white12),
            Expanded(
              child: ListView.builder(
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final isSelected = session['id'] == _currentSessionId;
                  return ListTile(
                    leading: Icon(
                      Icons.chat_bubble_outline,
                      color: isSelected ? _primaryColor : _mutedColor,
                      size: 20,
                    ),
                    title: Text(
                      session['title'] ?? 'Untitled Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? Colors.white : _mutedColor,
                        fontSize: 14,
                      ),
                    ),
                    selected: isSelected,
                    trailing:
                        isSelected
                            ? null
                            : IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => _deleteSession(session['id']!),
                            ),
                    onTap: () {
                      _loadSession(session['id']!);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(int index) {
    final msg = _messages[index];
    final isUser = msg['role'] == 'user';
    final isSystem = msg['role'] == 'system';

    if (isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            msg['content'],
            style: const TextStyle(
              color: _dangerColor,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final commands = isUser ? <String>[] : _extractCommands(msg['content']);
    final timestamp = DateTime.parse(
      msg['timestamp'] ?? DateTime.now().toIso8601String(),
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
          if (!isUser) _buildAvatar(false),
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
                        data: msg['content'],
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
                            borderRadius: BorderRadius.circular(8),
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
          if (isUser) _buildAvatar(true),
        ],
      ),
    );
  }

  Widget _buildAvatar(bool isUser) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isUser ? _surfaceColor : _primaryColor.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isUser ? Icons.person_outline : Icons.smart_toy_outlined,
        color: isUser ? _mutedColor : _primaryColor,
        size: 18,
      ),
    );
  }

  Widget _buildCommandCard(int msgIndex, String command) {
    final output = _messages[msgIndex]['outputs']?[command];
    final assessment = _riskAssessor.assess(command);
    final color = _riskColor(assessment.level);
    final isError = output?.startsWith('Error:') ?? false;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
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
                        _riskLabel(assessment.level),
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
                      color: Color(0xFFE2E8F0),
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
                    borderRadius: BorderRadius.circular(25),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
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
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                      : const Icon(Icons.arrow_upward),
              style: IconButton.styleFrom(backgroundColor: _primaryColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 24, left: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _surfaceColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Text(
          '...',
          style: TextStyle(color: _mutedColor, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
