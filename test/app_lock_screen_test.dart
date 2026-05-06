import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/features/security/app_lock_screen.dart';
import 'package:hamma/core/storage/app_lock_storage.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'app_lock_pin': '1234'});
  });

  testWidgets('AppLockScreen shows keypad on mobile (narrow width)', (WidgetTester tester) async {
    // Set a narrow width
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const MaterialApp(
      home: AppLockScreen(
        mode: AppLockMode.verify,
        appLockStorage: AppLockStorage(),
      ),
    ));

    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    // Should find the keypad (digit 1)
    expect(find.text('1'), findsOneWidget);
    // Should NOT find the "Type your PIN to continue" text (desktop only)
    expect(find.text('Type your PIN to continue'), findsNothing);
    
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });

  testWidgets('AppLockScreen hides keypad and shows desktop layout on wide screen (if platform matches)', (WidgetTester tester) async {
    // This test will only pass on Linux/Windows/MacOS due to Platform check in widget
    if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      return;
    }

    // Set a wide width
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const MaterialApp(
      home: AppLockScreen(
        mode: AppLockMode.verify,
        appLockStorage: AppLockStorage(),
      ),
    ));

    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    // Should NOT find the keypad (digit 1 is in the keypad)
    expect(find.text('1'), findsNothing);
    // Should find the "Type your PIN to continue" text
    expect(find.text('Type your PIN to continue'), findsOneWidget);
    // Should find the "HAMMA" wordmark
    expect(find.text('HAMMA'), findsOneWidget);

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
