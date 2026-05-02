import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bundled_engine.dart';

/// Production [InferenceBackend] implementation backed by upstream
/// llama.cpp's `llama-server` binary, spawned as a child process.
///
/// Why a subprocess instead of FFI?
///
///   * `llama-server` is upstream's blessed embedding story — a single
///     ~5 MB statically-linked binary that already speaks an
///     OpenAI-compatible HTTP API, including streaming. No FFI struct
///     ABI to keep in lock-step with upstream releases.
///   * Process isolation: a model crash (CUDA OOM, mmap fault, native
///     assert) takes down only the subprocess, not Hamma.
///   * Per-OS build matrix collapses: we ship one statically-linked
///     binary per platform instead of a shared library plus all its
///     transitive deps.
///   * End-to-end testability: a [LlamaServerLauncher] can be injected
///     so tests run against a Dart-side fake without needing the real
///     binary present.
///
/// The [BundledEngine] HTTP shim still wraps this backend, so the rest
/// of the app keeps using the existing OpenAI-compatible plumbing
/// (`AiCommandService._chatWithOpenAi`, `LocalEngineHealthMonitor`,
/// `LocalEngineDetector`). When a request arrives at the shim, the
/// backend forwards it to the spawned `llama-server` and streams the
/// reply back — adding one localhost-to-localhost hop (microseconds).
class LlamaServerBackend implements InferenceBackend {
  LlamaServerBackend({
    String? binaryPath,
    LlamaServerLauncher? launcher,
    HttpClient Function()? httpClientFactory,
    Duration startupTimeout = const Duration(seconds: 60),
    Duration killGracePeriod = const Duration(seconds: 3),
    int contextSize = 4096,
  })  : _explicitBinaryPath = binaryPath,
        _launcher = launcher ?? _spawnRealLlamaServer,
        _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _startupTimeout = startupTimeout,
        _killGracePeriod = killGracePeriod,
        _contextSize = contextSize;

  final String? _explicitBinaryPath;
  final LlamaServerLauncher _launcher;
  final HttpClient Function() _httpClientFactory;
  final Duration _startupTimeout;
  final Duration _killGracePeriod;
  final int _contextSize;

  LlamaServerHandle? _handle;
  String _modelId = '';
  bool _ready = false;

  /// Resolve the side-car binary path. Tests can pass a fixed path via
  /// the constructor; production looks next to the executable
  /// (Flutter desktop bundles `lib/`-adjacent assets that way).
  String get binaryPath => _explicitBinaryPath ?? _defaultBinaryPath();

  static String _defaultBinaryPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final exeName = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
    // First look at the canonical Flutter bundle layout, then fall
    // back to next-to-the-executable for Windows / macOS.
    final candidates = <String>[
      // Linux: <bundle>/lib/llama-server
      '$exeDir${Platform.pathSeparator}lib${Platform.pathSeparator}$exeName',
      // Linux/macOS/Windows: directly next to the binary
      '$exeDir${Platform.pathSeparator}$exeName',
      // macOS .app: Contents/Frameworks/
      '$exeDir${Platform.pathSeparator}..${Platform.pathSeparator}'
          'Frameworks${Platform.pathSeparator}$exeName',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    // Return the first candidate so the failure mode is "file not
    // found" with a meaningful path the user can grep for.
    return candidates.first;
  }

  @override
  bool get isAvailable => File(binaryPath).existsSync();

  @override
  bool get isReady => _ready;

  @override
  String get currentModelId => _modelId;

  /// Endpoint of the spawned `llama-server` (loopback). `null` when
  /// the backend is stopped. Useful for tests that want to talk to
  /// the upstream server directly.
  String? get spawnedEndpoint => _handle?.endpoint;

  @override
  Future<void> loadModel(String modelPath, {String? modelId}) async {
    if (!isAvailable) {
      throw StateError(
        'llama-server binary not found at $binaryPath. Drop the '
        'platform binary into native/<os>/ and rebuild — see '
        'native/README.md.',
      );
    }
    final resolvedBinary = binaryPath;
    if (!File(modelPath).existsSync()) {
      throw StateError('Model file not found: $modelPath');
    }
    // If a previous spawn is still around, tear it down first.
    await _shutdownProcess();

    final handle = await _launcher(
      binaryPath: resolvedBinary,
      modelPath: modelPath,
      contextSize: _contextSize,
    );
    _handle = handle;
    try {
      await _waitForReady(handle.endpoint).timeout(_startupTimeout);
    } catch (e) {
      await _shutdownProcess();
      throw StateError('llama-server did not become ready: $e');
    }
    _ready = true;
    _modelId = modelId?.trim().isNotEmpty == true
        ? modelId!.trim()
        : _deriveModelId(modelPath);
  }

