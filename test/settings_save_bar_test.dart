import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/features/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> useDesktopSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget buildSubject({
    required int Function() saveCounter,
    Future<void> Function()? hold,
  }) {
    return MaterialApp(
      home: SettingsScreen(
        initialProvider: AiProvider.openAi,
        initialApiKey: '',
        initialOpenRouterModel: null,
        initialLocalEndpoint: 'http://localhost:11434',
        initialLocalModel: 'gemma3',
        onSaveAiSettings: (
          AiProvider provider,
          String apiKey,
          String? openRouterModel,
          String? localEndpoint,
          String? localModel,
        ) async {
          saveCounter();
          if (hold != null) await hold();
        },
      ),
    );
  }

  Future<void> editApiKeyViaRow(WidgetTester tester, String value) async {
    await tester.tap(find.byKey(const ValueKey('settings_row_openai_key')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings_edit_text_field')),
      value,
    );
    await tester.tap(find.byKey(const ValueKey('settings_edit_save')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'sticky save bar is hidden until a row is dirty, '
    'shown after a writeback and hidden again after save',
    (tester) async {
      var saves = 0;
      await useDesktopSurface(tester);
      await tester.pumpWidget(buildSubject(saveCounter: () => saves++));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      final saveBar = find.byKey(const ValueKey('settings_sticky_save_bar'));
      expect(saveBar, findsNothing);

      await editApiKeyViaRow(tester, 'sk-test-12345');

      expect(saveBar, findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);

      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();

      expect(saves, 1);
      expect(saveBar, findsNothing);
    },
  );

  testWidgets(
    'changing the AI provider via the chevron row marks settings dirty '
    'and persists the picked value via save',
    (tester) async {
      var saves = 0;
      AiProvider? lastProvider;
      await useDesktopSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialProvider: AiProvider.openAi,
            initialApiKey: '',
            initialOpenRouterModel: null,
            initialLocalEndpoint: 'http://localhost:11434',
            initialLocalModel: 'gemma3',
            onSaveAiSettings: (p, k, m, le, lm) async {
              saves++;
              lastProvider = p;
            },
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
          findsNothing);

      await tester.tap(find.byKey(const ValueKey('settings_row_ai_provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings_edit_choice_Gemini')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
          findsOneWidget);

      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();

      expect(saves, 1);
      expect(lastProvider, AiProvider.gemini);
    },
  );

  testWidgets(
    'rapid double-tap on SAVE only fires onSaveAiSettings once',
    (tester) async {
      var saves = 0;
      await useDesktopSurface(tester);
      await tester.pumpWidget(buildSubject(saveCounter: () => saves++));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      await editApiKeyViaRow(tester, 'sk-test-12345');

      final saveBtn = find.text('SAVE');
      await tester.tap(saveBtn, warnIfMissed: false);
      await tester.tap(saveBtn, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(saves, 1);
    },
  );
}
