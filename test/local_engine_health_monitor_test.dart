import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/local_engine_health_monitor.dart';

/// In-process loopback HTTP server stand-in for various local AI engines.
///
/// Configurable per-test:
///  - [ollamaVersion]:        when non-null, `/api/version` returns this.
///  - [ollamaLoadedModels]:   `/api/ps` body — null means 404.
///  - [openAiModels]:         when non-null, `/v1/models` returns these ids.
///  - [requestLog]:           paths the test can assert against.
class _FakeEngineServer {
  _FakeEngineServer({
    this.ollamaVersion,
    this.ollamaLoadedModels,
    this.openAiModels,
  });

  String? ollamaVersion;
  List<String>? ollamaLoadedModels;
  List<String>? openAiModels;
  final List<String> requestLog = [];

  HttpServer? _server;

  String get endpoint => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _handle(HttpRequest req) {
    requestLog.add(req.uri.path);
    final res = req.response;
    final path = req.uri.path;
    if (path == '/api/version' && ollamaVersion != null) {
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'version': ollamaVersion}));
      res.close();
      return;
    }
    if (path == '/api/ps' && ollamaLoadedModels != null) {
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'models': ollamaLoadedModels!
            .map((n) => {
                  'name': n,
                  'size': 1,
                  'size_vram': 1,
                  'expires_at': '',
                })
            .toList(),
      }));
      res.close();
      return;
    }
    if (path == '/v1/models' && openAiModels != null) {
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'data': openAiModels!
            .map((id) => {'id': id, 'object': 'model'})
            .toList(),
      }));
      res.close();
      return;
    }
    res.statusCode = HttpStatus.notFound;
    res.close();
  }
}

void main() {
  group('LocalEngineHealthMonitor', () {
    late _FakeEngineServer server;
    late LocalEngineHealthMonitor monitor;

    tearDown(() async {
      await monitor.dispose();
      await server.stop();
    });

    test('reports online + loaded model name when Ollama is healthy', () async {
      server = _FakeEngineServer(
        ollamaVersion: '0.6.4',
        ollamaLoadedModels: ['gemma3:latest'],
      );
      await server.start();
      monitor = LocalEngineHealthMonitor(
        endpoint: server.endpoint,
        interval: const Duration(seconds: 30),
      );

      final h = await monitor.probeNow();
      expect(h.status, LocalEngineHealthStatus.online);
      expect(h.version, '0.6.4');
      expect(h.loadedModels, ['gemma3:latest']);
      expect(h.isReachable, isTrue);
    });

    test('reports loadingModel when engine is up but no model is warm',
        () async {
      server = _FakeEngineServer(
        ollamaVersion: '0.6.4',
        ollamaLoadedModels: const [],
      );
      await server.start();
      monitor = LocalEngineHealthMonitor(
        endpoint: server.endpoint,
        interval: const Duration(seconds: 30),
      );

      final h = await monitor.probeNow();
      expect(h.status, LocalEngineHealthStatus.loadingModel);
      expect(h.version, '0.6.4');
      expect(h.loadedModels, isEmpty);
      expect(h.isReachable, isTrue);
      expect(h.isOnline, isFalse);
    });

    test('falls back to OpenAI-compat /v1/models when Ollama is not present',
        () async {
      server = _FakeEngineServer(
        openAiModels: ['lmstudio-community/llama-3-8b-instruct'],
      );
      await server.start();
      monitor = LocalEngineHealthMonitor(
        endpoint: server.endpoint,
        interval: const Duration(seconds: 30),
      );

      final h = await monitor.probeNow();
      expect(h.status, LocalEngineHealthStatus.online);
      expect(h.loadedModels, isNotEmpty);
      expect(h.loadedModels.first,
          'lmstudio-community/llama-3-8b-instruct');
      // We must have actually called /v1/models, not just /api/version.
      expect(server.requestLog, contains('/v1/models'));
    });

    test('reports offline when neither Ollama nor OpenAI-compat answer',
        () async {
      server = _FakeEngineServer();
      await server.start();
      monitor = LocalEngineHealthMonitor(
        endpoint: server.endpoint,
        interval: const Duration(seconds: 30),
      );

      final h = await monitor.probeNow();
      expect(h.status, LocalEngineHealthStatus.offline);
      expect(h.error, isNotNull);
      expect(h.isReachable, isFalse);
    });

    test('emits initial loading event then a real probe event', () async {
      server = _FakeEngineServer(
        ollamaVersion: '0.6.4',
        ollamaLoadedModels: ['gemma3'],
      );
      await server.start();
      monitor = LocalEngineHealthMonitor(
        endpoint: server.endpoint,
        interval: const Duration(seconds: 30),
      );

      final events = <LocalEngineHealth>[];
      final sub = monitor.watch().listen(events.add);
      // Wait long enough for the immediate post-onListen probe to land.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(events.first.status, LocalEngineHealthStatus.loading);
      expect(events.last.status, LocalEngineHealthStatus.online);
      expect(events.last.loadedModels, ['gemma3']);
    });

    test('deduplicates concurrent probes through _inflight', () async {
      var versionCalls = 0;
      server = _FakeEngineServer(
        ollamaVersion: '0.6.4',
        ollamaLoadedModels: const [],
      );
      await server.start();
      // Wrap the request handler to count /api/version calls.
      final originalLog = server.requestLog;
      // Fire several concurrent probes; they should all resolve to the
      // same Future and we should see at most one `/api/version` call.
      monitor = LocalEngineHealthMonitor(
        endpoint: server.endpoint,
        interval: const Duration(seconds: 30),
      );

      final futures = List.generate(5, (_) => monitor.probeNow());
      final results = await Future.wait(futures);
      for (final r in results) {
        expect(r.status, LocalEngineHealthStatus.loadingModel);
      }
      versionCalls =
          originalLog.where((p) => p == '/api/version').length;
      expect(versionCalls, 1,
          reason: 'concurrent probeNow() calls must coalesce into one');
    });
  });
}
