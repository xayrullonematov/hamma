import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'llama_cpp_bindings.dart';
import 'llama_server_backend.dart';

/// Pluggable inference backend the [BundledEngine] talks to.
///
/// The production implementation is [LlamaServerBackend] (in
/// `llama_server_backend.dart`), which spawns the upstream
/// `llama-server` binary as a child process and proxies requests to
/// it over loopback HTTP. Tests inject [EchoBackend] (or another
/// custom fake) so the HTTP shim, the streaming protocol and the
/// onboarding wiring can all be exercised without a native binary.
/// [LlamaCppBackend] (FFI) is kept as a future option but is
/// currently disabled — see its docstring.
///
/// Backend implementations MUST be safe to call from a single isolate
/// (the engine serialises concurrent generate() calls so callers don't
/// have to). [generate] yields one delta per token / chunk; the stream
/// completes when generation finishes naturally or the consumer
/// cancels.
abstract class InferenceBackend {
  /// `true` once a model is loaded and the backend can serve [generate].
  bool get isReady;

  /// True when this backend is actually usable on this OS (e.g. native
  /// library is present). [BundledEngine.start] short-circuits with a
  /// helpful error when this returns false so the UI can fall back to
  /// "connect to existing engine".
  bool get isAvailable;

  /// Identifier the OpenAI-compatible shim returns for `model` in
  /// `/v1/models`. Typically the active model id (e.g. `gemma3-1b-it-q4`).
  String get currentModelId;

  /// Load a GGUF model from [modelPath]. Calling [loadModel] a second
  /// time on the same backend MUST tear down the previous one first —
  /// the implementation handles that internally. Throws on failure.
  Future<void> loadModel(String modelPath, {String? modelId});

  /// Generate a streaming reply for [messages]. Each yielded string is
  /// an incremental chunk (one token, or a few — backends are free to
  /// batch). The stream ends naturally when the model returns its EOT
  /// token or when [maxTokens] is reached.
  Stream<String> generate({
    required List<Map<String, String>> messages,
    double? temperature,
    int? maxTokens,
  });

  /// Tear down the loaded model and release native resources. Idempotent.
  Future<void> dispose();
}

/// **Future / experimental** backend that talks to `libllama` directly
/// via FFI. Not used in production — see [LlamaServerBackend] in
/// `llama_server_backend.dart`, which is the default backend wired
/// into [BundledEngineController].
///
/// Why this exists: the FFI path is a useful fallback for builds where
/// spawning a subprocess isn't an option (locked-down sandboxes,
/// future iOS support). The bindings in `llama_cpp_bindings.dart`
/// cover the symbols a complete implementation would need; the
/// generation loop itself (token sampling, KV-cache management,
/// chat-template wiring) is intentionally not wired up here because
/// the struct ABI of llama.cpp's `llama_batch` / `llama_*_params` is
/// volatile across upstream releases and would need to be pinned per
/// release in production. [LlamaServerBackend] sidesteps that by
/// using upstream's stable HTTP API.
///
/// [isAvailable] returns false unless a real `libllama` is present
/// AND a future implementation flips the gate, so the onboarding UI
/// silently routes around this path today.
class LlamaCppBackend implements InferenceBackend {
  LlamaCppBackend({LlamaCppLibrary? library, String? libraryPath})
      : _explicitLibrary = library,
        _libraryPath = libraryPath;

  final LlamaCppLibrary? _explicitLibrary;
  final String? _libraryPath;
  LlamaCppLibrary? _resolvedLibrary;

  String _modelId = '';
  bool _modelLoaded = false;

  LlamaCppLibrary? get _library {
    if (_explicitLibrary != null) return _explicitLibrary;
    _resolvedLibrary ??= LlamaCppLibrary.openOrNull(overridePath: _libraryPath);
    return _resolvedLibrary;
  }

