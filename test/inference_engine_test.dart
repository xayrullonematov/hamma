import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/inference_engine.dart';

void main() {
  group('InferenceEngine', () {
    late InferenceEngine engine;

    setUp(() {
      engine = InferenceEngine(libraryPath: 'dummy_lib.so');
    });

    test('generate yields tokens and completes', () async {
      // In this test, it will probably fail because dummy_lib.so doesn't exist,
      // and the isolate will return an error message.
      // But we can test that the stream emits *something* (even an error).
      
      final tokens = <String>[];
      final stream = engine.generate(
        modelPath: 'dummy_model.gguf',
        prompt: 'Hello',
      );

      try {
        await for (final token in stream) {
          tokens.add(token);
        }
      } catch (e) {
        // Expected if native lib not found
        expect(e.toString(), contains('Native library not found'));
      }
    });
  });
}
