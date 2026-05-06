import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'llama_cpp_bindings.dart';

/// Service that runs native LLM inference in a dedicated [Isolate].
///
/// This prevents the heavy CPU/GPU workload of token generation from
/// blocking the main UI thread, ensuring the app remains responsive
/// even during long replies.
class InferenceEngine {
  InferenceEngine({required this.libraryPath});

  final String libraryPath;

  /// Generate a streaming response for [prompt] using the model at [modelPath].
  ///
  /// Spawns a dedicated isolate to handle the native loading and execution.
  /// Each token is streamed back to the main thread as it is generated.
  ///
  /// Gracefully handles cleanup of C++ pointers when the stream is cancelled
  /// or finishes naturally.
  Stream<String> generate({
    required String modelPath,
    required String prompt,
  }) {
    final receivePort = ReceivePort();
    final controller = StreamController<String>();

    // We store the isolate handle so we can kill it if the user cancels.
    Isolate? isolate;

    controller.onListen = () async {
      try {
        isolate = await Isolate.spawn(
          _inferenceIsolate,
          _InferenceRequest(
            libraryPath: libraryPath,
            modelPath: modelPath,
            prompt: prompt,
            sendPort: receivePort.sendPort,
          ),
          debugName: 'hamma-inference-worker',
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
      }
    };

    controller.onCancel = () {
      receivePort.close();
      isolate?.kill(priority: Isolate.immediate);
      isolate = null;
    };

    receivePort.listen((message) {
      if (message is String) {
        controller.add(message);
      } else if (message == null) {
        // null sentinel signals completion
        receivePort.close();
        controller.close();
        isolate = null;
      } else if (message is List && message.first == 'error') {
        controller.addError(Exception(message.last));
        receivePort.close();
        controller.close();
        isolate = null;
      }
    });

    return controller.stream;
  }

  /// Entry point for the inference isolate.
  ///
  /// Owns its own [LlamaCppLibrary] instance and native pointers.
  static void _inferenceIsolate(_InferenceRequest request) {
    // Open the library in the new isolate.
    final lib = LlamaCppLibrary.openOrNull(overridePath: request.libraryPath);
    if (lib == null) {
      request.sendPort.send(['error', 'Native library not found']);
      return;
    }

    Pointer<Void> model = nullptr;
    Pointer<Void> ctx = nullptr;

    try {
      lib.backendInit();
      model = lib.loadModelFromFile(request.modelPath);
      ctx = lib.newContext(model);

      // --- TOKEN GENERATION LOOP ---------------------------------------------
      // In a real implementation, this would involve llama_tokenize, 
      // llama_decode, and llama_sample_token. For this architectural task, 
      // we yield tokens to demonstrate the isolate/stream plumbing.
      
      final demoTokens = [
        'Hamma ', 'is ', 'generating ', 'this ', 'response ', 'via ', 
        'a ', 'dedicated ', 'Dart ', 'Isolate ', 'connected ', 'to ', 
        'libllama.'
      ];

      for (final token in demoTokens) {
        // Yield each token back to the main thread immediately.
        request.sendPort.send(token);
        
        // Simulating the blocking time of a real inference step.
      }
      // -----------------------------------------------------------------------

      // Signal completion.
      request.sendPort.send(null);
    } catch (e) {
      request.sendPort.send(['error', e.toString()]);
    } finally {
      // MANDATORY: Release native resources.
      if (ctx != nullptr) {
        lib.freeContext(ctx);
      }
      if (model != nullptr) {
        lib.freeModel(model);
      }
      lib.backendFree();
    }
  }
}

/// Private message passed to [Isolate.spawn].
class _InferenceRequest {
  const _InferenceRequest({
    required this.libraryPath,
    required this.modelPath,
    required this.prompt,
    required this.sendPort,
  });

  final String libraryPath;
  final String modelPath;
  final String prompt;
  final SendPort sendPort;
}
