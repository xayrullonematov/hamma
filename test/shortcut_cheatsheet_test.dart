import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/keymap/keymap.dart';
import 'package:hamma/features/shortcuts/cheatsheet.dart';

void main() {
  Future<void> pumpCheatsheet(
    WidgetTester tester, {
    KeymapScope scope = KeymapScope.global,
    TargetPlatform platform = TargetPlatform.linux,
  }) async {
    // Generous viewport — the cheatsheet's max content height (480)
    // plus header and footer doesn't fit in the default 800x600.
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShortcutCheatsheet(scope: scope, platformOverride: platform),
        ),
      ),
    );
  }

  testWidgets('renders header and group labels', (tester) async {
    await pumpCheatsheet(tester);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    // Groups are uppercased on display.
    expect(find.text('NAVIGATION'), findsOneWidget);
    expect(find.text('HELP'), findsOneWidget);
  });

  testWidgets('renders one row per active entry', (tester) async {
    await pumpCheatsheet(tester, scope: KeymapScope.global);
    for (final entry in Keymap.forScope(KeymapScope.global)) {
      expect(
        find.text(entry.label),
        findsOneWidget,
        reason: 'label "${entry.label}" missing from cheatsheet',
      );
    }
  });

  testWidgets('chord glyphs reflect the override platform', (tester) async {
    await pumpCheatsheet(tester, platform: TargetPlatform.macOS);
    // palette.open displays as ⌘K on macOS.
    expect(find.text('⌘K'), findsOneWidget);
    expect(find.text('Ctrl+K'), findsNothing);
  });

  testWidgets('scoped cheatsheet hides unrelated entries', (tester) async {
    await pumpCheatsheet(tester, scope: KeymapScope.terminal);
    // Palette-only entries should NOT appear in a terminal-scoped sheet.
    expect(find.text('Invoke selected result'), findsNothing);
    // But global ones still do.
    expect(find.text('Open command palette'), findsOneWidget);
    // And terminal-scoped ones too.
    expect(find.text('Copy selection'), findsOneWidget);
  });
}