  @override
  bool get isAvailable {
    // Library presence alone isn't enough — until the FFI generation
    // loop is wired up, this backend cannot actually serve requests.
    // Returning false keeps the onboarding UI from advertising a
    // path that will throw on first use. See [LlamaServerBackend].
    return false;
  }

  /// True iff the underlying shared library is loadable. Distinct from
  /// [isAvailable] which also requires the generation pipeline to be
  /// implemented. Useful for diagnostics ("library is present but
  /// FFI engine is disabled in this build").
  bool get hasNativeLibrary => _library != null;

  @override
  bool get isReady => _modelLoaded;

  @override
  String get currentModelId => _modelId;

  @override
  Future<void> loadModel(String modelPath, {String? modelId}) async {
    final lib = _library;
    if (lib == null) {
      throw StateError(
        'libllama is not bundled with this build. Drop the platform '
        'shared library into the app bundle (see native/README.md) or '
        'use the "Connect to existing engine" path.',
      );
    }
    final file = File(modelPath);
    if (!file.existsSync()) {
      throw StateError('Model file not found: $modelPath');
    }
    lib.backendInit();
    // We deliberately do NOT call `lib.loadModelFromFile(modelPath)` here
    // unless the consumer has actually opted in — invoking native code
    // without a real GGUF-compatible build of llama.cpp would crash the
    // host process. The runtime check above is enough to keep the
    // architecture honest; the wiring to native generation lives behind
    // a build-time flag in the production llama.cpp side-car package
    // (see native/README.md).
    _modelLoaded = true;
    _modelId = modelId?.trim().isNotEmpty == true
        ? modelId!.trim()
        : _deriveModelId(modelPath);
  }

  static String _deriveModelId(String path) {
    final fname = path.split(RegExp(r'[/\\]')).last;
    return fname.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '');
  }

  @override
  Stream<String> generate({
    required List<Map<String, String>> messages,
    double? temperature,
    int? maxTokens,
  }) async* {
    if (!_modelLoaded) {
      throw StateError('LlamaCppBackend.generate called before loadModel');
    }
    // Production wire-through to llama_decode lives in the native
    // side-car package. The Dart-side architecture above is what gets
    // shipped, tested and reviewed; switching this branch to a real
    // sampling loop is the single change required when the native
    // sidecar lands.
    throw UnimplementedError(
      'Native llama.cpp generation is not built into this binary. '
      'Build the side-car as documented in native/README.md.',
    );
  }

  @override
  Future<void> dispose() async {
    if (_modelLoaded) {
      _library?.backendFree();
    }
    _modelLoaded = false;
    _modelId = '';
  }
}

/// In-process backend that streams a deterministic echo of the user's
/// last message. Used by tests and as a "demo mode" when no real model
/// is loaded so the UI plumbing stays exercised end to end.
class EchoBackend implements InferenceBackend {
  EchoBackend({this.modelId = 'echo-demo', this.chunkSize = 4});

  final String modelId;
  final int chunkSize;
  bool _ready = false;

  @override
  bool get isAvailable => true;

  @override
  bool get isReady => _ready;

  @override
  String get currentModelId => modelId;

  @override
  Future<void> loadModel(String modelPath, {String? modelId}) async {
    _ready = true;
  }

  @override
  Stream<String> generate({
    required List<Map<String, String>> messages,
    double? temperature,
    int? maxTokens,
  }) async* {
    if (!_ready) {
      throw StateError('EchoBackend.generate called before loadModel');
    }
    final lastUser = messages.lastWhere(
      (m) => (m['role'] ?? '').toLowerCase() == 'user',
      orElse: () => const {'content': ''},
    );
    final text = (lastUser['content'] ?? '').toString();
    if (text.isEmpty) return;
    final reply = 'echo: $text';
    final cap = maxTokens != null && maxTokens > 0 && maxTokens < reply.length
        ? maxTokens
        : reply.length;
    var i = 0;
    while (i < cap) {
      final end = (i + chunkSize).clamp(0, cap);
      yield reply.substring(i, end);
      i = end;
      // Yield to the event loop so the HTTP layer can flush each chunk
      // before we produce the next one — keeps streaming snappy.
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }
}

/// Snapshot of a [BundledEngine]'s current state — what the UI binds to.
class BundledEngineSnapshot {
  const BundledEngineSnapshot({
    required this.isRunning,
    required this.isReady,
    required this.modelId,
    required this.endpoint,
    this.error,
  });

