import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'inference_engine.dart';
import 'llama_server_backend.dart';

/// Pluggable inference backend the [BundledEngine] talks to.
///
/// The production implementation is [LlamaServerBackend] (in
/// `llama_server_backend.dart`), which spawns the upstream
/// `llama-server` binary as a child process and proxies requests to
/// it over loopback HTTP. Tests inject [EchoBackend] (or another
/// custom fake) so the HTTP shim, the streaming protocol and the
/// onboarding wiring can all be exercised without a native binary.
/// [LlamaCppBackend] (FFI) is kept as a primary path for mobile.
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

/// Backend that talks to `libllama` directly via FFI using [InferenceEngine].
/// Primary path for mobile (Android/iOS) where spawning subprocesses is restricted.
class LlamaCppBackend implements InferenceBackend {
  LlamaCppBackend();

  final InferenceEngine _engine = const InferenceEngine();

  String _modelId = '';
  String _modelPath = '';
  bool _modelLoaded = false;

  @override
  bool get isAvailable {
    // InferenceEngine is now available on all platforms via llama_cpp_dart.
    return !kIsWeb;
  }

  @override
  bool get isReady => _modelLoaded;

  @override
  String get currentModelId => _modelId;

  @override
  Future<void> loadModel(String modelPath, {String? modelId}) async {
    if (!File(modelPath).existsSync()) {
      throw StateError('Model file not found: $modelPath');
    }
    
    // We try to load the model. This will throw if the native library is missing.
    try {
      await _engine.loadModel(modelPath);
    } catch (e) {
      throw StateError('Failed to load local inference model: $e');
    }

    _modelPath = modelPath;
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
  }) {
    if (!_modelLoaded) {
      throw StateError('LlamaCppBackend.generate called before loadModel');
    }

    // Convert chat messages to a single prompt.
    // In a real implementation, we would use a proper chat template for the model.
    final prompt = '${messages.map((m) => '${m['role']}: ${m['content']}').join('\n')}\nassistant:';

    return _engine.streamResponse(prompt, _modelPath);
  }

  @override
  Future<void> dispose() async {
    await _engine.dispose();
    _modelLoaded = false;
    _modelId = '';
    _modelPath = '';
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

  /// Start the loopback server and load [modelPath]. Throws on failure.
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
    } catch (_) {/* best-effort */}
  }

  /// Frees all resources.
  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
  }

  // ---- HTTP logic -----------------------------------------------------------

  void _handleRequest(HttpRequest req) {
    if (req.method == 'GET' && req.uri.path == '/v1/models') {
      _handleListModels(req);
    } else if (req.method == 'POST' && req.uri.path == '/v1/chat/completions') {
      _handleChatCompletions(req);
    } else {
      req.response.statusCode = HttpStatus.notFound;
      req.response.close();
    }
  }

  void _handleListModels(HttpRequest req) {
    final payload = {
      'object': 'list',
      'data': [
        {
          'id': _backend.currentModelId,
          'object': 'model',
          'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'owned_by': 'hamma-bundled',
        }
      ],
    };
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(payload));
    req.response.close();
  }

  Future<void> _handleChatCompletions(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.close();
      return;
    }

    final messages = _readMessages(decoded['messages']);
    final temperature = _readDouble(decoded['temperature']) ?? 0.7;
    final maxTokens = _readInt(decoded['max_tokens']);
    final stream = decoded['stream'] == true;

    if (!stream) {
      // Non-streaming fallback for simple clients.
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
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
        return;
      }

      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'id': 'bundled-${DateTime.now().millisecondsSinceEpoch}',
        'object': 'chat.completion',
        'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'model': _backend.currentModelId,
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': buf.toString()},
            'finish_reason': 'stop',
          }
        ],
      }));
      await req.response.close();
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
