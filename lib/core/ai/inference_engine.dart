import 'dart:async';
import 'dart:io';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// Service that runs native LLM inference using the llama_cpp_dart package.
///
/// This engine leverages [LlamaParent] to manage a background Dart Isolate
/// where the heavy computational work of token generation occurs. This
/// ensures the main UI thread remains responsive during long replies.
class InferenceEngine {
  /// Primary constructor.
  const InferenceEngine();

  /// Ensures the native llama.cpp library is loaded on desktop platforms.
  ///
  /// On Android, the package handles this automatically. On Linux, macOS,
  /// and Windows, we must explicitly set [Llama.libraryPath] before the
  /// engine is initialized, as DynamicLibrary.process() fails in
  /// notarised/bundled environments.
  static void ensureNativeLibraryLoaded() {
    if (Platform.isAndroid) return;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final String? libraryName;
    final List<String> candidates;

    if (Platform.isLinux) {
      libraryName = 'libllama.so';
      candidates = [
        '$exeDir/lib/$libraryName',
        '$exeDir/$libraryName',
      ];
    } else if (Platform.isMacOS) {
      libraryName = 'libllama.dylib';
      candidates = [
        '$exeDir/../Frameworks/$libraryName',
        '$exeDir/$libraryName',
      ];
    } else if (Platform.isWindows) {
      libraryName = 'llama.dll';
      candidates = [
        '$exeDir/$libraryName',
      ];
    } else {
      return;
    }

    for (final path in candidates) {
      if (File(path).existsSync()) {
        Llama.libraryPath = path;
        return;
      }
    }

    // If we reach here on a desktop platform, we didn't find the library.
    // We let the engine fail naturally later with a clear error.
    Llama.libraryPath = null;
  }

  // Note: These fields are non-final but the class is used as a singleton
  // in AiCommandService. We manage state internally.
  static LlamaParent? _llamaParent;
  static String? _currentModelPath;

  /// Loads a GGUF model from a local path.
  Future<bool> loadModel(String modelPath) async {
    // 1. Validate file existence before attempting to load
    final file = File(modelPath);
    if (!await file.exists()) {
      throw Exception('Model file not found at: $modelPath');
    }

    // 2. Optimization: If the same model is already loaded and ready, skip reloading
    if (_llamaParent != null &&
        _currentModelPath == modelPath &&
        _llamaParent!.status == LlamaStatus.ready) {
      return true;
    }

    // 3. Clean up any existing background isolate/resources
    await dispose();

    try {
      // 4. Configure model and context parameters. 
      final modelParams = ModelParams();
      final contextParams = ContextParams();
      final samplingParams = SamplerParams();

      final loadCommand = LlamaLoad(
        path: modelPath,
        modelParams: modelParams,
        contextParams: contextParams,
        samplingParams: samplingParams,
      );

      // 5. Initialize the Parent manager which handles Isolate lifecycle
      final parent = LlamaParent(loadCommand);
      _llamaParent = parent;
      
      // init() spawns the LlamaChild isolate and waits for the ready signal
      await parent.init();

      _currentModelPath = modelPath;
      return true;
    } catch (e) {
      // Ensure we don't leave a half-initialized engine
      await dispose();
      throw Exception('Failed to initialize local inference engine: $e');
    }
  }

  /// Generates a streaming response for the given [prompt].
  Stream<String> streamResponse(String prompt, String modelPath) async* {
    // 1. Ensure the engine is ready with the requested model
    if (_llamaParent == null || _currentModelPath != modelPath) {
      await loadModel(modelPath);
    }

    if (_llamaParent == null) {
      throw Exception('Inference engine is not initialized.');
    }

    // 2. Send the prompt to the background isolate. 
    final promptId = await _llamaParent!.sendPrompt(prompt);

    // 3. Set up a local stream controller to bridge tokens and completion events
    final controller = StreamController<String>();

    // Listen for incremental text tokens from the background isolate
    final tokenSub = _llamaParent!.stream.listen((token) {
      if (!controller.isClosed) {
        controller.add(token);
      }
    });

    // Listen for the 'done' signal for this specific prompt
    final completionSub = _llamaParent!.completions.listen((event) {
      if (event.promptId == promptId) {
        if (!event.success) {
          if (!controller.isClosed) {
            controller.addError(
              Exception(event.errorDetails ?? 'Generation failed'),
            );
          }
        }
        if (!controller.isClosed) {
          controller.close();
        }
      }
    });

    try {
      // 4. Yield the tokens to the consumer
      yield* controller.stream;
    } finally {
      // 5. Mandatory cleanup of local listeners to prevent leaks
      await tokenSub.cancel();
      await completionSub.cancel();
    }
  }

  /// Properly shuts down the inference engine and kills the background isolate.
  Future<void> dispose() async {
    if (_llamaParent != null) {
      try {
        await _llamaParent!.dispose();
      } catch (_) {
        // Best-effort cleanup
      } finally {
        _llamaParent = null;
        _currentModelPath = null;
      }
    }
  }
}
