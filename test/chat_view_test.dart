import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/ui/terminal/chat_view.dart';

void main() {
  testWidgets('ChatView renders brutalist header and tokens', (tester) async {
    final tokenController = StreamController<String>();
    final progressController = StreamController<double>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatView(
            tokenStream: tokenController.stream,
            downloadProgressStream: progressController.stream,
          ),
        ),
      ),
    );

    // Header was removed
    expect(find.text('AI TERMINAL v2.0 — STREAMING'), findsNothing);

    tokenController.add('Hello ');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Hello '), findsOneWidget);

    tokenController.add('World');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Hello World'), findsOneWidget);

    progressController.add(50.0);
    await tester.pump(const Duration(milliseconds: 100));
    // Label was removed
    expect(find.textContaining('50.0%'), findsNothing);
    // ASCII bar [=========>          ] remains while < 100%
    expect(find.textContaining('[=========>          ]'), findsOneWidget);

    progressController.add(100.0);
    await tester.pump(const Duration(milliseconds: 100));
    // Bar disappears when done
    expect(find.textContaining('['), findsNothing);

    await tokenController.close();
    await progressController.close();

  });
}
