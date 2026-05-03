import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/features/ai_assistant/copilot_dock.dart';

void main() {
  group('CopilotDockController', () {
    test('starts closed and reports no request', () {
      final c = CopilotDockController();
      addTearDown(c.dispose);
      expect(c.isOpen, isFalse);
      expect(c.request, isNull);
    });

    test('open() stores request and notifies listeners', () {
      final c = CopilotDockController();
      addTearDown(c.dispose);
      var notifications = 0;
      c.addListener(() => notifications++);

      final req = CopilotDockRequest(
        title: 'AI',
        builder: (_) => const SizedBox.shrink(),
      );
      c.open(req);

      expect(c.isOpen, isTrue);
      expect(identical(c.request, req), isTrue);
      expect(notifications, 1);
    });

    test('close() clears the request and notifies', () {
      final c = CopilotDockController();
      addTearDown(c.dispose);
      c.open(CopilotDockRequest(
        title: 't',
        builder: (_) => const SizedBox.shrink(),
      ));
      var notifications = 0;
      c.addListener(() => notifications++);

      c.close();
      expect(c.isOpen, isFalse);
      expect(c.request, isNull);
      expect(notifications, 1);
    });

    test('close() is a no-op when already closed (no notifications)', () {
      final c = CopilotDockController();
      addTearDown(c.dispose);
      var notifications = 0;
      c.addListener(() => notifications++);

      c.close();
      expect(notifications, 0);
    });
  });

  group('CopilotDockRequest', () {
    test('every request gets a unique key so docked content remounts', () {
      // The dashboard rebuilds the docked pane via a KeyedSubtree
      // bound to [request.key]. If two consecutive requests reused
      // the same key, the AiCopilotSheet state (chat history, voice
      // mode, etc.) would leak across surfaces.
      final a = CopilotDockRequest(
        title: 'a',
        builder: (_) => const SizedBox.shrink(),
      );
      final b = CopilotDockRequest(
        title: 'a',
        builder: (_) => const SizedBox.shrink(),
      );
      expect(a.key, isNot(equals(b.key)));
    });
  });

  group('CopilotDock InheritedNotifier', () {
    testWidgets('maybeOf returns null when no dock is installed',
        (tester) async {
      CopilotDockController? found;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            found = CopilotDock.maybeOf(context);
            return const SizedBox.shrink();
          }),
        ),
      );
      expect(found, isNull);
    });

    testWidgets('maybeOf returns the controller when dock is installed',
        (tester) async {
      final controller = CopilotDockController();
      addTearDown(controller.dispose);

      CopilotDockController? found;
      await tester.pumpWidget(
        MaterialApp(
          home: CopilotDock(
            controller: controller,
            child: Builder(builder: (context) {
              found = CopilotDock.maybeOf(context);
              return const SizedBox.shrink();
            }),
          ),
        ),
      );
      expect(identical(found, controller), isTrue);
    });
  });
}
