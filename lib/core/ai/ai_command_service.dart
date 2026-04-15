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
          // Beta: single cheap model — upgrade to gpt-4o when scaling
          model: 'gpt-4.1-mini',
        );
      case AiProvider.gemini:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKey: apiKey,
          // Beta: single cheap model — free tier has quota limits
          model: 'gemini-2.5-flash',
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

  static const _systemInstruction =
      'Convert user request into a safe ordered Linux shell plan. '
      'Return ONLY a JSON array. '
      'Each item must be either a string command or an object with '
      '"title", "command", and optional "description". '
      'Use one shell command per step. '
      'Do not include markdown, code fences, or explanations outside JSON.';
  static const _chatInstruction =
      'You are a concise Linux and server operations assistant. '
      'Explain errors, logs, Linux concepts, and debugging strategies clearly. '
      'Reply in plain language only. '
      'Do not return JSON, shell commands, command lists, or step plans.';

  final AiApiConfig config;
  final String? openRouterModel;

  Future<List<AiCommandStep>> generateCommandPlan(String prompt) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) {
      throw const AiCommandServiceException('Prompt cannot be empty.');
    }

    if (!config.isConfigured) {
      throw AiCommandServiceException(
        '${config.provider.label} API key is not set. Update it in Settings before generating commands.',
      );
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      switch (config.provider) {
        case AiProvider.openAi:
          return await _generatePlanWithOpenAi(client, trimmedPrompt);
        case AiProvider.gemini:
          return await _generatePlanWithGemini(client, trimmedPrompt);
        case AiProvider.openRouter:
          return await _generatePlanWithOpenAi(client, trimmedPrompt);
      }
    } on TimeoutException {
      throw AiCommandServiceException(
        '${config.provider.label} request timed out. Try again.',
      );
    } on SocketException {
      throw AiCommandServiceException(
        'Network error while contacting ${config.provider.label}.',
      );
    } on FormatException {
      throw const AiCommandServiceException(
        'AI response was not valid JSON.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> generateCommands(String prompt) async {
    final plan = await generateCommandPlan(prompt);
    return plan.map((step) => step.command).toList();
  }

  Future<String> generateChatResponse(String prompt) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) {
      throw const AiCommandServiceException('Prompt cannot be empty.');
    }

    if (!config.isConfigured) {
      throw AiCommandServiceException(
        '${config.provider.label} API key is not set. Update it in Settings before using chat.',
      );
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      switch (config.provider) {
        case AiProvider.openAi:
          return await _chatWithOpenAi(client, trimmedPrompt);
        case AiProvider.gemini:
          return await _chatWithGemini(client, trimmedPrompt);
        case AiProvider.openRouter:
          return await _chatWithOpenAi(client, trimmedPrompt);
      }
    } on TimeoutException {
      throw AiCommandServiceException(
        '${config.provider.label} request timed out. Try again.',
      );
    } on SocketException {
      throw AiCommandServiceException(
        'Network error while contacting ${config.provider.label}.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<AiCommandStep>> _generatePlanWithOpenAi(
    HttpClient client,
    String prompt,
  ) async {
    final request = await client
        .postUrl(Uri.parse('${config.baseUrl}/chat/completions'))
        .timeout(const Duration(seconds: 15));

    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${config.apiKey}',
    );

    request.write(
      jsonEncode({
        'model': config.model,
        'temperature': 0.2,
        'messages': [
          {
            'role': 'system',
            'content': _systemInstruction,
          },
          {
            'role': 'user',
            'content': prompt,
          },
        ],
      }),
    );

    final response = await request.close().timeout(const Duration(seconds: 30));
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(
        _extractErrorMessage(responseBody) ??
            _providerErrorMessage(
              provider: config.provider,
              statusCode: response.statusCode,
            ),
      );
    }

    final content = _extractOpenAiContent(responseBody);
    if (content == null || content.trim().isEmpty) {
      throw AiCommandServiceException(
        '${config.provider.label} returned an empty response.',
      );
    }

    final plan = _parseCommandPlan(content);
    if (plan.isEmpty) {
      throw AiCommandServiceException(
        '${config.provider.label} returned no commands.',
      );
    }

    return plan;
  }

  Future<List<AiCommandStep>> _generatePlanWithGemini(
    HttpClient client,
    String prompt,
  ) async {
    final request = await client
        .postUrl(Uri.parse('${config.baseUrl}/models/${config.model}:generateContent'))
        .timeout(const Duration(seconds: 15));

    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set('x-goog-api-key', config.apiKey);

    request.write(
      jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text': '$_systemInstruction\n\nUser request: $prompt',
              },
            ],
          },
        ],
      }),
    );

    final response = await request.close().timeout(const Duration(seconds: 30));
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(
        _extractErrorMessage(responseBody) ??
            _providerErrorMessage(
              provider: config.provider,
              statusCode: response.statusCode,
            ),
      );
    }

    final content = _extractGeminiContent(responseBody);
    if (content == null || content.trim().isEmpty) {
      throw const AiCommandServiceException(
        'Gemini returned an empty response.',
      );
    }

    final plan = _parseCommandPlan(content);
    if (plan.isEmpty) {
      throw const AiCommandServiceException(
        'Gemini returned no commands.',
      );
    }

    return plan;
  }

  Future<String> _chatWithOpenAi(
    HttpClient client,
    String prompt,
  ) async {
    final request = await client
        .postUrl(Uri.parse('${config.baseUrl}/chat/completions'))
        .timeout(const Duration(seconds: 15));

    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${config.apiKey}',
    );

    request.write(
      jsonEncode({
        'model': config.model,
        'temperature': 0.4,
        'messages': [
          {
            'role': 'system',
            'content': _chatInstruction,
          },
          {
            'role': 'user',
            'content': prompt,
          },
        ],
      }),
    );

    final response = await request.close().timeout(const Duration(seconds: 30));
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(
        _extractErrorMessage(responseBody) ??
            _providerErrorMessage(
              provider: config.provider,
              statusCode: response.statusCode,
            ),
      );
    }

    final content = _extractOpenAiContent(responseBody);
    if (content == null || content.trim().isEmpty) {
      throw AiCommandServiceException(
        '${config.provider.label} returned an empty response.',
      );
    }

    return content.trim();
  }

  Future<String> _chatWithGemini(
    HttpClient client,
    String prompt,
  ) async {
    final request = await client
        .postUrl(
          Uri.parse('${config.baseUrl}/models/${config.model}:generateContent'),
        )
        .timeout(const Duration(seconds: 15));

    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set('x-goog-api-key', config.apiKey);

    request.write(
      jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text': '$_chatInstruction\n\nUser request: $prompt',
              },
            ],
          },
        ],
      }),
    );

    final response = await request.close().timeout(const Duration(seconds: 30));
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiCommandServiceException(
        _extractErrorMessage(responseBody) ??
            _providerErrorMessage(
              provider: config.provider,
              statusCode: response.statusCode,
            ),
      );
    }

    final content = _extractGeminiContent(responseBody);
    if (content == null || content.trim().isEmpty) {
      throw const AiCommandServiceException(
        'Gemini returned an empty response.',
      );
    }

    return content.trim();
  }

  String? _extractOpenAiContent(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map<String, dynamic>) {
      return null;
    }

    final message = firstChoice['message'];
    if (message is! Map<String, dynamic>) {
      return null;
    }

    final content = message['content'];
    if (content is String) {
      return content;
    }

    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map<String, dynamic> && part['type'] == 'text') {
          final text = part['text'];
          if (text is String) {
            buffer.write(text);
          }
        }
      }

      final combined = buffer.toString().trim();
      return combined.isEmpty ? null : combined;
    }

    return null;
  }

  String? _extractGeminiContent(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      return null;
    }

    final firstCandidate = candidates.first;
    if (firstCandidate is! Map<String, dynamic>) {
      return null;
    }

    final content = firstCandidate['content'];
    if (content is! Map<String, dynamic>) {
      return null;
    }

    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) {
      return null;
    }

    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is Map<String, dynamic>) {
        final text = part['text'];
        if (text is String) {
          buffer.write(text);
        }
      }
    }

    final combined = buffer.toString().trim();
    return combined.isEmpty ? null : combined;
  }

  List<AiCommandStep> _parseCommandPlan(String rawContent) {
    final trimmed = rawContent.trim();

    try {
      return _decodeCommandPlanArray(trimmed);
    } on FormatException {
      final start = trimmed.indexOf('[');
      final end = trimmed.lastIndexOf(']');
      if (start == -1 || end == -1 || end <= start) {
        throw const AiCommandServiceException(
          'AI response could not be parsed into a command list.',
        );
      }

      final jsonSlice = trimmed.substring(start, end + 1);
      return _decodeCommandPlanArray(jsonSlice);
    }
  }

  List<AiCommandStep> _decodeCommandPlanArray(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! List) {
      throw const AiCommandServiceException(
        'AI response was not a JSON array.',
      );
    }

    final steps = <AiCommandStep>[];
    for (var index = 0; index < decoded.length; index++) {
      final item = decoded[index];

      if (item is String) {
        final command = item.trim();
        if (command.isEmpty) {
          throw const AiCommandServiceException(
            'AI returned an empty command entry.',
          );
        }
        steps.add(
          AiCommandStep(
            title: 'Step ${index + 1}',
            command: command,
          ),
        );
        continue;
      }

      if (item is Map<String, dynamic>) {
        final command = (item['command'] ?? '').toString().trim();
        if (command.isEmpty) {
          throw const AiCommandServiceException(
            'AI returned a plan step without a command.',
          );
        }

        final title = (item['title'] ?? '').toString().trim();
        final description = (item['description'] ?? '').toString().trim();

        steps.add(
          AiCommandStep(
            title: title.isEmpty ? 'Step ${index + 1}' : title,
            command: command,
            description: description.isEmpty ? null : description,
          ),
        );
        continue;
      }

      throw const AiCommandServiceException(
        'AI returned an unsupported plan step entry.',
      );
    }

    return steps;
  }

  String? _extractErrorMessage(String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } on FormatException {
      return null;
    }

    return null;
  }

  String _providerErrorMessage({
    required AiProvider provider,
    required int statusCode,
  }) {
    // Fix 1: Gemini returns 403 for both invalid key AND quota exceeded.
    // OpenAI uses 401 for invalid key and 429 for quota — keep separate.
    if (provider == AiProvider.gemini) {
      if (statusCode == 401 || statusCode == 403) {
        return 'Gemini rejected the request. Check your API key or free-tier quota.';
      }
      if (statusCode == 429) {
        return 'Gemini free-tier limit reached. Try again later or switch to OpenAI in Settings.';
      }
    } else if (provider == AiProvider.openRouter) {
      if (statusCode == 401 || statusCode == 403) {
        return 'OpenRouter rejected the API key. Check the key and try again.';
      }
      if (statusCode == 429) {
        return 'OpenRouter rate limit reached. Try again later or switch models in Settings.';
      }
    } else {
      if (statusCode == 401 || statusCode == 403) {
        return '${provider.label} rejected the API key. Check the key and try again.';
      }
      if (statusCode == 429) {
        return '${provider.label} quota limit reached. Check your plan or try again later.';
      }
    }

    return '${provider.label} request failed with status $statusCode.';
  }
}

class AiCommandServiceException implements Exception {
  const AiCommandServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AiCommandStep {
  const AiCommandStep({
    required this.title,
    required this.command,
    this.description,
  });

  final String title;
  final String command;
  final String? description;
}
