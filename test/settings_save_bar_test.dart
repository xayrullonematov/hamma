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

  // The master-detail refactor only renders the active category's card on
  // desktop, and a tappable category list on mobile. To keep the AI section
  // (which owns the OpenAI Key field) reachable to these tests, force a
  // desktop-class surface so the AI card is the master-detail default.
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

  testWidgets(
    'sticky save bar is hidden until a field is dirty, '
    'shown after a change, and hidden again after save',
    (tester) async {
      var saves = 0;
      await useDesktopSurface(tester);
      await tester.pumpWidget(buildSubject(saveCounter: () => saves++));
      // Allow async loads to settle so _loadingFromStorage flips to false.
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      final saveBar = find.byKey(const ValueKey('settings_sticky_save_bar'));
      expect(saveBar, findsNothing);

      // Type into the OpenAI API key field (by its label).
      final apiKeyField =
          find.widgetWithText(TextFormField, 'OpenAI Key').first;
      await tester.enterText(apiKeyField, 'sk-test-12345');
      await tester.pump();

      expect(saveBar, findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);

      // Tap SAVE.
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();

      expect(saves, 1);
      expect(saveBar, findsNothing);
    },
  );

  testWidgets(
    'changing the AI provider alone marks settings dirty and persists via save',
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

      // Open provider dropdown and pick Gemini.
      await tester.tap(find.byType(DropdownButtonFormField<AiProvider>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gemini').last);
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

      final apiKeyField =
          find.widgetWithText(TextFormField, 'OpenAI Key').first;
      await tester.enterText(apiKeyField, 'sk-test-12345');
      await tester.pump();

      final saveBtn = find.text('SAVE');
      await tester.tap(saveBtn, warnIfMissed: false);
      await tester.tap(saveBtn, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(saves, 1);
    },
  );
}
