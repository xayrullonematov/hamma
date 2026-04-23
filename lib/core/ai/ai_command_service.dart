import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';

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
    }
  }

  final AiProvider provider;
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured => apiKey.trim().isNotEmpty;
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
  }) {
    return AiCommandService(
      config: AiApiConfig.forProvider(
        provider: provider,
        apiKey: apiKey,
        openRouterModel: openRouterModel,
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

  Future<String> generateChatResponse(String prompt, {List<Map<String, String>> history = const []}) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) throw const AiCommandServiceException('Prompt cannot be empty.');

    if (!config.isConfigured) {
      throw AiCommandServiceException('${config.provider.label} API key is not set.');
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      switch (config.provider) {
        case AiProvider.openAi:
          return await _chatWithOpenAi(client, trimmedPrompt, history);
        case AiProvider.gemini:
          return await _chatWithGemini(client, trimmedPrompt, history);
        case AiProvider.openRouter:
          return await _chatWithOpenAi(client, trimmedPrompt, history);
      }
    } on TimeoutException {
      throw AiCommandServiceException('${config.provider.label} timed out.');
    } on SocketException {
      throw AiCommandServiceException('Network error contacting ${config.provider.label}.');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _chatWithOpenAi(HttpClient client, String prompt, List<Map<String, String>> history) async {
    final request = await client.postUrl(Uri.parse('${config.baseUrl}/chat/completions')).timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');

    final messages = [
      {'role': 'system', 'content': _chatInstruction},
      ...history,
      {'role': 'user', 'content': prompt},
    ];

    request.write(jsonEncode({
      'model': config.model,
      'temperature': 0.4,
      'messages': messages,
    }));

    final response = await request.close().timeout(const Duration(seconds: 30));
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(_extractErrorMessage(responseBody) ?? 'Status ${response.statusCode}');
    }

    return _extractOpenAiContent(responseBody) ?? '';
  }

  Future<String> _chatWithGemini(HttpClient client, String prompt, List<Map<String, String>> history) async {
    final request = await client.postUrl(Uri.parse('${config.baseUrl}/models/${config.model}:generateContent')).timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set('x-goog-api-key', config.apiKey);

    final contents = history.map((m) {
      return {
        'role': m['role'] == 'assistant' ? 'model' : 'user',
        'parts': [{'text': m['content']}]
      };
    }).toList();

    contents.add({
      'role': 'user',
      'parts': [{'text': 'System Instruction: $_chatInstruction\n\nUser: $prompt'}]
    });

    request.write(jsonEncode({'contents': contents}));

    final response = await request.close().timeout(const Duration(seconds: 30));
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

    // Use the existing chat logic to get a structured response
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
      // Fallback: If no code blocks but text exists, it might be an explanation of why it can't do it
      throw AiCommandServiceException(response);
    }

    return steps;
  }

  Future<List<String>> generateCommands(String prompt) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) throw const AiCommandServiceException('Prompt cannot be empty.');
    return [];
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
