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

  testWidgets('desktop renders the categories rail', (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('settings_categories_rail')),
        findsOneWidget);
  });

  testWidgets('mobile width omits the categories rail', (tester) async {
    await setSurface(tester, const Size(420, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('settings_categories_rail')),
        findsNothing);
    // Search field is still present on every form factor.
    expect(find.byKey(const ValueKey('settings_search_field')),
        findsOneWidget);
  });

  testWidgets('search hides non-matching cards and clear restores them',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // Sanity: AI Configuration is one of the section titles.
    expect(find.text('AI Configuration'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('settings_search_field')),
      'health',
    );
    await tester.pump();

    // After filtering, at least one section is hidden via Visibility.
    final hidden = tester
        .widgetList<Visibility>(find.byType(Visibility))
        .where((v) => !v.visible)
        .length;
    expect(hidden, greaterThan(0));

    // Clear restores all sections to visible.
    await tester.tap(find.byKey(const ValueKey('settings_search_clear')));
    await tester.pump();
    final stillHidden = tester
        .widgetList<Visibility>(find.byType(Visibility))
        .where((v) => !v.visible)
        .length;
    expect(stillHidden, 0);
  });

  testWidgets('rail tap on Security routes through ensureVisible',
      (tester) async {
    await setSurface(tester, const Size(1400, 900));
    await tester.pumpWidget(build());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.tap(
      find.byKey(const ValueKey('settings_category_security')),
    );
    await tester.pumpAndSettle();

    // Rail still mounted, no exception thrown.
    expect(find.byKey(const ValueKey('settings_categories_rail')),
        findsOneWidget);
  });
}
