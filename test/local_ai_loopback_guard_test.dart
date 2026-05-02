import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/ai/ollama_client.dart';

/// Zero-trust enforcement guard: the only sanctioned home for the
/// loopback rule is `OllamaClient.isLoopbackEndpoint`. The Settings
/// screen and the runtime client both gate on this same predicate, so
/// keeping its behaviour pinned here prevents drift.
void main() {
  group('OllamaClient.isLoopbackEndpoint', () {
    test('accepts the canonical loopback hosts', () {
      expect(OllamaClient.isLoopbackEndpoint('http://localhost'), isTrue);
      expect(
        OllamaClient.isLoopbackEndpoint('http://localhost:11434'),
        isTrue,
      );
      expect(
        OllamaClient.isLoopbackEndpoint('http://127.0.0.1:11434'),
        isTrue,
      );
      expect(
        OllamaClient.isLoopbackEndpoint('http://127.0.0.1:11434/'),
        isTrue,
      );
      // Anything in 127.0.0.0/8 is loopback per RFC 6890.
      expect(
        OllamaClient.isLoopbackEndpoint('http://127.5.6.7:1234'),
        isTrue,
      );
      // IPv6 loopback in bracket form.
      expect(OllamaClient.isLoopbackEndpoint('http://[::1]:1234'), isTrue);
      // Mixed case host should still be recognised.
      expect(
        OllamaClient.isLoopbackEndpoint('HTTP://LocalHost:11434'),
        isTrue,
      );
    });

    test('rejects LAN / public / malformed endpoints', () {
      expect(
        OllamaClient.isLoopbackEndpoint('http://192.168.1.10:11434'),
        isFalse,
      );
      expect(
        OllamaClient.isLoopbackEndpoint('http://10.0.0.5:11434'),
        isFalse,
      );
      expect(
        OllamaClient.isLoopbackEndpoint('https://api.openai.com'),
        isFalse,
      );
      // Hostname that *looks* like loopback but isn't.
      expect(
        OllamaClient.isLoopbackEndpoint('http://localhost.evil.com'),
        isFalse,
      );
      // Non-HTTP schemes are rejected outright.
      expect(
        OllamaClient.isLoopbackEndpoint('ssh://localhost:22'),
        isFalse,
      );
      expect(
        OllamaClient.isLoopbackEndpoint('file:///etc/passwd'),
        isFalse,
      );
      expect(OllamaClient.isLoopbackEndpoint(''), isFalse);
      expect(OllamaClient.isLoopbackEndpoint('not a url'), isFalse);
      expect(OllamaClient.isLoopbackEndpoint('http://'), isFalse);
    });

    test('OllamaClient constructor refuses non-loopback endpoints', () {
      expect(
        () => OllamaClient(endpoint: 'http://192.168.1.10:11434'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => OllamaClient(endpoint: 'https://api.openai.com'),
        throwsA(isA<ArgumentError>()),
      );
      // The well-formed loopback case must still construct.
      expect(
        () => OllamaClient(endpoint: 'http://127.0.0.1:11434'),
        returnsNormally,
      );
    });
  });

  // The OllamaClient guard is the model-manager seatbelt; the same rule must
  // also fire when a chat path constructs an `AiCommandService` for the local
  // provider. Otherwise a non-loopback endpoint persisted in storage (or
  // injected via any other call path) would silently exfiltrate prompts the
  // moment the user opens chat.
  group('AiCommandService.forProvider local-mode loopback guard', () {
    test('refuses non-loopback localEndpoint at construction time', () {
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
          localEndpoint: 'http://192.168.1.10:11434',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
          localEndpoint: 'https://api.openai.com',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
          localEndpoint: 'http://localhost.evil.com:11434',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts canonical loopback localEndpoint values', () {
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
          localEndpoint: 'http://127.0.0.1:11434',
        ),
        returnsNormally,
      );
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
          localEndpoint: 'http://localhost:11434',
        ),
        returnsNormally,
      );
      // Falling back to the hard-coded default endpoint must also pass.
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
        ),
        returnsNormally,
      );
    });

    test('non-local providers are unaffected by the loopback guard', () {
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.openAi,
          apiKey: 'sk-test',
        ),
        returnsNormally,
      );
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.gemini,
          apiKey: 'g-test',
        ),
        returnsNormally,
      );
      expect(
        () => AiCommandService.forProvider(
          provider: AiProvider.openRouter,
          apiKey: 'or-test',
        ),
        returnsNormally,
      );
    });
  });
}
