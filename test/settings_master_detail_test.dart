import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/features/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> setSurface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget build() {
    return MaterialApp(
      home: SettingsScreen(
        initialProvider: AiProvider.openAi,
        initialApiKey: '',
        initialOpenRouterModel: null,
        initialLocalEndpoint: 'http://localhost:11434',
        initialLocalModel: 'gemma3',
        onSaveAiSettings: (_, __, ___, ____, _____) async {},
      ),
    );
  }

  // Counts wrap-level Visibility widgets produced by _wrapCategorySection
  // (Visibility -> Padding(bottom:20) -> card). Other Visibility widgets
  // nested inside cards or rows are excluded.
  int visibleSectionCount(WidgetTester tester) {
    final list = find.byKey(const ValueKey('settings_sections_list'));
    if (list.evaluate().isEmpty) return 0;
    final all = tester.widgetList<Visibility>(
      find.descendant(of: list, matching: find.byType(Visibility)),
    );
    return all.where((v) {
      if (!v.visible) return false;
      final child = v.child;
      if (child is! Padding) return false;
      final pad = child.padding;
      return pad is EdgeInsets &&
          pad.bottom == 20 &&
          pad.top == 0 &&
          pad.left == 0 &&
          pad.right == 0;
    }).length;
  }

  testWidgets('desktop renders the categories rail', (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('settings_categories_rail')),
        findsOneWidget);
  });

  testWidgets(
      'desktop master-detail: default selection shows ONLY the AI section card',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(visibleSectionCount(tester), 1);
    // The AI card's Default Provider chevron row is reachable.
    expect(find.byKey(const ValueKey('settings_row_ai_provider')),
        findsOneWidget);
  });

  testWidgets(
      'desktop master-detail: tapping Security in the rail switches the '
      'detail pane to the Security card only', (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('settings_row_ai_provider')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings_category_security')));
    await tester.pumpAndSettle();

    expect(visibleSectionCount(tester), 1);
    expect(find.byKey(const ValueKey('settings_row_ai_provider')),
        findsNothing);
    expect(find.byKey(const ValueKey('settings_row_app_pin')), findsOneWidget);
  });

  testWidgets(
      'desktop search overrides master-detail and shows all matching cards',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(visibleSectionCount(tester), 1);

    await tester.enterText(
      find.byKey(const ValueKey('settings_search_field')),
      'health',
    );
    await tester.pump();

    expect(visibleSectionCount(tester), 1);
    expect(find.byKey(const ValueKey('settings_row_ai_provider')),
        findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings_search_clear')));
    await tester.pump();
    expect(visibleSectionCount(tester), 1);
    expect(find.byKey(const ValueKey('settings_row_ai_provider')),
        findsOneWidget);
  });

  testWidgets(
      'field-label search: typing "OpenAI Key" surfaces the AI category card',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.enterText(
      find.byKey(const ValueKey('settings_search_field')),
      'openai key',
    );
    await tester.pump();

    expect(visibleSectionCount(tester), 1);
    expect(find.byKey(const ValueKey('settings_row_openai_key')),
        findsOneWidget);
  });

  testWidgets(
      'field-label search: typing "WebDAV URL" surfaces the Backup category',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.enterText(
      find.byKey(const ValueKey('settings_search_field')),
      'webdav url',
    );
    await tester.pump();

    expect(visibleSectionCount(tester), 1);
    expect(find.byKey(const ValueKey('settings_row_ai_provider')),
        findsNothing);
    expect(find.byKey(const ValueKey('settings_row_backup_destination')),
        findsOneWidget);
  });

  testWidgets('mobile width omits the rail and shows the category list',
      (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('settings_categories_rail')),
        findsNothing);
    expect(find.byKey(const ValueKey('settings_sections_list')), findsNothing);
    expect(find.byKey(const ValueKey('settings_mobile_category_list')),
        findsOneWidget);

    for (final id in const [
      'ai',
      'triage',
      'health',
      'security',
      'backup',
      'support',
    ]) {
      expect(
        find.byKey(ValueKey('settings_mobile_category_$id')),
        findsOneWidget,
        reason: 'category $id should be in mobile list',
      );
    }
  });

  testWidgets(
      'mobile: tapping a category row pushes a detail route showing only '
      'that category', (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.tap(
      find.byKey(const ValueKey('settings_mobile_category_health')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings_category_detail_health')),
      findsOneWidget,
    );

    expect(find.text('HEALTH MONITORING'), findsOneWidget);
    expect(visibleSectionCount(tester), 1);
    // Health card's background-monitoring toggle row is keyed.
    expect(find.byKey(const ValueKey('settings_row_health_enabled')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings_search_field')),
      findsNothing,
    );
  });

  testWidgets(
      'mobile: editing a row inside the pushed detail route surfaces the '
      'sticky save bar so changes can be saved without going back',
      (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('settings_mobile_category_ai')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings_category_detail_ai')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
        findsNothing);

    // Tap the OpenAI Key row → edit page → enter value → SAVE.
    await tester.tap(find.byKey(const ValueKey('settings_row_openai_key')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings_edit_text_field')),
        findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('settings_edit_text_field')),
      'sk-from-mobile-detail',
    );
    await tester.tap(find.byKey(const ValueKey('settings_edit_save')));
    await tester.pumpAndSettle();

    // Back on the category detail, the save bar must appear.
    expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
        findsOneWidget);
    expect(find.text('SAVE'), findsOneWidget);
  });

  testWidgets('mobile: search inside the category list filters cards inline',
      (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.enterText(
      find.byKey(const ValueKey('settings_search_field')),
      'security',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('settings_mobile_category_list')),
        findsNothing);
    expect(find.byKey(const ValueKey('settings_sections_list')),
        findsOneWidget);
    expect(visibleSectionCount(tester), 1);
  });
}
