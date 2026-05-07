// ignore_for_file: camel_case_types
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Minimal Dart FFI typedefs for the public llama.cpp C API.
///
/// We bind only the handful of symbols the bundled engine actually uses
/// (load model, tokenise, decode, sample, free) so that:
///
///   * Compilation never depends on having the full `llama.h` available.
///   * The native shared library is loaded **on demand** — when the user
///     opts into "Built-in engine" — so launching Hamma without a
///     bundled model never pays the FFI cost.
///   * The surface is small enough to swap out for a different runtime
///     (mlc, candle, executorch …) by writing a new [LlamaCppLibrary]
///     subclass.
///
/// This file purposely contains **no global state** — `dart:ffi` symbol
/// lookup is deferred until [LlamaCppLibrary.openOrNull] is called, and
/// every binding is a method on the loaded library handle. That lets unit
/// tests construct the engine with a fake backend and skip native
/// loading entirely.
class LlamaCppLibrary {
  LlamaCppLibrary._(this._lib) {
    _bind();
  }

  final DynamicLibrary _lib;

  /// Try to load the platform shared library for llama.cpp.
  ///
  /// Returns `null` (instead of throwing) when the library is not
  /// present. The caller decides whether to surface that as an error
  /// or fall through to "use external Ollama" mode.
  ///
  /// On Linux/macOS we look up `libllama.so` / `libllama.dylib` next to
  /// the executable (Flutter desktop bundles native libs into `lib/`),
  /// then fall back to the system loader path so power users can drop a
  /// build of llama.cpp into `/usr/local/lib`. On Windows we look for
  /// `llama.dll` next to the binary.
  static LlamaCppLibrary? openOrNull({String? overridePath}) {
    try {
      DynamicLibrary lib;
      if (overridePath != null && overridePath.isNotEmpty) {
        lib = DynamicLibrary.open(overridePath);
      } else {
        lib = _openPlatformDefault();
      }
      return LlamaCppLibrary._(lib);
    } catch (_) {
      return null;
    }
  }

  static DynamicLibrary _openPlatformDefault() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    
    // We look in standard Flutter bundle locations for each OS.
    final candidates = <String>[
      // Direct name (system path or Android native lib path)
      'libllama.so',
      'libllama.dylib',
      'llama.dll',
      
      // Desktop Bundle layouts
      p.join(exeDir, 'lib', 'libllama.so'),
      p.join(exeDir, 'libllama.so'),
      p.join(exeDir, 'libllama.dylib'),
      p.join(exeDir, 'llama.dll'),
      
      // macOS .app/Contents/Frameworks/
      p.join(exeDir, '..', 'Frameworks', 'libllama.dylib'),
      
      // Fallback for development / custom installs
      '/usr/local/lib/libllama.so',
      '/usr/local/lib/libllama.dylib',
    ];

    Object? lastError;
    for (final path in candidates) {
      try {
        return DynamicLibrary.open(path);
      } catch (e) {
        lastError = e;
      }
    }
    
    // If all fail, try opening by just the name (last resort)
    try {
      if (Platform.isWindows) return DynamicLibrary.open('llama.dll');
      if (Platform.isMacOS) return DynamicLibrary.open('libllama.dylib');
      return DynamicLibrary.open('libllama.so');
    } catch (e) {
      lastError = e;
    }

    throw StateError(
      'Could not locate libllama. Tried ${candidates.length} candidates. '
      'Last error: $lastError',
    );
  }

  // --- Late-bound function pointers ----------------------------------------

  late final void Function() _backendInit;
  late final void Function() _backendFree;
  late final Pointer<Void> Function(Pointer<Utf8> path, Pointer<Void> params)
      _modelLoad;
  late final void Function(Pointer<Void> model) _modelFree;
  late final Pointer<Void> Function(Pointer<Void> model, Pointer<Void> params)
      _ctxNew;
  late final void Function(Pointer<Void> ctx) _ctxFree;

  void _bind() {
    _backendInit = _lib
        .lookupFunction<Void Function(), void Function()>('llama_backend_init');
    _backendFree = _lib.lookupFunction<Void Function(), void Function()>(
        'llama_backend_free');
    _modelLoad = _lib.lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Void>),
        Pointer<Void> Function(
            Pointer<Utf8>, Pointer<Void>)>('llama_load_model_from_file');
    _modelFree = _lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('llama_free_model');
    _ctxNew = _lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>(
        'llama_new_context_with_model');
    _ctxFree = _lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('llama_free');
  }

  /// Initialise the llama.cpp backend (loads CUDA/Metal/CPU kernels). Safe
  /// to call multiple times — the underlying impl is reference-counted.
  void backendInit() => _backendInit();

  /// Tear down everything the backend allocated. Call once at shutdown.
  void backendFree() => _backendFree();

  /// Load a GGUF model from disk. Returns an opaque pointer; the caller
  /// is responsible for handing it back to [freeModel] when done.
  Pointer<Void> loadModelFromFile(String path) {
    final cstr = path.toNativeUtf8();
    try {
      final handle = _modelLoad(cstr, nullptr);
      if (handle == nullptr) {
        throw StateError('llama_load_model_from_file returned NULL for $path');
      }
      return handle;
    } finally {
      malloc.free(cstr);
    }
  }

  void freeModel(Pointer<Void> model) {
    if (model == nullptr) return;
    _modelFree(model);
  }

  /// Spin up an inference context for a previously loaded model.
  Pointer<Void> newContext(Pointer<Void> model) {
    final ctx = _ctxNew(model, nullptr);
    if (ctx == nullptr) {
      throw StateError('llama_new_context_with_model returned NULL');
    }
    return ctx;
  }

  void freeContext(Pointer<Void> ctx) {
    if (ctx == nullptr) return;
    _ctxFree(ctx);
  }
}
