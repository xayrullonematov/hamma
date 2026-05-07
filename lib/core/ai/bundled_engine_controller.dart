import 'dart:async';
import 'package:flutter/foundation.dart';

import 'bundled_engine.dart';
import 'llama_server_backend.dart';

import 'hardware_detector.dart';

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

  /// Returns the active engine, lazily detecting the best available
  /// backend on first access using an Ollama-inspired runner strategy.
  static Future<BundledEngine> get instance async {
    if (_instance == null) {
      final features = await HardwareDetector.detect();
      final strategies = RunnerStrategy.getApplicable(features);
      
      InferenceBackend? bestBackend;
      
      // Look for the best available runner among applicable strategies.
      for (final strategy in strategies) {
        // Try Subprocess Strategy (Ollama's preferred runner style)
        for (final binary in strategy.binaryCandidates) {
          final backend = LlamaServerBackend(binaryPath: binary);
          if (backend.isAvailable) {
            debugPrint('BundledEngine: Using ${strategy.name} subprocess runner: $binary');
            bestBackend = backend;
            break;
          }
        }
        if (bestBackend != null) break;

        // Try FFI Strategy (fallback or primary mobile path)
        for (final library in strategy.libraryCandidates) {
          final backend = LlamaCppBackend(libraryPath: library);
          if (backend.isAvailable) {
            debugPrint('BundledEngine: Using ${strategy.name} FFI runner: $library');
            bestBackend = backend;
            break;
          }
        }
        if (bestBackend != null) break;
      }

      // If absolutely nothing is found, use the generic FFI backend
      // as it will provide the best diagnostic error messages.
      _instance = BundledEngine(backend: bestBackend ?? LlamaCppBackend());
    }
    return _instance!;
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
