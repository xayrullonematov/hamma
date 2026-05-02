import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thin native client for the Ollama HTTP API.
///
/// Used in addition to the OpenAI-compatible chat endpoint so that the
/// in-app model manager can list / pull / delete / inspect models without
/// leaving the app. Pure Dart, no Flutter dependency, fully unit-testable
/// via the [httpClientFactory] override.
class OllamaClient {
  /// Constructs a client and **enforces the zero-trust guarantee** that
  /// the configured endpoint points at loopback. Any attempt to talk
  /// to a non-loopback host (LAN IP, public DNS, etc.) throws an
  /// [ArgumentError] at construction time so a misconfigured endpoint
  /// can never accidentally exfiltrate prompts off-device.
  OllamaClient({
    required this.endpoint,
    HttpClient Function()? httpClientFactory,
    Duration? connectionTimeout,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _connectionTimeout = connectionTimeout ?? const Duration(seconds: 5) {
    if (!isLoopbackEndpoint(endpoint)) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Local AI endpoints must point at loopback (127.0.0.0/8, ::1, or '
            'localhost). Refusing to send prompts to a non-loopback host.',
      );
    }
  }

  /// Returns `true` when [url] parses to a host that is unambiguously
  /// loopback. Recognises `localhost`, IPv6 `::1` and any address in
  /// the IPv4 `127.0.0.0/8` block. Anything else (LAN IPs, public
  /// hostnames, malformed input) returns `false`.
  ///
  /// This is the central authority for the app's zero-trust guarantee
  /// — Settings, the runtime client, and the loopback test all share
  /// this implementation so they cannot drift apart.
  static bool isLoopbackEndpoint(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'localhost') return true;
    if (host == '::1' || host == '[::1]') return true;
    final addr = InternetAddress.tryParse(host);
    if (addr == null) return false;
    if (addr.type == InternetAddressType.IPv4) {
      // 127.0.0.0/8 is the entire loopback block.
      return addr.rawAddress.isNotEmpty && addr.rawAddress[0] == 127;
    }
    if (addr.type == InternetAddressType.IPv6) {
      return addr.isLoopback;
    }
    return false;
  }

  /// Base URL of the Ollama daemon, e.g. `http://localhost:11434`.
  /// No trailing slash.
  final String endpoint;
  final HttpClient Function() _httpClientFactory;
  final Duration _connectionTimeout;

  String get _normalizedEndpoint {
    var e = endpoint.trim();
    while (e.endsWith('/')) {
      e = e.substring(0, e.length - 1);
    }
    return e;
  }

  Uri _uri(String path) => Uri.parse('$_normalizedEndpoint$path');

  HttpClient _newClient() {
    final c = _httpClientFactory();
    c.connectionTimeout = _connectionTimeout;
    return c;
  }

