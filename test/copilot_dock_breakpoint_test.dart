import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/responsive/breakpoints.dart';
import 'package:hamma/features/ai_assistant/copilot_dock.dart';

/// A minimal probe that mirrors the dock-vs-sheet decision used by
/// terminal_screen.dart and watch_with_ai_screen.dart: when a
/// CopilotDock is installed AND the viewport is desktop, route to
/// the dock controller; otherwise show a modal sheet.
class _CopilotInvoker extends StatelessWidget {
  const _CopilotInvoker();

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: () async {
        final dock = CopilotDock.maybeOf(context);
        if (dock != null && Breakpoints.isDesktop(context)) {
          dock.open(
            CopilotDockRequest(
              title: 'AI',
              builder: (_) => const Text('docked-content'),
            ),
          );
          return;
        }
        await showModalBottomSheet<void>(
          context: context,
          builder: (_) => const Text('modal-content'),
        );
      },
      child: const Text('open ai'),
    );
  }
}

Widget _harness({required double width, CopilotDockController? dock}) {
  Widget child = const Scaffold(body: Center(child: _CopilotInvoker()));
  if (dock != null) child = CopilotDock(controller: dock, child: child);
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 900)),
      child: child,
    ),
  );
}

void main() {
  testWidgets('desktop + dock installed → opens docked pane (no modal)',
      (tester) async {
    final dock = CopilotDockController();
    addTearDown(dock.dispose);

    await tester.pumpWidget(_harness(width: 1400, dock: dock));
    await tester.tap(find.text('open ai'));
    await tester.pump();

    expect(dock.isOpen, isTrue);
    expect(dock.request?.title, 'AI');
    expect(find.text('modal-content'), findsNothing);
  });

  testWidgets('tablet + dock installed → falls back to modal sheet',
      (tester) async {
    final dock = CopilotDockController();
    addTearDown(dock.dispose);

    await tester.pumpWidget(_harness(width: 900, dock: dock));
    await tester.tap(find.text('open ai'));
    await tester.pumpAndSettle();

    expect(dock.isOpen, isFalse);
    expect(find.text('modal-content'), findsOneWidget);
  });

  testWidgets('desktop without dock installed → modal sheet',
      (tester) async {
    await tester.pumpWidget(_harness(width: 1400));
    await tester.tap(find.text('open ai'));
    await tester.pumpAndSettle();

    expect(find.text('modal-content'), findsOneWidget);
  });

  testWidgets('mobile + dock installed → modal sheet', (tester) async {
    final dock = CopilotDockController();
    addTearDown(dock.dispose);

    await tester.pumpWidget(_harness(width: 420, dock: dock));
    await tester.tap(find.text('open ai'));
    await tester.pumpAndSettle();

    expect(dock.isOpen, isFalse);
    expect(find.text('modal-content'), findsOneWidget);
  });
}
