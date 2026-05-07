import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/inference_engine.dart';

void main() {
  group('InferenceEngine (basic)', () {
    const InferenceEngine engine = InferenceEngine();

    test('can be instantiated as const', () {
      expect(engine, isNotNull);
    });

    test('loadModel throws if file missing', () async {
      expect(
        () => engine.loadModel('/path/to/nothing.gguf'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
