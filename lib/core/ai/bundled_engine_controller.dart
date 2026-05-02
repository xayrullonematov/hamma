import 'dart:async';

import 'bundled_engine.dart';
import 'llama_server_backend.dart';

/// Process-wide singleton that owns the [BundledEngine] for the app.
///
/// We keep one engine instance for the whole app lifetime so model
/// load (which is expensive — gigabytes mmapped, several seconds of
/// warmup) only happens once. Settings, the AI assistant screen and
/// the copilot sheet all read from the same controller.
///
/// In tests, call [BundledEngineController.overrideForTesting] in a
/// `setUp` block and [resetForTesting] in `tearDown` to swap the
/// underlying engine for one backed by [EchoBackend].
class BundledEngineController {
  BundledEngineController._();

  static BundledEngine? _instance;

  /// Returns the active engine, lazily creating one (with the default
  /// [LlamaServerBackend]) on first access. The backend wraps the
  /// upstream `llama-server` binary — see `native/README.md` for how
  /// the per-OS side-car gets built and bundled.
  static BundledEngine get instance {
    return _instance ??= BundledEngine(backend: LlamaServerBackend());
  }

  /// True when the controller has been wired (either by `instance`
  /// access or by an override). Used by the UI to decide whether to
  /// show a "built-in engine offline" pill or hide the section
  /// entirely.
  static bool get isWired => _instance != null;

  /// Replace the singleton with [engine]. Stops the previous instance
  /// if there was one. Tests should always use this and pair with
  /// [resetForTesting].
  static void overrideForTesting(BundledEngine engine) {
    final prev = _instance;
    _instance = engine;
    if (prev != null) {
      // Best-effort cleanup of the prior instance — ignore failures so
      // a flaky teardown doesn't poison subsequent tests.
      unawaited(prev.dispose());
    }
  }

  /// Tear down the active singleton. Call from `tearDown` in tests.
  static Future<void> resetForTesting() async {
    final prev = _instance;
    _instance = null;
    if (prev != null) {
      await prev.dispose();
    }
  }
}
