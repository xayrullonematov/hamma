import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/storage/app_prefs_storage.dart';
import 'package:hamma/features/servers/server_dashboard_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('drag updates emit clamped widths within min/max', (tester) async {
    final updates = <double>[];
    var ended = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 240),
              SidebarResizeHandle(
                currentWidth: 240,
                onDragUpdate: updates.add,
                onDragEnd: () => ended++,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final handle = find.byType(SidebarResizeHandle);
    final start = tester.getCenter(handle);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(updates, isNotEmpty);
    expect(updates.last, lessThanOrEqualTo(AppPrefsStorage.sidebarMaxWidth));
    expect(updates.last, greaterThanOrEqualTo(AppPrefsStorage.sidebarMinWidth));
    expect(ended, 1);
  });

  testWidgets('over-drag is clamped to sidebarMaxWidth', (tester) async {
    final updates = <double>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 240),
              SidebarResizeHandle(
                currentWidth: AppPrefsStorage.sidebarMaxWidth - 5,
                onDragUpdate: updates.add,
                onDragEnd: () {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SidebarResizeHandle)),
    );
    await gesture.moveBy(const Offset(500, 0));
    await tester.pump();
    await gesture.up();

    expect(updates.last, AppPrefsStorage.sidebarMaxWidth);
  });

  test('AppPrefsStorage round-trip persists drag-end width', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = AppPrefsStorage();

    expect(await prefs.getSidebarWidth(), isNull);
    await prefs.setSidebarWidth(312);
    expect(await prefs.getSidebarWidth(), 312);
  });
}
