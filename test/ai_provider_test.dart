import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_provider.dart';

void main() {
  group('AiProvider enum values', () {
    test('has exactly four providers', () {
      expect(AiProvider.values, hasLength(4));
    });

    test('contains openAi, gemini, openRouter, and local', () {
      expect(
        AiProvider.values,
        containsAll(<AiProvider>[
          AiProvider.openAi,
          AiProvider.gemini,
          AiProvider.openRouter,
          AiProvider.local,
        ]),
      );
    });
  });

  group('AiProviderPresentation.storageValue', () {
    test('openAi maps to "openai"', () {
      expect(AiProvider.openAi.storageValue, 'openai');
    });

    test('gemini maps to "gemini"', () {
      expect(AiProvider.gemini.storageValue, 'gemini');
    });

    test('openRouter maps to "openrouter"', () {
      expect(AiProvider.openRouter.storageValue, 'openrouter');
    });

    test('local maps to "local"', () {
      expect(AiProvider.local.storageValue, 'local');
    });
  });

  group('AiProviderPresentation.label', () {
    test('openAi label is "OpenAI"', () {
      expect(AiProvider.openAi.label, 'OpenAI');
    });

    test('gemini label is "Gemini"', () {
      expect(AiProvider.gemini.label, 'Gemini');
    });

    test('openRouter label is "OpenRouter"', () {
      expect(AiProvider.openRouter.label, 'OpenRouter');
    });

    test('local label is "Local AI"', () {
      expect(AiProvider.local.label, 'Local AI');
    });
  });

  group('AiProviderPresentation.helperText', () {
    test('openAi helper text mentions paid API key', () {
      expect(AiProvider.openAi.helperText.toLowerCase(), contains('paid'));
    });

    test('gemini helper text mentions quota', () {
      expect(AiProvider.gemini.helperText.toLowerCase(), contains('quota'));
    });

    test('openRouter helper text mentions openrouter.ai', () {
      expect(AiProvider.openRouter.helperText.toLowerCase(), contains('openrouter'));
    });

    test('local helper text mentions zero-trust / offline', () {
      final text = AiProvider.local.helperText.toLowerCase();
      expect(text, anyOf(contains('zero-trust'), contains('offline')));
    });
  });

  group('AiProviderPresentation.requiresApiKey', () {
    test('openAi, gemini, openRouter require an API key', () {
      expect(AiProvider.openAi.requiresApiKey, isTrue);
      expect(AiProvider.gemini.requiresApiKey, isTrue);
      expect(AiProvider.openRouter.requiresApiKey, isTrue);
    });

    test('local does NOT require an API key', () {
      expect(AiProvider.local.requiresApiKey, isFalse);
    });
  });

  group('AiProviderPresentation.isLocal', () {
    test('only local returns true', () {
      expect(AiProvider.local.isLocal, isTrue);
      expect(AiProvider.openAi.isLocal, isFalse);
      expect(AiProvider.gemini.isLocal, isFalse);
      expect(AiProvider.openRouter.isLocal, isFalse);
    });
  });

  group('aiProviderFromStorage', () {
    test('parses "openai" → AiProvider.openAi', () {
      expect(aiProviderFromStorage('openai'), AiProvider.openAi);
    });

    test('parses "gemini" → AiProvider.gemini', () {
      expect(aiProviderFromStorage('gemini'), AiProvider.gemini);
    });

    test('parses "openrouter" → AiProvider.openRouter', () {
      expect(aiProviderFromStorage('openrouter'), AiProvider.openRouter);
    });

    test('parses "local" → AiProvider.local', () {
      expect(aiProviderFromStorage('local'), AiProvider.local);
    });

    test('defaults to openAi for null input', () {
      expect(aiProviderFromStorage(null), AiProvider.openAi);
    });

    test('defaults to openAi for empty string', () {
      expect(aiProviderFromStorage(''), AiProvider.openAi);
    });

    test('defaults to openAi for unknown value', () {
      expect(aiProviderFromStorage('anthropic'), AiProvider.openAi);
    });

    test('is case-insensitive for known values', () {
      expect(aiProviderFromStorage('GEMINI'), AiProvider.gemini);
      expect(aiProviderFromStorage('OpenAI'), AiProvider.openAi);
      expect(aiProviderFromStorage('OPENROUTER'), AiProvider.openRouter);
      expect(aiProviderFromStorage('LOCAL'), AiProvider.local);
    });

    test('trims whitespace before matching', () {
      expect(aiProviderFromStorage('  gemini  '), AiProvider.gemini);
      expect(aiProviderFromStorage('  local  '), AiProvider.local);
    });
  });
}
