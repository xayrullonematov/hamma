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

  testWidgets(
    'searching inside the Support card hides non-matching Resources rows',
    (tester) async {
      await useDesktop(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // Jump straight to the Support category in the rail; this scrolls
      // the right pane to that section so its rows are laid out.
      await tester.tap(
          find.byKey(const ValueKey('settings_category_support')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_row_help_center')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings_row_extensions')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings_row_vault')),
          findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings_search_field')),
        'vault',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_row_vault')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings_row_help_center')),
          findsNothing);
      expect(find.byKey(const ValueKey('settings_row_extensions')),
          findsNothing);
      expect(find.text('RESOURCES'), findsOneWidget);
    },
  );

  testWidgets(
    'searching for a row-only keyword keeps the parent category '
    'visible and surfaces only the matching row',
    (tester) async {
      await useDesktop(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // "gpt" is a keyword on the OpenRouter Model row. The AI category
      // title does not contain it, so the registry-driven category
      // visibility is what keeps the AI card on screen.
      await tester.enterText(
        find.byKey(const ValueKey('settings_search_field')),
        'gpt',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_categories_rail')),
          findsOneWidget);
      expect(find.text('AI Configuration'), findsWidgets);
      expect(find.byKey(const ValueKey('settings_row_openai_key')),
          findsNothing);
    },
  );

  testWidgets(
    'searching for a row-only keyword inside a conditional group keeps '
    'the parent category visible',
    (tester) async {
      await useDesktop(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // "token" is only registered against backup → WebDAV Password.
      await tester.enterText(
        find.byKey(const ValueKey('settings_search_field')),
        'token',
      );
      await tester.pumpAndSettle();

      expect(find.text('Backup & Restore'), findsWidgets);
    },
  );

  testWidgets(
    'mobile: changing the AI provider via the pushed detail route '
    'surfaces the sticky save bar inside that route',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(app());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // Mobile: tap the AI category in the master list to push the detail.
      await tester.tap(
          find.byKey(const ValueKey('settings_mobile_category_ai')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
          findsNothing);

      await tester
          .tap(find.byKey(const ValueKey('settings_row_ai_provider')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('settings_edit_choice_Gemini')));
      await tester.pumpAndSettle();

      // Save bar must surface on the pushed detail route, not just on the
      // root settings screen behind it.
      expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
          findsOneWidget);
    },
  );
}
