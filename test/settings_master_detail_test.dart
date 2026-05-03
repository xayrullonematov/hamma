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

  // Counts category cards that are present in the tree AND not hidden by
  // a wrapping Visibility(visible: false). Cards stay mounted via
  // maintainState:true, so this is the only reliable way to assert which
  // sections the user can actually interact with after the master-detail
  // refactor. We filter to ONLY the wrap-level Visibility widgets that
  // _wrapCategorySection produces (Visibility -> Padding(bottom:20) -> card)
  // so nested Visibility widgets inside cards don't skew the count.
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

    // 6 categories defined; only the active one (ai) is visible.
    expect(visibleSectionCount(tester), 1);
    // The AI card's signature provider dropdown is reachable.
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsOneWidget);
  });

  testWidgets(
      'desktop master-detail: tapping Security in the rail switches the '
      'detail pane to the Security card only', (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // Sanity: AI dropdown initially visible.
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings_category_security')));
    await tester.pumpAndSettle();

    // Still exactly one section visible — Security.
    expect(visibleSectionCount(tester), 1);
    // Security has no provider dropdown; it has the Set/Remove App PIN button.
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsNothing);
    expect(
      find.textContaining('App PIN', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets(
      'desktop search overrides master-detail and shows all matching cards',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // Default (no search): exactly one card visible (master-detail).
    expect(visibleSectionCount(tester), 1);

    // Search for 'health' — only Health card matches.
    await tester.enterText(
      find.byKey(const ValueKey('settings_search_field')),
      'health',
    );
    await tester.pump();

    // Health is matched; AI is hidden because search overrode master-detail
    // and "health" doesn't appear in the AI category keywords.
    expect(visibleSectionCount(tester), 1);
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsNothing);

    // Clearing returns to master-detail (one card visible: the active AI).
    await tester.tap(find.byKey(const ValueKey('settings_search_clear')));
    await tester.pump();
    expect(visibleSectionCount(tester), 1);
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsOneWidget);
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
    // The matched AI card exposes the OpenAI Key field by label.
    expect(
      find.widgetWithText(TextFormField, 'OpenAI Key'),
      findsOneWidget,
    );
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

    // Backup card matched; AI dropdown is gone.
    expect(visibleSectionCount(tester), 1);
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsNothing);
    // Backup destination dropdown should be present.
    expect(
      find.text('Backup Destination'),
      findsOneWidget,
    );
  });

  testWidgets('mobile width omits the rail and shows the category list',
      (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('settings_categories_rail')),
        findsNothing);
    // Section list is NOT rendered — instead, the mobile category list is.
    expect(find.byKey(const ValueKey('settings_sections_list')),
        findsNothing);
    expect(find.byKey(const ValueKey('settings_mobile_category_list')),
        findsOneWidget);

    // All 6 category rows are tappable.
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

    // The pushed detail Scaffold is keyed by id.
    expect(
      find.byKey(const ValueKey('settings_category_detail_health')),
      findsOneWidget,
    );

    // Inside the detail route, the AppBar title shows the category name.
    expect(find.text('HEALTH MONITORING'), findsOneWidget);
    // The settings sections list is mounted with only the Health card visible.
    expect(visibleSectionCount(tester), 1);
    // Health card has its background-monitoring switch.
    expect(find.byType(SwitchListTile), findsOneWidget);
    // The mobile detail route hides the search field.
    expect(
      find.byKey(const ValueKey('settings_search_field')),
      findsNothing,
    );
  });

  testWidgets(
      'mobile: editing a field inside the pushed detail route surfaces the '
      'sticky save bar so changes can be saved without going back',
      (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('settings_mobile_category_ai')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings_category_detail_ai')),
        findsOneWidget);
    // Save bar is initially hidden inside the detail route.
    expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
        findsNothing);

    final apiKeyField =
        find.widgetWithText(TextFormField, 'OpenAI Key').first;
    await tester.enterText(apiKeyField, 'sk-from-mobile-detail');
    await tester.pump();

    // After dirtying inside the pushed route the save bar must appear there.
    expect(find.byKey(const ValueKey('settings_sticky_save_bar')),
        findsOneWidget);
    expect(find.text('SAVE'), findsOneWidget);
  });

  testWidgets('mobile: search inside the category list filters cards inline',
      (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // Search active flips mobile from category-list mode to inline filtered
    // section list.
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
