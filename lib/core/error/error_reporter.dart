import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'error_scrubber.dart';
import 'in_widget_error_panel.dart';

/// Central installer for Flutter's three top-level error hooks:
///
///  - [FlutterError.onError] — synchronous framework errors (build,
///    layout, paint).
///  - [PlatformDispatcher.instance.onError] — uncaught async errors at
///    the platform/isolate level.
///  - [ErrorWidget.builder] — replaces the default red-on-yellow widget
///    that appears when a single widget fails to render.
///
/// All three hooks chain to whatever was previously installed (so this
/// can be safely called before `SentryFlutter.init`, which then layers
/// its own handlers on top without losing ours).
///
/// Captured errors are passed through [ErrorScrubber.scrub] before they
/// are stored in [lastFatal] or surfaced via the in-widget error panel.
/// They are **not** scrubbed before being forwarded to Sentry — the
/// Sentry `beforeSend` hook in `main.dart` handles transport-side
/// scrubbing so the original stack frames are preserved for debugging.
class ErrorReporter {
  ErrorReporter._();

  static bool _installed = false;

  /// The most recent fatal error captured by [install], or `null` if no
  /// fatal error has occurred. The message has been passed through
  /// [ErrorScrubber.scrub]; the raw object is also retained for callers
  /// that want to format it themselves.
  static FatalError? lastFatal;

  /// Installs the three error hooks. Idempotent — subsequent calls are
  /// no-ops. Must be called after `WidgetsFlutterBinding.ensureInitialized()`
  /// (because it touches `PlatformDispatcher.instance`).
  static void install() {
    if (_installed) return;
    _installed = true;

    // Preserve and chain to whatever was already installed so we play
    // nice with Sentry's own integrations.
    final previousFlutterErrorHandler = FlutterError.onError;
    final previousDispatcherHandler = PlatformDispatcher.instance.onError;

    FlutterError.onError = (FlutterErrorDetails details) {
      _capture(details.exception, details.stack, hint: 'Flutter framework');
      // Always print to console in debug for fast feedback.
      if (kDebugMode) {
        FlutterError.dumpErrorToConsole(details);
      }
      // Chain to the previous handler last so Sentry-style integrations
      // still receive every event.
      previousFlutterErrorHandler?.call(details);
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _capture(error, stack, hint: 'Platform dispatcher');
      // Returning `true` from a chained handler tells Flutter the error
      // was handled. We defer the final true/false to the previous
      // handler if any; otherwise return true to suppress the default
      // crash-the-isolate behavior in release.
      final handledByPrevious = previousDispatcherHandler?.call(error, stack);
      return handledByPrevious ?? true;
    };

    ErrorWidget.builder = (FlutterErrorDetails details) {
      // Single-widget render failures get an in-place brutalist panel
      // instead of the default red banner. The fatal-error capture
      // already happened in FlutterError.onError above.
      return InWidgetErrorPanel(details: details);
    };
  }

  /// Manually report an error caught in a try/catch block.
  ///
  /// Forwards to Sentry if it has been initialized and updates
  /// [lastFatal]. Never throws.
  static Future<void> report(
    Object error,
    StackTrace? stack, {
    String? hint,
  }) async {
    _capture(error, stack, hint: hint);
    try {
      if (Sentry.isEnabled) {
        await Sentry.captureException(error, stackTrace: stack);
      }
    } catch (_) {
      // Swallow — the reporter must never throw.
    }
  }

  /// Resets installation state. Test-only.
  @visibleForTesting
  static void debugReset() {
    _installed = false;
    lastFatal = null;
  }

  static void _capture(Object error, StackTrace? stack, {String? hint}) {
    final scrubbed = ErrorScrubber.scrub(error.toString());
    lastFatal = FatalError(
      original: error,
      scrubbedMessage: scrubbed,
      stackTrace: stack,
      hint: hint,
      capturedAt: DateTime.now(),
    );
  }
}

/// A captured fatal error with its message already scrubbed of likely
/// sensitive substrings. The raw [original] object and [stackTrace] are
/// retained for callers that need them (e.g., the crash screen formats
/// them itself in debug mode).
class FatalError {
  const FatalError({
    required this.original,
    required this.scrubbedMessage,
    required this.stackTrace,
    required this.hint,
    required this.capturedAt,
  });

  final Object original;
  final String scrubbedMessage;
  final StackTrace? stackTrace;
  final String? hint;
  final DateTime capturedAt;
}