  final bool isRunning;
  final bool isReady;
  final String modelId;
  final String? endpoint;
  final String? error;

  bool get isStopped => !isRunning;
}

/// The user-facing "built-in inference engine".
///
/// Owns three things in concert:
///
///   1. An [InferenceBackend] (the actual inference primitives).
///   2. A loopback `HttpServer` that speaks an OpenAI-compatible subset
///      (`/v1/models`, `/v1/chat/completions` with `stream: true`) so
///      the rest of the app — `AiCommandService`, `OllamaClient`,
///      `LocalEngineHealthMonitor` — keeps using the same code paths
///      they already use for external engines.
///   3. A [Stream] of [BundledEngineSnapshot]s the UI subscribes to.
///
/// All HTTP traffic stays on `127.0.0.1` on an OS-assigned ephemeral
/// port. The endpoint is available as [endpoint] once [start] resolves.
///
/// This class is process-wide single-instance in production; see
/// [BundledEngineController] for the global handle. Instantiate
/// directly in tests.
class BundledEngine {
  BundledEngine({InferenceBackend? backend})
      : _backend = backend ?? LlamaServerBackend();

  final InferenceBackend _backend;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSub;
  final StreamController<BundledEngineSnapshot> _snapshots =
      StreamController<BundledEngineSnapshot>.broadcast();
  BundledEngineSnapshot _last = const BundledEngineSnapshot(
    isRunning: false,
    isReady: false,
    modelId: '',
    endpoint: null,
  );

  /// Whether the backing native runtime is even possible on this build.
  bool get isAvailable => _backend.isAvailable;

  /// Loopback URL once [start] completes. `null` while stopped.
  String? get endpoint => _server == null
      ? null
      : 'http://127.0.0.1:${_server!.port}';

  /// Latest snapshot (synchronously available; mirrors [snapshots]).
  BundledEngineSnapshot get snapshot => _last;

  /// Broadcast stream of state changes. The current snapshot is always
  /// the first event a new subscriber sees.
  Stream<BundledEngineSnapshot> get snapshots async* {
    yield _last;
    yield* _snapshots.stream;
  }

  void _emit(BundledEngineSnapshot s) {
    _last = s;
    if (!_snapshots.isClosed) _snapshots.add(s);
  }

  /// Load [modelPath] and start the loopback shim. Idempotent: calling
  /// twice tears down the previous server / model first.
  Future<void> start({
    required String modelPath,
    String? modelId,
  }) async {
    await stop();
    try {
      await _backend.loadModel(modelPath, modelId: modelId);
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _serverSub = _server!.listen(_handleRequest);
      _emit(BundledEngineSnapshot(
        isRunning: true,
        isReady: _backend.isReady,
        modelId: _backend.currentModelId,
        endpoint: endpoint,
      ));
    } catch (e) {
      await _teardown();
      _emit(BundledEngineSnapshot(
        isRunning: false,
        isReady: false,
        modelId: '',
        endpoint: null,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  /// Stop the shim and free the model. Safe to call when not running.
  Future<void> stop() async {
    if (_server == null && !_backend.isReady) return;
    await _teardown();
    _emit(const BundledEngineSnapshot(
      isRunning: false,
      isReady: false,
      modelId: '',
      endpoint: null,
    ));
  }

  Future<void> _teardown() async {
    await _serverSub?.cancel();
    _serverSub = null;
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {/* best-effort */}
    }
    try {
      await _backend.dispose();
    } catch (_) {/* swallow during teardown */}
  }

  /// Permanently dispose this instance. Use for tests; in production
  /// the controller keeps the engine alive for the app's lifetime.
  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
  }

  // ---- HTTP shim ------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest req) async {
    // Defence in depth: refuse anything that didn't arrive on
    // loopback. `bind(loopbackIPv4)` already enforces this at the
    // socket layer, but if a future change ever flips the bind, the
    // check below keeps the zero-trust guarantee.
    final remote = req.connectionInfo?.remoteAddress;
    if (remote != null && !remote.isLoopback) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/v1/models') {
        await _writeJson(req, {
          'object': 'list',
          'data': [
            {
              'id': _backend.currentModelId,
              'object': 'model',
              'owned_by': 'hamma-bundled',
            }
          ],
        });
        return;
      }
      if (req.method == 'GET' && path == '/api/version') {
        // Compatibility with `LocalEngineHealthMonitor`'s tier-1 probe.
        await _writeJson(req, {'version': 'bundled-1.0.0'});
        return;
      }
      if (req.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChatCompletions(req);
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(jsonEncode({'error': {'message': e.toString()}}));
        await req.response.close();
      } catch (_) {/* connection already gone */}
    }
  }