  static String _deriveModelId(String path) {
    final fname = path.split(RegExp(r'[/\\]')).last;
    return fname.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '');
  }

  /// Poll `/v1/models` (or the supplied custom path) on the spawned
  /// server until it answers 200, or the configured timeout elapses.
  Future<void> _waitForReady(String endpoint) async {
    final deadline = DateTime.now().add(_startupTimeout);
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      final client = _httpClientFactory();
      try {
        final req = await client
            .getUrl(Uri.parse('$endpoint/v1/models'))
            .timeout(const Duration(seconds: 2));
        final resp = await req.close().timeout(const Duration(seconds: 2));
        await resp.drain<void>();
        if (resp.statusCode == 200) return;
      } catch (_) {
        // Server not up yet — keep polling.
      } finally {
        client.close(force: true);
      }
      // Quick exponential-ish backoff capped at 500ms so we don't busy-spin
      // but also don't add seconds to startup on a fast machine.
      final delay = Duration(milliseconds: (50 * attempt).clamp(50, 500));
      await Future<void>.delayed(delay);
    }
    throw TimeoutException('llama-server health probe never returned 200');
  }

  @override
  Stream<String> generate({
    required List<Map<String, String>> messages,
    double? temperature,
    int? maxTokens,
  }) async* {
    final handle = _handle;
    if (!_ready || handle == null) {
      throw StateError('LlamaServerBackend.generate called before loadModel');
    }
    final client = _httpClientFactory();
    HttpClientResponse? resp;
    try {
      final req = await client.postUrl(
        Uri.parse('${handle.endpoint}/v1/chat/completions'),
      );
      req.headers.contentType = ContentType.json;
      final payload = <String, dynamic>{
        'model': _modelId,
        'stream': true,
        'messages': messages,
      };
      if (temperature != null) payload['temperature'] = temperature;
      if (maxTokens != null && maxTokens > 0) {
        payload['max_tokens'] = maxTokens;
      }
      req.write(jsonEncode(payload));
      resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final body = await resp.transform(utf8.decoder).join();
        throw StateError(
          'llama-server returned ${resp.statusCode}: $body',
        );
      }
      // Decode SSE: lines of "data: <json>" separated by blank lines,
      // terminated by "data: [DONE]". Keep this parser tiny — the
      // OpenAI delta shape is well-known.
      final lines =
          resp.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        try {
          final obj = jsonDecode(payload);
          if (obj is! Map) continue;
          final choices = obj['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'];
          if (delta is! Map) continue;
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            yield content;
          }
        } catch (_) {
          // Malformed event from the server — skip rather than tear
          // down the whole generation.
          continue;
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
    _modelId = '';
    await _shutdownProcess();
  }

  Future<void> _shutdownProcess() async {
    final h = _handle;
    _handle = null;
    if (h == null) return;
    try {
      await h.kill(grace: _killGracePeriod);
    } catch (_) {
      // Best effort — if the process is already gone, that's fine.
    }
  }
}

/// Opaque handle to a spawned `llama-server` process.
///
/// Hidden behind an interface so tests can inject a Dart-side fake
/// (no real subprocess) without touching the rest of the backend.
abstract class LlamaServerHandle {
  /// Loopback URL the spawned server is listening on. Stable for the
  /// lifetime of the process.
  String get endpoint;

  /// Send SIGTERM and wait up to [grace] for clean shutdown. If the
  /// process is still alive after [grace], escalate to SIGKILL.
  /// Idempotent — safe to call when the process is already dead.
  Future<void> kill({Duration grace = const Duration(seconds: 3)});

  /// Resolves with the process exit code once it dies.
  Future<int> get exitCode;
}

/// Function that knows how to spawn `llama-server` (or a fake stand-in
/// in tests) and return a [LlamaServerHandle].
typedef LlamaServerLauncher = Future<LlamaServerHandle> Function({
  required String binaryPath,
  required String modelPath,
  required int contextSize,
});

/// Default launcher: invokes the real binary as a child process,
/// binding it to an OS-assigned ephemeral loopback port.
Future<LlamaServerHandle> _spawnRealLlamaServer({
  required String binaryPath,
  required String modelPath,
  required int contextSize,
}) async {
  // Reserve an ephemeral port the same way `BundledEngine` does:
  // bind, read .port, then close so the child can re-bind. There's a
  // small TOCTOU window but llama-server's startup is fast enough
  // that collisions are extremely rare in practice.
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();

  final args = <String>[
    '--model', modelPath,
    '--ctx-size', '$contextSize',
    '--host', '127.0.0.1',
    '--port', '$port',
    // Keep llama-server quiet on stdout — we don't ship a log viewer.
    '--log-disable',
  ];
  final proc = await Process.start(
    binaryPath,
    args,
    mode: ProcessStartMode.detachedWithStdio,
    runInShell: false,
  );
  // Drain stdout/stderr to a /dev/null sink so the pipes don't fill
  // up and block the child after a few hundred MB of model-load
  // chatter.
  unawaited(proc.stdout.drain<void>().catchError((_) {}));
  unawaited(proc.stderr.drain<void>().catchError((_) {}));

  return _RealLlamaServerHandle(
    proc: proc,
    endpoint: 'http://127.0.0.1:$port',
  );
}

class _RealLlamaServerHandle implements LlamaServerHandle {
  _RealLlamaServerHandle({required Process proc, required this.endpoint})
      : _proc = proc;

  final Process _proc;
  @override
  final String endpoint;
  bool _killed = false;

  @override
  Future<int> get exitCode => _proc.exitCode;

  @override
  Future<void> kill({Duration grace = const Duration(seconds: 3)}) async {
    if (_killed) return;
    _killed = true;
    _proc.kill(ProcessSignal.sigterm);
    try {
      await _proc.exitCode.timeout(grace);
    } on TimeoutException {
      _proc.kill(ProcessSignal.sigkill);
      await _proc.exitCode;
    }
  }
}
