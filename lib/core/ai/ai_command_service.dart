import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';
import 'command_risk_assessor.dart';

class AiApiConfig {
  const AiApiConfig({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  factory AiApiConfig.forProvider({
    required AiProvider provider,
    required String apiKey,
    String? openRouterModel,
    String? localEndpoint,
    String? localModel,
  }) {
    switch (provider) {
      case AiProvider.openAi:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: apiKey,
          model: 'gpt-4o-mini',
        );
      case AiProvider.gemini:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKey: apiKey,
          model: 'gemini-1.5-flash',
        );
      case AiProvider.openRouter:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://openrouter.ai/api/v1',
          apiKey: apiKey,
          model: (openRouterModel?.trim().isNotEmpty ?? false)
              ? openRouterModel!.trim()
              : 'meta-llama/llama-3-8b-instruct',
        );
      case AiProvider.local:
        final endpoint = (localEndpoint?.trim().isNotEmpty ?? false)
            ? localEndpoint!.trim()
            : 'http://localhost:11434';
        return AiApiConfig(
          provider: provider,
          baseUrl: '$endpoint/v1',
          apiKey: 'local',
          model: (localModel?.trim().isNotEmpty ?? false)
              ? localModel!.trim()
              : 'gemma3',
        );
    }
  }

  final AiProvider provider;
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured {
    if (provider == AiProvider.local) {
      return baseUrl.isNotEmpty;
    }
    return apiKey.trim().isNotEmpty;
  }
}

class CommandIntent {
  const CommandIntent({
    required this.action,
    this.targetServer,
    required this.command,
    required this.explanation,
  });

  final String action;
  final String? targetServer;
  final String command;
  final String explanation;

  factory CommandIntent.fromJson(Map<String, dynamic> json) {
    return CommandIntent(
      action: json['action'] as String? ?? 'Execute Command',
      targetServer: json['target_server'] as String?,
      command: json['command'] as String? ?? '',
      explanation: json['explanation'] as String? ?? '',
    );
  }
}

class AiCommandService {
  const AiCommandService({
    required this.config,
    this.openRouterModel,
  });

  factory AiCommandService.forProvider({
    required AiProvider provider,
    required String apiKey,
    String? openRouterModel,
    String? localEndpoint,
    String? localModel,
  }) {
    return AiCommandService(
      config: AiApiConfig.forProvider(
        provider: provider,
        apiKey: apiKey,
        openRouterModel: openRouterModel,
        localEndpoint: localEndpoint,
        localModel: localModel,
      ),
      openRouterModel: openRouterModel,
    );
  }

  static const _chatInstruction =
      'You are Hamma Assistant, a concise Linux and server operations expert. '
      'Explain errors, logs, and concepts clearly. '
      'If you suggest commands, wrap them in markdown code blocks like ```bash\\ncommand\\n```. '
      'Keep responses professional and focused on system administration.';

  final AiApiConfig config;
  final String? openRouterModel;

  Duration get _connectionTimeout =>
      config.provider == AiProvider.local
          ? const Duration(seconds: 5)
          : const Duration(seconds: 15);

  Duration get _responseTimeout =>
      config.provider == AiProvider.local
          ? const Duration(seconds: 120)
          : const Duration(seconds: 30);

  String _localUnavailableMessage() {
    final host = config.baseUrl.replaceAll('/v1', '');
    return 'Cannot reach local AI engine at $host. '
        'Is Ollama running? Try: ollama serve';
  }

  /// Extracts the first well-formed JSON object from [text].
  ///
  /// Tries three strategies in order:
  ///   1. Direct JSON parse (model returned pure JSON).
  ///   2. Extract from a ```json ... ``` or ``` ... ``` code fence.
  ///   3. Brace-depth scan — finds the first syntactically complete `{...}`
  ///      block, ignoring any surrounding prose or markdown.
  static Map<String, dynamic>? _parseJsonFromResponse(String text) {
    final trimmed = text.trim();

    // 1. Direct parse.
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}

    // 2. Code fence: ```json ... ``` or ``` ... ```
    final codeFence =
        RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(trimmed);
    if (codeFence != null) {
      try {
        final decoded = jsonDecode(codeFence.group(1)!.trim());
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }

    // 3. Brace-depth scan — O(n), string-aware so braces inside JSON
    //    strings (e.g. {"explanation":"literal } brace"}) don't prematurely
    //    close the candidate. Tracks escape sequences inside strings.
    int depth = 0;
    int start = -1;
    bool inString = false;
    bool escape = false;

    for (int i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];

      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == r'\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }

      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (ch == '}') {
        if (depth == 0) continue; // stray '}' in prose — ignore
        depth--;
        if (depth == 0 && start != -1) {
          try {
            final candidate = trimmed.substring(start, i + 1);
            final decoded = jsonDecode(candidate);
            if (decoded is Map<String, dynamic>) return decoded;
          } catch (_) {}
          start = -1;
        }
      }
    }

