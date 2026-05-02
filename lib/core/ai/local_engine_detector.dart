import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Inference engines Hamma knows how to identify on `localhost`.
enum LocalEngineKind {
  ollama,
  lmStudio,
  llamaCpp,
  jan,
  unknown,
}

extension LocalEngineKindLabel on LocalEngineKind {
  String get displayName {
    switch (this) {
      case LocalEngineKind.ollama:
        return 'Ollama';
      case LocalEngineKind.lmStudio:
        return 'LM Studio';
      case LocalEngineKind.llamaCpp:
        return 'llama.cpp';
      case LocalEngineKind.jan:
        return 'Jan';
      case LocalEngineKind.unknown:
        return 'Local engine';
    }
  }
}

class DetectedEngine {
  const DetectedEngine({
    required this.kind,
    required this.endpoint,
    this.version = '',
  });

  final LocalEngineKind kind;
  /// Base URL with no trailing slash, e.g. `http://localhost:11434`.
  final String endpoint;
  final String version;

  String get displayLabel {
    final v = version.isEmpty ? '' : ' · $version';
    return '${kind.displayName}$v';
  }
}

/// Probes well-known local inference engine ports on `127.0.0.1`.
///
/// Each probe is best-effort and short-timeout (≤2s default) so a full sweep
/// completes quickly even when nothing is listening. All requests are made
/// against loopback addresses; this service must never reach the public
/// internet.
class LocalEngineDetector {
  LocalEngineDetector({
    Duration probeTimeout = const Duration(seconds: 2),
    HttpClient Function()? httpClientFactory,
    String host = '127.0.0.1',
  })  : _probeTimeout = probeTimeout,
        _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _host = host;

  final Duration _probeTimeout;
  final HttpClient Function() _httpClientFactory;
  final String _host;

  /// Default port × engine map.
  static const List<({int port, LocalEngineKind kind})> defaultProbes = [
    (port: 11434, kind: LocalEngineKind.ollama),
    (port: 1234, kind: LocalEngineKind.lmStudio),
    (port: 8080, kind: LocalEngineKind.llamaCpp),
    (port: 1337, kind: LocalEngineKind.jan),
  ];

  /// Probe every well-known port in parallel and return the engines we
  /// found, in the same order as [defaultProbes].
  Future<List<DetectedEngine>> detect() async {
    final results = await Future.wait(
      defaultProbes.map((p) => _probe(p.kind, p.port)),
    );
    return results.whereType<DetectedEngine>().toList(growable: false);
  }

  /// Probe a single host:port and identify the engine if anything responds.
  /// Returns `null` when nothing is listening or the response can't be
  /// recognized as a known engine.
  Future<DetectedEngine?> probe({
    required LocalEngineKind kind,
    required int port,
  }) {
    return _probe(kind, port);
  }

  Future<DetectedEngine?> _probe(LocalEngineKind kind, int port) async {
    final client = _httpClientFactory();
    client.connectionTimeout = _probeTimeout;
    final endpoint = 'http://$_host:$port';
    try {
      switch (kind) {
        case LocalEngineKind.ollama:
          return await _probeOllama(client, endpoint);
        case LocalEngineKind.lmStudio:
        case LocalEngineKind.llamaCpp:
        case LocalEngineKind.jan:
        case LocalEngineKind.unknown:
          return await _probeOpenAiCompat(client, endpoint, kind);
      }
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<DetectedEngine?> _probeOllama(
    HttpClient client,
    String endpoint,
  ) async {
    try {
      final req = await client
          .getUrl(Uri.parse('$endpoint/api/version'))
          .timeout(_probeTimeout);
      final resp = await req.close().timeout(_probeTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      String version = '';
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          version = (decoded['version'] as String?)?.trim() ?? '';
        }
      } catch (_) {}
      return DetectedEngine(
        kind: LocalEngineKind.ollama,
        endpoint: endpoint,
        version: version,
      );
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// LM Studio, llama.cpp server, and Jan all expose an OpenAI-compatible
  /// `/v1/models` endpoint. Hitting that gives us a cheap "is something
  /// alive on this port?" probe.
  Future<DetectedEngine?> _probeOpenAiCompat(
    HttpClient client,
    String endpoint,
    LocalEngineKind kind,
  ) async {
    try {
      final req = await client
          .getUrl(Uri.parse('$endpoint/v1/models'))
          .timeout(_probeTimeout);
      final resp = await req.close().timeout(_probeTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return null;
      }
      await resp.drain<void>();
      return DetectedEngine(
        kind: kind,
        endpoint: endpoint,
      );
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
