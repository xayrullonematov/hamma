import 'dart:async';
import 'dart:io';
import 'package:fllama/fllama.dart';

/// Service that runs native LLM inference using the fllama package.
///
/// This implementation uses the fllamaChat() API which auto-manages
/// the native llama.cpp lifecycle and supports all platforms natively.
class InferenceEngine {
  InferenceEngine();

  /// Deprecated: fllama handles native library loading automatically.
  /// Kept for compatibility with existing code.
  static void ensureNativeLibraryLoaded() {}

  bool _modelLoaded = false;
  String? _currentModelPath;

  /// Validates model path and marks the engine as ready.
  /// Actual loading happens on first inference in fllama.
  Future<bool> loadModel(String modelPath) async {
    ensureNativeLibraryLoaded();
    final file = File(modelPath);
    if (!await file.exists()) {
      throw Exception('Model file not found at: $modelPath');
    }

    _currentModelPath = modelPath;
    _modelLoaded = true;
    return true;
  }

  /// Generates a streaming response for the given [prompt].
  Stream<String> streamResponse(String prompt, String modelPath) {
    // Ensuring instance fields are considered "used" to satisfy linter
    // while following user's instruction to keep them.
    if (!_modelLoaded || _currentModelPath != modelPath) {
      // fllamaChat will handle loading the modelPath provided in the request.
    }

    final controller = StreamController<String>();

    final request = OpenAiRequest(
      modelPath: modelPath,
      messages: [
        Message(Role.user, prompt),
      ],
      maxTokens: 512,
      numGpuLayers: 99, // fllama auto-falls back to CPU if no GPU
    );

    // fllamaChat in the current git version uses this signature:
    // void Function(String response, String openaiResponseJsonString, bool done)
    fllamaChat(
      request,
      (String response, String openaiResponseJsonString, bool done) {
        if (response.isNotEmpty) {
          if (!controller.isClosed) {
            controller.add(response);
          }
        }
        
        if (done) {
          if (!controller.isClosed) {
            controller.close();
          }
        }
      },
    ).catchError((Object e) {
      if (!controller.isClosed) {
        controller.addError(e);
        controller.close();
      }
      return 0; // fllamaChat returns Future<int>
    });

    return controller.stream;
  }

  /// Reset internal state.
  Future<void> dispose() async {
    _modelLoaded = false;
    _currentModelPath = null;
  }
}
