import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/main.dart';
import 'package:hamma/core/storage/api_key_storage.dart';
import 'package:hamma/core/storage/app_lock_storage.dart';
import 'package:hamma/core/storage/app_prefs_storage.dart';
import 'package:hamma/core/ai/ai_provider.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AiServerApp(
      apiKeyStorage: ApiKeyStorage(),
      appLockStorage: AppLockStorage(),
      appPrefsStorage: AppPrefsStorage(),
      initialSettings: AiSettings(provider: AiProvider.openAi, openRouterModel: null),
      initialHasAppPin: false,
      initialIsOnboardingComplete: true,
    ));

    expect(find.byType(AiServerApp), findsOneWidget);
  });
}
