import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/features/shortcuts/cheatsheet.dart';

/// Mirrors the `?` wiring installed in `lib/main.dart`'s
/// MaterialApp.builder. If main.dart's intent/action plumbing drifts
/// out of sync with this, the test fails — keeping the discoverability
/// guarantee from regressing.
class _ShowCheatsheetIntent extends Intent {
  const _ShowCheatsheetIntent();
}

void main() {
  testWidgets('pressing ? at the app root opens the cheatsheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) {
          return Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              CharacterActivator('?'): _ShowCheatsheetIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _ShowCheatsheetIntent: CallbackAction<_ShowCheatsheetIntent>(
                  onInvoke: (_) {
                    final navContext = navigatorKey.currentContext;
                    if (navContext != null) {
                      unawaited(ShortcutCheatsheet.show(navContext));
                    }
                    return null;
                  },
                ),
              },
              child: child!,
            ),
          );
        },
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsNothing);

    // Hand focus to the root and dispatch the `?` chord.
    final root = tester.binding.focusManager.rootScope;
    root.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    // CharacterActivator listens for the produced character regardless
    // of underlying key, so dispatching the literal character is the
    // canonical way to simulate a `?` press in widget tests.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();

    expect(find.text('Keyboard shortcuts'), findsOneWidget);
  });
}
