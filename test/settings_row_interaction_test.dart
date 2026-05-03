import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/features/settings/settings_screen.dart';

/// Integration tests covering the Termius-style chevron/toggle row
/// behaviour added in Task #48: focused edit-page writeback, sticky
/// save-bar dirtying from grouped toggle rows, and row-granular search
/// hiding non-matching rows while keeping the group header visible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> useDesktop(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget app() => MaterialApp(
        home: SettingsScreen(
          initialProvider: AiProvider.openAi,
          initialApiKey: '',
          initialOpenRouterModel: null,
          initialLocalEndpoint: 'http://localhost:11434',
          initialLocalModel: 'gemma3',
          onSaveAiSettings: (_, __, ___, ____, _____) async {},
        ),
      );

  testWidgets(
    'tapping the Health background-monitoring toggle row dirties the '
    'sticky save bar',
    (tester) async {
      await useDesktop(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey('settings_category_health')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
          findsNothing);

      // Toggle the grouped row; this is a SettingsRow.toggle, not a
      // SwitchListTile. Tapping the row body must flip the switch and
      // dirty the screen.
      await tester
          .tap(find.byKey(const ValueKey('settings_row_health_enabled')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
          findsOneWidget);
    },
  );

  testWidgets(
    'opening the AI provider chevron row, picking Gemini and going back '
    'writes the new value into the row subtitle',
    (tester) async {
      await useDesktop(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // Initial subtitle: OpenAI.
      expect(find.text('OpenAI'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('settings_row_ai_provider')));
      await tester.pumpAndSettle();

      // Edit page is keyed and shows the radio choices.
      expect(
        find.byKey(const ValueKey('settings_edit_page_Default Provider')),
        findsOneWidget,
      );

      await tester
          .tap(find.byKey(const ValueKey('settings_edit_choice_Gemini')));
      await tester.pumpAndSettle();

      // Edit page popped, AI row subtitle now reads Gemini.
      expect(
        find.byKey(const ValueKey('settings_edit_page_Default Provider')),
        findsNothing,
      );
      expect(find.text('Gemini'), findsWidgets);
    },
  );

  testWidgets(
    'row-granular search hides non-matching rows inside a visible group '
    'while keeping the group header on screen',
    (tester) async {
      await useDesktop(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // Sanity: all three API key rows are mounted in the AI card.
      expect(find.byKey(const ValueKey('settings_row_openai_key')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings_row_gemini_key')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings_row_openrouter_key')),
          findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings_search_field')),
        'gemini',
      );
      await tester.pump();

      // The AI category card stays visible; only the matching row remains
      // and the API KEYS group header is still on screen.
      expect(find.byKey(const ValueKey('settings_row_gemini_key')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings_row_openai_key')),
          findsNothing);
      expect(find.byKey(const ValueKey('settings_row_openrouter_key')),
          findsNothing);
      expect(find.text('API KEYS'), findsOneWidget);
    },
  );
}
