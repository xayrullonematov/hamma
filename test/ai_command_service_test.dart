import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';

void main() {
  const service = AiCommandService(
    config: AiApiConfig(
      provider: AiProvider.openAi,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      model: 'test-model',
    ),
  );

  test('config reports configured when api key is present', () {
    const config = AiApiConfig(
      provider: AiProvider.gemini,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      model: 'test-model',
    );

    expect(config.isConfigured, isTrue);
  });

  test('service throws clear error for empty prompt', () async {
    await expectLater(
      service.generateCommands('   '),
      throwsA(
        isA<AiCommandServiceException>().having(
          (error) => error.message,
          'message',
          'Prompt cannot be empty.',
        ),
      ),
    );
  });
}
