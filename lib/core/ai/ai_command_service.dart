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
  });

  factory AiCommandService.forProvider({
    required AiProvider provider,
    required String apiKey,
  }) {
    return AiCommandService(
      config: AiApiConfig.forProvider(
        provider: provider,
        apiKey: apiKey,
      ),
    );
  }

  static const _systemInstruction =
      'Convert user request into safe Linux shell commands. '
      'Return ONLY a JSON array of commands. No explanations.';

  final AiApiConfig config;

  Future<List<String>> generateCommands(String prompt) async {
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
          return await _generateWithOpenAi(client, trimmedPrompt);
        case AiProvider.gemini:
          return await _generateWithGemini(client, trimmedPrompt);
      }
    } on TimeoutException {
      throw const AiCommandServiceException(
        'AI request timed out. Try again.',
      );
    } on SocketException {
      throw const AiCommandServiceException(
        'Network error while contacting the AI provider.',
      );
    } on FormatException {
      throw const AiCommandServiceException(
        'AI response was not valid JSON.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> _generateWithOpenAi(
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
      throw const AiCommandServiceException(
        'OpenAI returned an empty response.',
      );
    }

    final commands = _parseCommands(content);
    if (commands.isEmpty) {
      throw const AiCommandServiceException(
        'OpenAI returned no commands.',
      );
    }

    return commands;
  }

  Future<List<String>> _generateWithGemini(
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

    final commands = _parseCommands(content);
    if (commands.isEmpty) {
      throw const AiCommandServiceException(
        'Gemini returned no commands.',
      );
    }

    return commands;
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

  List<String> _parseCommands(String rawContent) {
    final trimmed = rawContent.trim();

    try {
      return _decodeCommandArray(trimmed);
    } on FormatException {
      final start = trimmed.indexOf('[');
      final end = trimmed.lastIndexOf(']');
      if (start == -1 || end == -1 || end <= start) {
        throw const AiCommandServiceException(
          'AI response could not be parsed into a command list.',
        );
      }

      final jsonSlice = trimmed.substring(start, end + 1);
      return _decodeCommandArray(jsonSlice);
    }
  }

  List<String> _decodeCommandArray(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! List) {
      throw const AiCommandServiceException(
        'AI response was not a JSON array.',
      );
    }

    final commands = decoded
        .whereType<String>()
        .map((command) => command.trim())
        .where((command) => command.isNotEmpty)
        .toList();

    if (commands.length != decoded.length) {
      throw const AiCommandServiceException(
        'AI returned non-string command entries.',
      );
    }

    return commands;
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
