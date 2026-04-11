import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AiApiConfig {
  const AiApiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  const AiApiConfig.placeholder()
      : baseUrl = 'https://api.openai.com/v1',
        apiKey = 'YOUR_OPENAI_API_KEY',
        model = 'gpt-4.1-mini';

  final String baseUrl;
  final String apiKey;
  final String model;

  AiApiConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) {
    return AiApiConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  bool get isConfigured {
    return apiKey.isNotEmpty && apiKey != 'YOUR_OPENAI_API_KEY';
  }
}

class AiCommandService {
  const AiCommandService({
    this.config = const AiApiConfig.placeholder(),
  });

  final AiApiConfig config;

  AiCommandService withApiKey(String apiKey) {
    return AiCommandService(
      config: config.copyWith(apiKey: apiKey),
    );
  }

  Future<List<String>> generateCommands(String prompt) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) {
      throw const AiCommandServiceException('Prompt cannot be empty.');
    }

    if (!config.isConfigured) {
      throw const AiCommandServiceException(
        'AI API key is not configured. Update AiApiConfig before generating commands.',
      );
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client
          .postUrl(Uri.parse('${config.baseUrl}/chat/completions'))
          .timeout(const Duration(seconds: 15));

      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');

      request.write(
        jsonEncode({
          'model': config.model,
          'temperature': 0.2,
          'messages': [
            {
              'role': 'system',
              'content': 'Convert user request into safe Linux shell commands. '
                  'Return ONLY a JSON array of commands. No explanations.',
            },
            {
              'role': 'user',
              'content': trimmedPrompt,
            },
          ],
        }),
      );

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiCommandServiceException(
          _extractErrorMessage(responseBody) ??
              'AI request failed with status ${response.statusCode}.',
        );
      }

      final content = _extractAssistantContent(responseBody);
      if (content == null || content.trim().isEmpty) {
        throw const AiCommandServiceException(
          'AI returned an empty response.',
        );
      }

      final commands = _parseCommands(content);
      if (commands.isEmpty) {
        throw const AiCommandServiceException(
          'AI returned no commands.',
        );
      }

      return commands;
    } on TimeoutException {
      throw const AiCommandServiceException(
        'AI request timed out. Try again.',
      );
    } on SocketException {
      throw const AiCommandServiceException(
        'Network error while contacting the AI API.',
      );
    } on FormatException {
      throw const AiCommandServiceException(
        'AI response was not valid JSON.',
      );
    } finally {
      client.close(force: true);
    }
  }

  String? _extractAssistantContent(String responseBody) {
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
}

class AiCommandServiceException implements Exception {
  const AiCommandServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
