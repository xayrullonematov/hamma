import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';

void main() {
  group('AiApiConfig.isConfigured', () {
    test('returns true when apiKey is non-empty', () {
      const config = AiApiConfig(
        provider: AiProvider.openAi,
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test-key',
        model: 'gpt-4o-mini',
      );
      expect(config.isConfigured, isTrue);
    });

    test('returns false when apiKey is empty', () {
      const config = AiApiConfig(
        provider: AiProvider.openAi,
        baseUrl: 'https://api.openai.com/v1',
        apiKey: '',
        model: 'gpt-4o-mini',
      );
      expect(config.isConfigured, isFalse);
    });

    test('returns false when apiKey is only whitespace', () {
      const config = AiApiConfig(
        provider: AiProvider.gemini,
        baseUrl: 'https://example.com',
        apiKey: '   ',
        model: 'gemini-1.5-flash',
      );
      expect(config.isConfigured, isFalse);
    });
  });

  group('AiApiConfig.forProvider — OpenAI', () {
    test('sets correct baseUrl and model', () {
      final config = AiApiConfig.forProvider(
        provider: AiProvider.openAi,
        apiKey: 'sk-key',
      );
      expect(config.baseUrl, 'https://api.openai.com/v1');
      expect(config.model, 'gpt-4o-mini');
      expect(config.provider, AiProvider.openAi);
      expect(config.apiKey, 'sk-key');
    });
  });

  group('AiApiConfig.forProvider — Gemini', () {
    test('sets correct baseUrl and model', () {
      final config = AiApiConfig.forProvider(
        provider: AiProvider.gemini,
        apiKey: 'gm-key',
      );
      expect(config.baseUrl, contains('googleapis.com'));
      expect(config.model, 'gemini-1.5-flash');
      expect(config.provider, AiProvider.gemini);
    });
  });

  group('AiApiConfig.forProvider — OpenRouter', () {
    test('uses provided openRouterModel when non-empty', () {
      final config = AiApiConfig.forProvider(
        provider: AiProvider.openRouter,
        apiKey: 'or-key',
        openRouterModel: 'anthropic/claude-3.5-sonnet',
      );
      expect(config.model, 'anthropic/claude-3.5-sonnet');
      expect(config.baseUrl, contains('openrouter.ai'));
    });

    test('falls back to default model when openRouterModel is null', () {
      final config = AiApiConfig.forProvider(
        provider: AiProvider.openRouter,
        apiKey: 'or-key',
      );
      expect(config.model, 'meta-llama/llama-3-8b-instruct');
    });

    test('falls back to default model when openRouterModel is blank', () {
      final config = AiApiConfig.forProvider(
        provider: AiProvider.openRouter,
        apiKey: 'or-key',
        openRouterModel: '   ',
      );
      expect(config.model, 'meta-llama/llama-3-8b-instruct');
    });
  });

  group('CommandIntent.fromJson', () {
    test('parses all fields correctly', () {
      final json = {
        'action': 'Restart Service',
        'target_server': 'prod-1',
        'command': 'systemctl restart nginx',
        'explanation': 'Restarts the nginx service',
      };
      final intent = CommandIntent.fromJson(json);

      expect(intent.action, 'Restart Service');
      expect(intent.targetServer, 'prod-1');
      expect(intent.command, 'systemctl restart nginx');
      expect(intent.explanation, 'Restarts the nginx service');
    });

    test('defaults action to "Execute Command" when absent', () {
      final intent = CommandIntent.fromJson({'command': 'ls', 'explanation': 'List'});
      expect(intent.action, 'Execute Command');
    });

    test('targetServer is null when absent', () {
      final intent = CommandIntent.fromJson({'command': 'ls', 'explanation': 'List'});
      expect(intent.targetServer, isNull);
    });

    test('defaults command and explanation to empty string when absent', () {
      final intent = CommandIntent.fromJson({});
      expect(intent.command, '');
      expect(intent.explanation, '');
    });
  });
}
