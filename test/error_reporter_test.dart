import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/error/error_reporter.dart';
import 'package:hamma/core/error/in_widget_error_panel.dart';

void main() {
  // Required because ErrorReporter.install touches PlatformDispatcher.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ErrorReporter.debugReset();
  });

  tearDown(() {
    ErrorReporter.debugReset();
  });

  group('ErrorReporter.install', () {
    test('is idempotent — second install is a no-op', () {
      ErrorReporter.install();
      final firstHandler = FlutterError.onError;

      ErrorReporter.install();
      final secondHandler = FlutterError.onError;

      // No new handler should have been wrapped on the second call.
      expect(secondHandler, same(firstHandler));
    });

    test('chains to the previously installed FlutterError.onError', () {
      var previousCalled = false;
      FlutterError.onError = (_) => previousCalled = true;

      ErrorReporter.install();

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('boom'),
        stack: StackTrace.current,
      ));

      expect(previousCalled, isTrue,
          reason: 'Previously installed handler must still be invoked');
    });

    test('chains to the previously installed PlatformDispatcher.onError', () {
      var previousCalled = false;
      PlatformDispatcher.instance.onError = (error, stack) {
        previousCalled = true;
        return true;
      };

      ErrorReporter.install();

      final result = PlatformDispatcher.instance.onError!(
        Exception('boom'),
        StackTrace.current,
      );

      expect(previousCalled, isTrue);
      expect(result, isTrue);
    });

    test('replaces ErrorWidget.builder with InWidgetErrorPanel', () {
      ErrorReporter.install();

      final widget = ErrorWidget.builder(FlutterErrorDetails(
        exception: Exception('build failure'),
      ));

      expect(widget, isA<InWidgetErrorPanel>());
    });
  });

  group('ErrorReporter capture', () {
    test('FlutterError.onError populates lastFatal with scrubbed message', () {
      ErrorReporter.install();

      // Suppress console noise from dumpErrorToConsole in debug mode.
      final previousPresent = FlutterError.presentError;
      FlutterError.presentError = (_) {};
      addTearDown(() => FlutterError.presentError = previousPresent);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('Login failed for password=hunter2'),
        stack: StackTrace.current,
      ));

      expect(ErrorReporter.lastFatal, isNotNull);
      expect(
        ErrorReporter.lastFatal!.scrubbedMessage,
        contains('password=[SCRUBBED]'),
      );
      expect(
        ErrorReporter.lastFatal!.scrubbedMessage,
        isNot(contains('hunter2')),
      );
    });

    test('PlatformDispatcher.onError populates lastFatal', () {
      ErrorReporter.install();

      PlatformDispatcher.instance.onError!(
        Exception('token=abc123secret'),
        StackTrace.current,
      );

      expect(ErrorReporter.lastFatal, isNotNull);
      expect(ErrorReporter.lastFatal!.hint, 'Platform dispatcher');
      expect(
        ErrorReporter.lastFatal!.scrubbedMessage,
        contains('token=[SCRUBBED]'),
      );
    });

    test('report() never throws even when Sentry is not initialized',
        () async {
      ErrorReporter.install();

      await expectLater(
        ErrorReporter.report(
          Exception('async failure with secret=topsecret'),
          StackTrace.current,
          hint: 'unit test',
        ),
        completes,
      );

      expect(ErrorReporter.lastFatal, isNotNull);
      expect(ErrorReporter.lastFatal!.hint, 'unit test');
      expect(
        ErrorReporter.lastFatal!.scrubbedMessage,
        contains('secret=[SCRUBBED]'),
      );
    });

    test('lastFatal preserves the original error object', () async {
      ErrorReporter.install();

      final original = Exception('something specific');
      await ErrorReporter.report(original, StackTrace.current);

      expect(ErrorReporter.lastFatal!.original, same(original));
    });

    test('capturedAt timestamp is set on each capture', () async {
      ErrorReporter.install();

      final before = DateTime.now();
      await ErrorReporter.report(Exception('first'), StackTrace.current);
      final after = DateTime.now();

      final captured = ErrorReporter.lastFatal!.capturedAt;
      expect(captured.isAfter(before.subtract(const Duration(seconds: 1))),
          isTrue);
      expect(captured.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });
  });

  group('InWidgetErrorPanel', () {
    testWidgets('renders the scrubbed exception message',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: InWidgetErrorPanel(
            details: FlutterErrorDetails(
              exception: Exception('Failed with password=hunter2'),
            ),
          ),
        ),
      );

      expect(find.text('RENDER ERROR'), findsOneWidget);
      expect(find.textContaining('password=[SCRUBBED]'), findsOneWidget);
      expect(find.textContaining('hunter2'), findsNothing);
    });

    testWidgets(
        'falls through to Flutter\'s "<no message available>" '
        'placeholder when the exception is empty',
        (WidgetTester tester) async {
      // FlutterErrorDetails.exceptionAsString() substitutes its own
      // placeholder for empty exceptions before our panel ever sees the
      // string, so we just verify the panel renders that placeholder
      // (rather than crashing or hiding it).
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: InWidgetErrorPanel(
            details: FlutterErrorDetails(exception: ''),
          ),
        ),
      );

      expect(find.textContaining('no message available'), findsOneWidget);
    });
  });
}
