@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/llama_server_backend.dart';

/// End-to-end integration test against a real `llama-server` binary
/// and a real GGUF model.
///
/// Skipped unless **both** environment variables are set:
///
///   * `LLAMA_SERVER_BIN`   — absolute path to the platform binary
///   * `LLAMA_SERVER_MODEL` — absolute path to a GGUF model file
///
/// We don't ship the binary in the repo (~5 MB per OS, plus per-OS
/// build complexity) and we don't ship the model (~750 MB even for
/// the smallest one). CI runs this test on the release pipeline
/// where both are available; local contributors who want to verify
/// the bundled engine works end-to-end can drop in the side-car
/// from `native/<os>/` and a tiny GGUF and run:
///
///   LLAMA_SERVER_BIN=/abs/path/to/llama-server \
///   LLAMA_SERVER_MODEL=/abs/path/to/some-tiny.gguf \
///     flutter test test/llama_server_backend_integration_test.dart
void main() {
  final binPath = Platform.environment['LLAMA_SERVER_BIN'];
  final modelPath = Platform.environment['LLAMA_SERVER_MODEL'];
  final skipReason = (binPath == null || modelPath == null)
      ? 'set LLAMA_SERVER_BIN and LLAMA_SERVER_MODEL to run this test'
      : null;

  test(
    'real llama-server: load + greedy generate yields non-empty text',
    () async {
      final backend = LlamaServerBackend(
        binaryPath: binPath!,
        startupTimeout: const Duration(seconds: 90),
        contextSize: 1024,
      );
      addTearDown(backend.dispose);
      expect(backend.isAvailable, isTrue,
          reason: 'binary at $binPath must exist');

      await backend.loadModel(modelPath!, modelId: 'integration');
      expect(backend.isReady, isTrue);
      final out = await backend
          .generate(
            messages: const [
              {'role': 'user', 'content': 'Say "ok" and nothing else.'},
            ],
            temperature: 0,
            maxTokens: 16,
          )
          .toList();
      expect(out, isNotEmpty,
          reason: 'real model should produce at least one token');
      expect(out.join().isNotEmpty, isTrue);
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
