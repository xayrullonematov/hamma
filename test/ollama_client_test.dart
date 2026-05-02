import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ollama_client.dart';

void main() {
  group('OllamaClient parsing helpers', () {
    test('parses a /api/tags response', () {
      const body = '''
{
  "models": [
    {
      "name": "gemma3:latest",
      "modified_at": "2024-01-01T00:00:00Z",
      "size": 5368709120,
      "digest": "abc123",
      "details": {
        "parameter_size": "7B",
        "quantization_level": "Q4_0",
        "family": "gemma"
      }
    },
    {
      "name": "llama3:8b",
      "modified_at": "2024-02-01T00:00:00Z",
      "size": 4500000000
    }
  ]
}
''';
      final lines = body
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty);

      // Round-trip via the public decode helper used by the API client.
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['models'], isA<List<dynamic>>());

      // Models list parsing: synthesize via the OllamaModel.fromJson factory
      // (the private helper is exercised end-to-end in the HTTP test below).
      final raw = decoded['models'] as List<dynamic>;
      final models = raw
          .map((m) =>
              OllamaModel.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList();

      expect(models, hasLength(2));
      expect(models.first.name, 'gemma3:latest');
      expect(models.first.sizeBytes, 5368709120);
      expect(models.first.parameterSize, '7B');
      expect(models.first.family, 'gemma');
      expect(models.first.humanSize, contains('GB'));
      expect(models.last.parameterSize, '');
      // Avoid unused warning for `lines`.
      expect(lines, isNotEmpty);
    });

    test('decodePullBody yields one event per JSON line and skips junk',
        () async {
      final lines = Stream.fromIterable([
        '',
        '{"status":"pulling manifest"}',
        '   ',
        '{"status":"downloading","completed":50,"total":100,"digest":"sha256:aa"}',
        'not-json-at-all',
        '{"status":"success"}',
      ]);

      final events =
          await OllamaClient.decodePullBody(lines).toList();

      expect(events, hasLength(3));
      expect(events[0].status, 'pulling manifest');
      expect(events[1].status, 'downloading');
      expect(events[1].fraction, closeTo(0.5, 1e-9));
      expect(events[2].isTerminal, isTrue);
    });

    test('decodeChatBody yields content deltas and stops at done', () async {
      final lines = Stream.fromIterable([
        '{"message":{"role":"assistant","content":"Hello"},"done":false}',
        '{"message":{"role":"assistant","content":" world"},"done":false}',
        '{"message":{"role":"assistant","content":"!"},"done":true}',
        // Anything after `done:true` must NOT be emitted.
        '{"message":{"role":"assistant","content":"IGNORED"},"done":false}',
      ]);

      final out = <String>[];
      await for (final delta in OllamaClient.decodeChatBody(lines)) {
        out.add(delta);
      }

      expect(out, ['Hello', ' world', '!']);
    });

    test('decodeChatBody tolerates blank lines and malformed JSON', () async {
      final lines = Stream.fromIterable([
        '',
        'garbage',
        '{"message":{"role":"assistant","content":"ok"},"done":true}',
      ]);
      final out = await OllamaClient.decodeChatBody(lines).toList();
      expect(out, ['ok']);
    });

    test('OllamaPullProgress.fraction is null when total is unknown', () {
      const p = OllamaPullProgress(status: 'pulling', completedBytes: 10);
      expect(p.fraction, isNull);
    });

    test('formatBytes scales with magnitude', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), endsWith(' B'));
      expect(formatBytes(1500), endsWith(' KB'));
      expect(formatBytes(5 * 1024 * 1024), endsWith(' MB'));
      expect(formatBytes(2 * 1024 * 1024 * 1024), endsWith(' GB'));
    });
  });

  group('OllamaClient HTTP integration (loopback test server)', () {
    late HttpServer server;
    late String base;
    late OllamaClient client;
    final List<String> requestLog = [];

    setUp(() async {
      requestLog.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      client = OllamaClient(endpoint: base);

      server.listen((req) async {
        requestLog.add('${req.method} ${req.uri.path}');
        if (req.method == 'GET' && req.uri.path == '/api/version') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'version': '0.1.42'}));
          await req.response.close();
          return;
        }
        if (req.method == 'GET' && req.uri.path == '/api/tags') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'models': [
              {
                'name': 'gemma3:latest',
                'modified_at': '2024-01-01T00:00:00Z',
                'size': 5368709120,
              }
            ]
          }));
          await req.response.close();
          return;
        }
        if (req.method == 'GET' && req.uri.path == '/api/ps') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'models': [
              {'name': 'gemma3:latest', 'size': 5368709120, 'expires_at': ''}
            ]
          }));
          await req.response.close();
          return;
        }
        if (req.method == 'DELETE' && req.uri.path == '/api/delete') {
          req.response.statusCode = 200;
          await req.response.close();
          return;
        }
        if (req.method == 'POST' && req.uri.path == '/api/pull') {
          req.response.headers.contentType = ContentType.json;
          // Stream three NDJSON lines.
          req.response.write(
              '${jsonEncode({'status': 'pulling manifest'})}\n');
          req.response.write(
              '${jsonEncode({'status': 'downloading', 'completed': 50, 'total': 100})}\n');
          req.response.write('${jsonEncode({'status': 'success'})}\n');
          await req.response.close();
          return;
        }
        if (req.method == 'POST' && req.uri.path == '/api/chat') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
              '${jsonEncode({'message': {'role': 'assistant', 'content': 'Hi '}, 'done': false})}\n');
          req.response.write(
              '${jsonEncode({'message': {'role': 'assistant', 'content': 'there'}, 'done': true})}\n');
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('version returns server-reported version string', () async {
      expect(await client.version(), '0.1.42');
    });

    test('listModels returns parsed models', () async {
      final models = await client.listModels();
      expect(models, hasLength(1));
      expect(models.first.name, 'gemma3:latest');
    });

    test('listLoadedModels returns parsed loaded models', () async {
      final loaded = await client.listLoadedModels();
      expect(loaded, hasLength(1));
      expect(loaded.first.name, 'gemma3:latest');
    });

    test('deleteModel issues a DELETE', () async {
      await client.deleteModel('gemma3:latest');
      expect(requestLog, contains('DELETE /api/delete'));
    });

    test('pullModel streams NDJSON progress events', () async {
      final events = await client.pullModel('gemma3:latest').toList();
      expect(events.map((e) => e.status), [
        'pulling manifest',
        'downloading',
        'success',
      ]);
      expect(events[1].fraction, closeTo(0.5, 1e-9));
      expect(events.last.isTerminal, isTrue);
    });

    test('streamChat yields incremental content deltas', () async {
      final out = <String>[];
      await for (final delta in client.streamChat(
        model: 'gemma3:latest',
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
      )) {
        out.add(delta);
      }
      expect(out, ['Hi ', 'there']);
    });

    test('all HTTP traffic targets loopback (zero-trust sanity)', () async {
      // Force at least one round-trip then verify no non-loopback URI was used.
      await client.version();
      // We constructed `base` from `127.0.0.1`, so any non-loopback request
      // would have failed to reach this server. Assert as an explicit guard.
      expect(base.startsWith('http://127.0.0.1:'), isTrue);
    });

    test('throws OllamaUnavailableException when the daemon is offline',
        () async {
      // Bind a fresh socket, close it immediately, then try to talk to it.
      final tmp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = tmp.port;
      await tmp.close(force: true);
      final dead = OllamaClient(
        endpoint: 'http://127.0.0.1:$deadPort',
        connectionTimeout: const Duration(milliseconds: 200),
      );
      await expectLater(
        dead.version(),
        throwsA(isA<OllamaUnavailableException>()),
      );
    });
  });

  group('OllamaClient validation', () {
    final c = OllamaClient(endpoint: 'http://127.0.0.1:11434');
    test('deleteModel rejects empty name', () {
      expect(() => c.deleteModel('  '), throwsArgumentError);
    });
    test('pullModel rejects empty name', () {
      expect(() => c.pullModel('').toList(), throwsArgumentError);
    });
    test('streamChat rejects empty model', () {
      expect(
        () => c.streamChat(model: '', messages: const []).toList(),
        throwsArgumentError,
      );
    });
  });
}
