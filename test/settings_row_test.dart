import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/features/settings/widgets/settings_row.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );
  }

  testWidgets('SettingsRow chevron variant renders label, value, and chevron',
      (tester) async {
    await tester.pumpWidget(host(
      SettingsRowGroup(
        header: 'GROUP',
        children: [
          SettingsRow.chevron(
            icon: Icons.bolt,
            label: 'Default Provider',
            value: 'OpenAI · gpt-4o-mini',
            onTap: () {},
          ),
        ],
      ),
    ));

    expect(find.text('GROUP'), findsOneWidget);
    expect(find.text('Default Provider'), findsOneWidget);
    expect(find.text('OpenAI · gpt-4o-mini'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('SettingsRow toggle variant flips value and fires onToggle',
      (tester) async {
    var current = false;
    var calls = 0;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) {
        return host(
          SettingsRowGroup(
            header: 'TOGGLES',
            children: [
              SettingsRow.toggle(
                icon: Icons.notifications,
                label: 'Background Monitoring',
                toggleValue: current,
                onToggle: (v) => setState(() {
                  current = v;
                  calls++;
                }),
              ),
            ],
          ),
        );
      },
    ));

    expect(find.byType(Switch), findsOneWidget);
    expect((tester.widget(find.byType(Switch)) as Switch).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(current, isTrue);
    expect((tester.widget(find.byType(Switch)) as Switch).value, isTrue);
  });

  testWidgets('SettingsRow chevron tap fires onTap once', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      SettingsRowGroup(
        header: 'GROUP',
        children: [
          SettingsRow.chevron(
            icon: Icons.help_outline,
            label: 'Help Center',
            value: 'Guides and FAQs',
            onTap: () => taps++,
          ),
        ],
      ),
    ));

    await tester.tap(find.text('Help Center'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('disabled SettingsRow ignores taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      SettingsRowGroup(
        header: 'GROUP',
        children: [
          SettingsRow.chevron(
            icon: Icons.mail_outline,
            label: 'Contact Support',
            value: 'Email the team',
            enabled: false,
            onTap: () => taps++,
          ),
        ],
      ),
    ));

    await tester.tap(find.text('Contact Support'));
    await tester.pumpAndSettle();
    expect(taps, 0);
  });
}
