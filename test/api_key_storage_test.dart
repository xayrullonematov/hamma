import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/storage/api_key_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('persists OpenRouter model even when API key is blank', (
    tester,
  ) async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = ApiKeyStorage();

      await storage.saveSettings(
        provider: AiProvider.openRouter,
        apiKey: '',
        openRouterModel: 'meta-llama/llama-3-8b-instruct',
      );

      final settings = await storage.loadSettings();

      expect(settings.provider, AiProvider.openRouter);
      expect(settings.apiKey, '');
      expect(settings.openRouterModel, 'meta-llama/llama-3-8b-instruct');
    });

  testWidgets('clears saved OpenRouter model when empty model is saved', (
    tester,
  ) async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = ApiKeyStorage();

      await storage.saveSettings(
        provider: AiProvider.openRouter,
        apiKey: 'key-123',
        openRouterModel: 'anthropic/claude-3.5-sonnet',
      );

      await storage.saveSettings(
        provider: AiProvider.openRouter,
        apiKey: '',
        openRouterModel: '',
      );

      final settings = await storage.loadSettings();

      expect(settings.provider, AiProvider.openRouter);
      expect(settings.apiKey, '');
      expect(settings.openRouterModel, isNull);
    });
}