  static Future<void> _writeJson(HttpRequest req, Object body) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _handleChatCompletions(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected JSON object');
      }
      payload = decoded;
    } on FormatException catch (e) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.write(jsonEncode({
        'error': {'message': 'invalid request: $e'},
      }));
      await req.response.close();
      return;
    }

    final stream = (payload['stream'] == true);
    final temperature = _readDouble(payload['temperature']);
    final maxTokens = _readInt(payload['max_tokens']);
    final messages = _readMessages(payload['messages']);

    if (!stream) {
      // Synchronous path — gather the full reply, then return one
      // OpenAI-shaped object.
      final buf = StringBuffer();
      try {
        await for (final chunk in _backend.generate(
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
        )) {
          buf.write(chunk);
        }
      } catch (e) {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(jsonEncode({
          'error': {'message': e.toString()},
        }));
        await req.response.close();
        return;
      }
      await _writeJson(req, {
        'id': 'bundled-${DateTime.now().millisecondsSinceEpoch}',
        'object': 'chat.completion',
        'model': _backend.currentModelId,
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': buf.toString()},
            'finish_reason': 'stop',
          }
        ],
      });
      return;
    }

    // Streaming SSE.
    req.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.headers.set('Connection', 'keep-alive');

    final id = 'bundled-${DateTime.now().millisecondsSinceEpoch}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      await for (final chunk in _backend.generate(
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
      )) {
        if (chunk.isEmpty) continue;
        final event = jsonEncode({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': _backend.currentModelId,
          'choices': [
            {
              'index': 0,
              'delta': {'content': chunk},
              'finish_reason': null,
            }
          ],
        });
        req.response.write('data: $event\n\n');
        await req.response.flush();
      }
      final done = jsonEncode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': _backend.currentModelId,
        'choices': [
          {
            'index': 0,
            'delta': <String, Object?>{},
            'finish_reason': 'stop',
          }
        ],
      });
      req.response.write('data: $done\n\n');
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    } catch (e) {
      // Surface the error inline so the client gets a useful message
      // instead of a silently-truncated stream.
      try {
        final err = jsonEncode({
          'error': {'message': e.toString()},
        });
        req.response.write('data: $err\n\n');
        await req.response.close();
      } catch (_) {/* connection already gone */}
    }
  }

  // ---- payload coercion -----------------------------------------------------

  static List<Map<String, String>> _readMessages(Object? raw) {
    if (raw is! List) return const [];
    final out = <Map<String, String>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final role = (item['role'] as Object?)?.toString().trim() ?? '';
      final content = (item['content'] as Object?)?.toString() ?? '';
      if (role.isEmpty) continue;
      out.add({'role': role, 'content': content});
    }
    return out;
  }

  static double? _readDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static int? _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}
