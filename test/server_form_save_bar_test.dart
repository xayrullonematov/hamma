import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/features/servers/server_form_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget wrap(Widget child) => MaterialApp(home: child);

  testWidgets(
    'sticky save bar is hidden until a field is dirty, '
    'and reappears for an edit of an existing server',
    (tester) async {
      await tester.pumpWidget(wrap(const ServerFormScreen()));
      await tester.pump();

      const barKey = ValueKey('server_form_sticky_save_bar');
      expect(find.byKey(barKey), findsNothing);

      // Type into the name field — dirties the form.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name').first,
        'Production DB',
      );
      await tester.pump();

      expect(find.byKey(barKey), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.text('SAVE'), findsOneWidget);

      // Revert the change → bar disappears.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name').first,
        '',
      );
      await tester.pump();
      expect(find.byKey(barKey), findsNothing);
    },
  );

  testWidgets(
    'editing existing server shows SAVE CHANGES label after a change',
    (tester) async {
      final server = ServerProfile(
        id: 'srv-1',
        name: 'Web 01',
        host: '10.0.0.1',
        port: 22,
        username: 'root',
        password: 'pw',
      );
      await tester.pumpWidget(
        wrap(ServerFormScreen(initialServer: server)),
      );
      await tester.pump();

      const barKey = ValueKey('server_form_sticky_save_bar');
      expect(find.byKey(barKey), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name').first,
        'Web 01 (renamed)',
      );
      await tester.pump();

      expect(find.byKey(barKey), findsOneWidget);
      expect(find.text('SAVE CHANGES'), findsOneWidget);
    },
  );

  testWidgets(
    'rapid double-tap on SAVE only pops the route once (busy guard)',
    (tester) async {
      // Wrap the form in a Navigator-aware harness so we can observe
      // pop calls. Each pop returns a ServerProfile; if the busy guard
      // is broken we'd see two pops which would crash the navigator
      // (no second route to pop). The presence of a single profile in
      // [popped] is sufficient evidence of dedup.
      final popped = <ServerProfile?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final result =
                        await Navigator.of(context).push<ServerProfile>(
                      MaterialPageRoute(
                        builder: (_) => const ServerFormScreen(),
                      ),
                    );
                    popped.add(result);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Fill in valid required fields.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name').first,
        'X',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host / IP').first,
        '1.2.3.4',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username').first,
        'root',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password').first,
        'pw',
      );
      await tester.pump();

      // Two near-instant taps. Without the busy guard, the second
      // would crash with "Cannot pop route" or push a duplicate
      // ServerProfile into the result.
      final saveButton = find.text('SAVE');
      await tester.tap(saveButton);
      await tester.tap(saveButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(popped.length, 1);
      expect(popped.single, isNotNull);
    },
  );
}
