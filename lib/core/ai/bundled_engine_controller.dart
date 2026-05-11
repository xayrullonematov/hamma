import 'dart:async';
import 'dart:io';
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
      // Mobile Fast-Path: Mobile platforms (Android/iOS) do not support
      // spawning subprocesses for inference. We bypass the Ollama-style
      // strategy loop and go straight to the FFI backend (fllama).
      if (Platform.isAndroid || Platform.isIOS) {
        debugPrint('BundledEngine: Using mobile FFI runner');
        _instance = BundledEngine(backend: LlamaCppBackend());
        return _instance!;
      }

      // Desktop Path: Try tiered strategy.
      final features = await HardwareDetector.detectAndLog();
      final strategies = RunnerStrategy.getApplicable(features);
      
      InferenceBackend? bestBackend;
      
      // Tier 1: Look for a compatible subprocess binary (Ollama-style).
      for (final strategy in strategies) {
        for (final binary in strategy.binaryCandidates) {
          final backend = LlamaServerBackend(
            binaryPath: binary,
            contextSize: _contextSizeForModel(binary),
          );
          if (backend.isAvailable) {
            debugPrint('BundledEngine: Using ${strategy.name} subprocess runner: $binary');
            bestBackend = backend;
            break;
          }
        }
        if (bestBackend != null) break;
      }

      // Tier 2: Fall back to FFI (fllama) if no binary was found or usable.
      if (bestBackend == null) {
        debugPrint('BundledEngine: No usable subprocess found, falling back to FFI runner');
        bestBackend = LlamaCppBackend();
      }

      _instance = BundledEngine(backend: bestBackend);
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

  static int _contextSizeForModel(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('1b') || lower.contains('1.1b')) return 512;
    if (lower.contains('3b') || lower.contains('3.8b')) return 2048;
    return 4096;
  }
}