  /// `GET /api/version` — used as a health probe.
  ///
  /// Throws [OllamaUnavailableException] on connection failure.
  Future<String> version() async {
    final client = _newClient();
    try {
      final req = await client
          .getUrl(_uri('/api/version'))
          .timeout(_connectionTimeout);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw OllamaApiException(
          'version request failed: HTTP ${resp.statusCode}',
        );
      }
      try {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        return (decoded['version'] as String?)?.trim() ?? '';
      } catch (_) {
        return '';
      }
    } on SocketException catch (e) {
      throw OllamaUnavailableException(e.message);
    } on TimeoutException {
      throw const OllamaUnavailableException('connection timed out');
    } finally {
      client.close(force: true);
    }
  }

  /// `GET /api/tags` — list locally installed models.
  Future<List<OllamaModel>> listModels() async {
    final client = _newClient();
    try {
      final req = await client
          .getUrl(_uri('/api/tags'))
          .timeout(_connectionTimeout);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw OllamaApiException(
          'listModels failed: HTTP ${resp.statusCode}',
        );
      }
      return _parseModelList(body);
    } on SocketException catch (e) {
      throw OllamaUnavailableException(e.message);
    } on TimeoutException {
      throw const OllamaUnavailableException('connection timed out');
    } finally {
      client.close(force: true);
    }
  }

  /// `GET /api/ps` — list models currently loaded into memory.
  Future<List<OllamaLoadedModel>> listLoadedModels() async {
    final client = _newClient();
    try {
      final req =
          await client.getUrl(_uri('/api/ps')).timeout(_connectionTimeout);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw OllamaApiException(
          'listLoadedModels failed: HTTP ${resp.statusCode}',
        );
      }
      return _parseLoadedModels(body);
    } on SocketException catch (e) {
      throw OllamaUnavailableException(e.message);
    } on TimeoutException {
      throw const OllamaUnavailableException('connection timed out');
    } finally {
      client.close(force: true);
    }
  }

  /// `DELETE /api/delete` — remove a model from disk.
  Future<void> deleteModel(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    final client = _newClient();
    try {
      final req = await client
          .deleteUrl(_uri('/api/delete'))
          .timeout(_connectionTimeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'name': trimmed}));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      // Drain so the connection can be released.
      await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw OllamaApiException(
          'deleteModel($trimmed) failed: HTTP ${resp.statusCode}',
        );
      }
    } on SocketException catch (e) {
      throw OllamaUnavailableException(e.message);
    } on TimeoutException {
      throw const OllamaUnavailableException('connection timed out');
    } finally {
      client.close(force: true);
    }
  }

  /// `POST /api/pull` — download a model. Streams [OllamaPullProgress]
  /// events until the model is fully pulled.
  ///
  /// The returned stream MUST be listened to; cancelling the subscription
  /// closes the underlying HTTP connection (best-effort cancel — Ollama
  /// continues the pull on the server side, but the client stops reading).
  Stream<OllamaPullProgress> pullModel(String name) async* {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    final client = _newClient();
    HttpClientResponse? resp;
    try {
      final req = await client
          .postUrl(_uri('/api/pull'))
          .timeout(_connectionTimeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'name': trimmed, 'stream': true}));
      resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final body = await resp.transform(utf8.decoder).join();
        throw OllamaApiException(
          'pullModel($trimmed) failed: HTTP ${resp.statusCode} $body',
        );
      }
      yield* _decodePullStream(resp);
    } on SocketException catch (e) {
      throw OllamaUnavailableException(e.message);
    } on TimeoutException {
      throw const OllamaUnavailableException('connection timed out');
    } finally {
      client.close(force: true);
    }
  }

  /// `POST /api/chat` — streamed chat completion.
  ///
  /// Yields the incremental message deltas (typically one or a few tokens
  /// per chunk). The stream completes when the server signals `done: true`.
  Stream<String> streamChat({
    required String model,
    required List<Map<String, String>> messages,
    double? temperature,
  }) async* {
    final trimmedModel = model.trim();
    if (trimmedModel.isEmpty) {
      throw ArgumentError.value(model, 'model', 'must not be empty');
    }
    final client = _newClient();
    HttpClientResponse? resp;
    try {
      final req = await client
          .postUrl(_uri('/api/chat'))
          .timeout(_connectionTimeout);
      req.headers.contentType = ContentType.json;
      final body = <String, dynamic>{
        'model': trimmedModel,
        'messages': messages,
        'stream': true,
        if (temperature != null) 'options': {'temperature': temperature},
      };
      req.write(jsonEncode(body));
      resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final errBody = await resp.transform(utf8.decoder).join();
        throw OllamaApiException(
          'streamChat failed: HTTP ${resp.statusCode} $errBody',
        );
      }
      yield* _decodeChatStream(resp);
    } on SocketException catch (e) {
      throw OllamaUnavailableException(e.message);
    } on TimeoutException {
      throw const OllamaUnavailableException('connection timed out');
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Parsing helpers — split out as static so they can be unit-tested without
  // touching HTTP.
  // ---------------------------------------------------------------------------

  static List<OllamaModel> _parseModelList(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];
      final raw = decoded['models'];
      if (raw is! List) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => OllamaModel.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static List<OllamaLoadedModel> _parseLoadedModels(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];
      final raw = decoded['models'];
      if (raw is! List) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => OllamaLoadedModel.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Decodes Ollama's pull response, which is one JSON object per line
  /// (newline-delimited JSON). Skips blank lines and malformed entries.
  static Stream<OllamaPullProgress> decodePullBody(Stream<String> lines) async* {
    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          yield OllamaPullProgress.fromJson(decoded);
        }
      } on FormatException {
        // skip malformed line; do not abort the stream
      }
    }
  }

  /// Decodes Ollama's chat response (NDJSON). Yields each non-empty
  /// `message.content` delta. Stops when `done: true`.
  static Stream<String> decodeChatBody(Stream<String> lines) async* {
    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, dynamic>) continue;
        final message = decoded['message'];
        if (message is Map) {
          final content = message['content'];
          if (content is String && content.isNotEmpty) {
            yield content;
          }
        }
        if (decoded['done'] == true) {
          return;
        }
      } on FormatException {
        continue;
      }
    }
  }

  Stream<OllamaPullProgress> _decodePullStream(HttpClientResponse resp) {
    return decodePullBody(_byteStreamToLines(resp));
  }

  Stream<String> _decodeChatStream(HttpClientResponse resp) {
    return decodeChatBody(_byteStreamToLines(resp));
  }

  static Stream<String> _byteStreamToLines(Stream<List<int>> source) {
    return source.transform(utf8.decoder).transform(const LineSplitter());
  }
}

