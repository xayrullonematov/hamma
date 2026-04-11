import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';

void main() {
  const service = AiCommandService(
    config: AiApiConfig(
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      model: 'test-model',
    ),
  );

  test('placeholder config reports not configured', () {
    const config = AiApiConfig.placeholder();

    expect(config.isConfigured, isFalse);
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