    return null;
  }

  Future<CommandIntent> parseIntent(String prompt, List<String> availableServers) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) throw const AiCommandServiceException('Prompt cannot be empty.');

    if (!config.isConfigured) {
      throw AiCommandServiceException('${config.provider.label} API key is not set.');
    }

    final systemInstruction =
        'You are a Linux sysadmin. Parse the user request into a structured intent. '
        'The available servers are: ${availableServers.join(", ")}. '
        'You MUST return strictly valid JSON matching this schema: '
        '{ "action": "<short description>", "target_server": "<server name from the available list, or null>", "command": "<bash command>", "explanation": "<short explanation>" }';

    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;

    try {
      String response;
      switch (config.provider) {
        case AiProvider.openAi:
          response = await _chatWithOpenAi(client, trimmedPrompt, [], systemInstruction: systemInstruction);
          break;
        case AiProvider.gemini:
          response = await _chatWithGemini(client, trimmedPrompt, [], systemInstruction: systemInstruction);
          break;
        case AiProvider.openRouter:
          response = await _chatWithOpenAi(client, trimmedPrompt, [], systemInstruction: systemInstruction);
          break;
        case AiProvider.local:
          response = await _chatWithOpenAi(client, trimmedPrompt, [], systemInstruction: systemInstruction);
          break;
      }

      final decoded = _parseJsonFromResponse(response);
      if (decoded == null) {
        throw const AiCommandServiceException(
          'AI response did not contain a valid JSON object. '
          'Try rephrasing your request.',
        );
      }

      return CommandIntent.fromJson(decoded);
    } on SocketException {
      if (config.provider == AiProvider.local) {
        throw AiCommandServiceException(_localUnavailableMessage());
      }
      throw AiCommandServiceException('Network error contacting ${config.provider.label}.');
    } on FormatException catch (e) {
      throw AiCommandServiceException('AI response was not valid JSON: $e');
    } catch (e) {
      if (e is AiCommandServiceException) rethrow;
      throw AiCommandServiceException('Intent parsing failed: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> generateChatResponse(String prompt, {List<Map<String, String>> history = const []}) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) throw const AiCommandServiceException('Prompt cannot be empty.');

    if (!config.isConfigured) {
      throw AiCommandServiceException('${config.provider.label} API key is not set.');
    }

    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;

    try {
      switch (config.provider) {
        case AiProvider.openAi:
          return await _chatWithOpenAi(client, trimmedPrompt, history);
        case AiProvider.gemini:
          return await _chatWithGemini(client, trimmedPrompt, history);
        case AiProvider.openRouter:
          return await _chatWithOpenAi(client, trimmedPrompt, history);
        case AiProvider.local:
          return await _chatWithOpenAi(client, trimmedPrompt, history);
      }
    } on TimeoutException {
      if (config.provider == AiProvider.local) {
        throw AiCommandServiceException('Local AI engine timed out. The model may still be loading — try again.');
      }
      throw AiCommandServiceException('${config.provider.label} timed out.');
    } on SocketException {
      if (config.provider == AiProvider.local) {
        throw AiCommandServiceException(_localUnavailableMessage());
      }
      throw AiCommandServiceException('Network error contacting ${config.provider.label}.');
    } finally {
      client.close(force: true);
    }
  }

  Future<CommandAnalysis> generateCommand(String prompt, {String? contextOutput}) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) throw const AiCommandServiceException('Prompt cannot be empty.');

    if (!config.isConfigured) {
      throw AiCommandServiceException('${config.provider.label} API key is not set.');
    }

    const systemInstruction =
        'You are a Linux sysadmin. Analyze the context and provide a safe command. '
        'You MUST return strictly valid JSON matching this schema: '
        '{ "command": "<the bash command>", "risk_level": "<low|moderate|high>", "explanation": "<short explanation>" }';

    String fullPrompt = trimmedPrompt;
    if (contextOutput != null && contextOutput.isNotEmpty) {
      fullPrompt = 'Context:\n$contextOutput\n\nTask: $trimmedPrompt';
    }

    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;

    try {
      String response;
      switch (config.provider) {
        case AiProvider.openAi:
          response = await _chatWithOpenAi(client, fullPrompt, [], systemInstruction: systemInstruction);
          break;
        case AiProvider.gemini:
          response = await _chatWithGemini(client, fullPrompt, [], systemInstruction: systemInstruction);
          break;
        case AiProvider.openRouter:
          response = await _chatWithOpenAi(client, fullPrompt, [], systemInstruction: systemInstruction);
          break;
        case AiProvider.local:
          response = await _chatWithOpenAi(client, fullPrompt, [], systemInstruction: systemInstruction);
          break;
      }

      final decoded = _parseJsonFromResponse(response);
      if (decoded == null) {
        throw const AiCommandServiceException(
          'AI response did not contain a valid JSON object. '
          'Try rephrasing your request.',
        );
      }

      var analysis = CommandAnalysis.fromJson(decoded);

      final fastRisk = CommandRiskAssessor.assessFast(analysis.command);
      if (fastRisk == CommandRiskLevel.critical) {
        analysis = CommandAnalysis(
          command: analysis.command,
          riskLevel: CommandRiskLevel.critical,
          explanation:
              'CRITICAL SAFETY WARNING: This command contains patterns that are highly dangerous. ${analysis.explanation}',
        );
      }

      return analysis;
    } on SocketException {
      if (config.provider == AiProvider.local) {
        throw AiCommandServiceException(_localUnavailableMessage());
      }
      throw AiCommandServiceException('Network error contacting ${config.provider.label}.');
    } on FormatException catch (e) {
      throw AiCommandServiceException('AI response was not valid JSON: $e');
    } catch (e) {
      if (e is AiCommandServiceException) rethrow;
      throw AiCommandServiceException('Command generation failed: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _chatWithOpenAi(
    HttpClient client,
    String prompt,
    List<Map<String, String>> history, {
    String? systemInstruction,
  }) async {
    final request = await client.postUrl(Uri.parse('${config.baseUrl}/chat/completions')).timeout(_connectionTimeout);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (config.provider != AiProvider.local) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
    }

    final messages = [
      {'role': 'system', 'content': systemInstruction ?? _chatInstruction},
      ...history,
      {'role': 'user', 'content': prompt},
    ];

    request.write(jsonEncode({
      'model': config.model,
      'temperature': 0.4,
      'messages': messages,
    }));

    final response = await request.close().timeout(_responseTimeout);
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(_extractErrorMessage(responseBody) ?? 'Status ${response.statusCode}');
    }

    return _extractOpenAiContent(responseBody) ?? '';
  }

  Future<String> _chatWithGemini(
    HttpClient client,
    String prompt,
    List<Map<String, String>> history, {
    String? systemInstruction,
  }) async {
    final request = await client.postUrl(Uri.parse('${config.baseUrl}/models/${config.model}:generateContent')).timeout(_connectionTimeout);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set('x-goog-api-key', config.apiKey);

    final contents = history.map((m) {
      return {
        'role': m['role'] == 'assistant' ? 'model' : 'user',
        'parts': [
          {'text': m['content']}
        ]
      };
    }).toList();

    contents.add({
      'role': 'user',
      'parts': [
        {'text': 'System Instruction: ${systemInstruction ?? _chatInstruction}\n\nUser: $prompt'}
      ]
    });

    request.write(jsonEncode({'contents': contents}));

    final response = await request.close().timeout(_responseTimeout);
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(_extractErrorMessage(responseBody) ?? 'Status ${response.statusCode}');
    }

    return _extractGeminiContent(responseBody) ?? '';
  }

  String? _extractOpenAiContent(String responseBody) {
    final decoded = jsonDecode(responseBody);
    return decoded['choices']?[0]?['message']?['content'];
  }

  String? _extractGeminiContent(String responseBody) {
    final decoded = jsonDecode(responseBody);
    return decoded['candidates']?[0]?['content']?['parts']?[0]?['text'];
  }

  String? _extractErrorMessage(String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      return decoded['error']?['message'];
    } catch (_) {
      return null;
    }
  }

  Future<List<AiCommandStep>> generateCommandPlan(String prompt) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) throw const AiCommandServiceException('Prompt cannot be empty.');

    final response = await generateChatResponse(
      'Based on the following request, provide a list of shell commands to execute. '
      'Format each command in a markdown bash block. '
      'Request: $trimmedPrompt',
    );

    final steps = <AiCommandStep>[];
    final regExp = RegExp(r'```(?:bash|sh)?\n([\s\S]*?)\n```');
    final matches = regExp.allMatches(response);

    for (final match in matches) {
      final command = match.group(1)?.trim();
      if (command != null && command.isNotEmpty) {
        steps.add(AiCommandStep(
          title: 'Execute Command',
          command: command,
          description: 'AI suggested command based on your request.',
        ));
      }
    }

    if (steps.isEmpty && response.isNotEmpty) {
      throw AiCommandServiceException(response);
    }

    return steps;
  }
}

class AiCommandServiceException implements Exception {
  const AiCommandServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AiCommandStep {
  const AiCommandStep({required this.title, required this.command, this.description});
  final String title;
  final String command;
  final String? description;
}
