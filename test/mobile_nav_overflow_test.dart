import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/features/servers/server_dashboard_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const eight = <DashboardNavItem>[
    DashboardNavItem(icon: Icons.terminal_rounded, label: 'Terminal'),
    DashboardNavItem(icon: Icons.folder_open_rounded, label: 'Files'),
    DashboardNavItem(icon: Icons.directions_boat_rounded, label: 'Docker'),
    DashboardNavItem(
        icon: Icons.settings_input_component_rounded, label: 'Services'),
    DashboardNavItem(
        icon: Icons.system_update_alt_rounded, label: 'Packages'),
    DashboardNavItem(icon: Icons.monitor_heart_outlined, label: 'Health'),
    DashboardNavItem(icon: Icons.article_outlined, label: 'Logs'),
    DashboardNavItem(icon: Icons.menu_book_outlined, label: 'Runbooks'),
  ];

  Widget host({
    required List<DashboardNavItem> items,
    int activeIndex = 0,
    bool isConnected = true,
    void Function(int)? onSelect,
  }) {
    return MaterialApp(
      home: Scaffold(
        bottomNavigationBar: MobileDashboardBottomNav(
          items: items,
          activeIndex: activeIndex,
          isConnected: isConnected,
          onSelect: onSelect ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('"More" destination appears when items exceed the visible limit',
      (tester) async {
    await tester.pumpWidget(host(items: eight));
    expect(
      find.byKey(const ValueKey('mobile_nav_more_destination')),
      findsOneWidget,
    );
  });

  testWidgets('"More" is absent when items fit within the visible limit',
      (tester) async {
    await tester.pumpWidget(host(items: eight.take(4).toList()));
    expect(
      find.byKey(const ValueKey('mobile_nav_more_destination')),
      findsNothing,
    );
  });

  testWidgets(
      'tapping "More" opens the overflow sheet with the remaining tabs',
      (tester) async {
    await tester.pumpWidget(host(items: eight));

    await tester.tap(
      find.byKey(const ValueKey('mobile_nav_more_destination')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile_plugin_overflow_sheet')),
      findsOneWidget,
    );
    // Tabs past the visible limit (visibleCount = 4): Packages, Health,
    // Logs, Runbooks should appear in the overflow sheet.
    expect(find.text('PACKAGES'), findsOneWidget);
    expect(find.text('HEALTH'), findsOneWidget);
    expect(find.text('LOGS'), findsOneWidget);
    expect(find.text('RUNBOOKS'), findsOneWidget);
  });

  testWidgets('selecting an overflow item invokes onSelect with its index',
      (tester) async {
    int? selected;
    await tester.pumpWidget(host(
      items: eight,
      onSelect: (i) => selected = i,
    ));

    await tester.tap(
      find.byKey(const ValueKey('mobile_nav_more_destination')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('RUNBOOKS'));
    await tester.pumpAndSettle();

    // Runbooks is the 8th built-in tab (index 7).
    expect(selected, 7);
    // Sheet closes after selection.
    expect(
      find.byKey(const ValueKey('mobile_plugin_overflow_sheet')),
      findsNothing,
    );
  });
}