/// Thrown when the Ollama daemon is not reachable (offline, wrong port,
/// network blocked). Distinct from [OllamaApiException], which means we
/// reached the server but it returned an error.
class OllamaUnavailableException implements Exception {
  const OllamaUnavailableException(this.message);
  final String message;
  @override
  String toString() => 'OllamaUnavailable: $message';
}

class OllamaApiException implements Exception {
  const OllamaApiException(this.message);
  final String message;
  @override
  String toString() => 'OllamaApi: $message';
}

/// A model installed on the local Ollama daemon.
class OllamaModel {
  const OllamaModel({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    this.digest = '',
    this.parameterSize = '',
    this.quantization = '',
    this.family = '',
  });

  factory OllamaModel.fromJson(Map<String, dynamic> json) {
    final details = (json['details'] as Map?) ?? const {};
    return OllamaModel(
      name: (json['name'] as String?)?.trim() ?? '',
      sizeBytes: _readInt(json['size']),
      modifiedAt: (json['modified_at'] as String?)?.trim() ?? '',
      digest: (json['digest'] as String?)?.trim() ?? '',
      parameterSize: (details['parameter_size'] as String?)?.trim() ?? '',
      quantization: (details['quantization_level'] as String?)?.trim() ?? '',
      family: (details['family'] as String?)?.trim() ?? '',
    );
  }

  final String name;
  final int sizeBytes;
  final String modifiedAt;
  final String digest;
  final String parameterSize;
  final String quantization;
  final String family;

  String get humanSize => formatBytes(sizeBytes);
}

/// A model currently held in RAM by the Ollama daemon.
class OllamaLoadedModel {
  const OllamaLoadedModel({
    required this.name,
    required this.sizeBytes,
    this.expiresAt = '',
  });

  factory OllamaLoadedModel.fromJson(Map<String, dynamic> json) {
    return OllamaLoadedModel(
      name: (json['name'] as String?)?.trim() ?? '',
      sizeBytes: _readInt(json['size']),
      expiresAt: (json['expires_at'] as String?)?.trim() ?? '',
    );
  }

  final String name;
  final int sizeBytes;
  final String expiresAt;
}

/// A single progress event emitted while pulling a model.
class OllamaPullProgress {
  const OllamaPullProgress({
    required this.status,
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.digest = '',
  });

  factory OllamaPullProgress.fromJson(Map<String, dynamic> json) {
    return OllamaPullProgress(
      status: (json['status'] as String?)?.trim() ?? '',
      completedBytes: _readInt(json['completed']),
      totalBytes: _readInt(json['total']),
      digest: (json['digest'] as String?)?.trim() ?? '',
    );
  }

  final String status;
  final int completedBytes;
  final int totalBytes;
  final String digest;

  /// 0.0 .. 1.0 when total is known; otherwise null.
  double? get fraction {
    if (totalBytes <= 0) return null;
    final f = completedBytes / totalBytes;
    if (f.isNaN || f.isInfinite) return null;
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }

  bool get isTerminal {
    final s = status.toLowerCase();
    return s == 'success' || s == 'done';
  }
}

int _readInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

/// Format bytes as a short human string. Public so the UI layer can reuse.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final fixed = size >= 100 ? 0 : (size >= 10 ? 1 : 2);
  return '${size.toStringAsFixed(fixed)} ${units[unit]}';
}
