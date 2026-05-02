import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/bundled_engine.dart';
import 'package:hamma/core/ai/llama_server_backend.dart';

/// Spin up a Dart `HttpServer` that mimics `llama-server`'s
/// OpenAI-compatible surface, plus a fake [LlamaServerHandle] that
/// shuts it down on `kill()`. Used by every test below — keeps the
/// suite fully hermetic (no real subprocess required).
Future<({HttpServer server, LlamaServerHandle handle})>
    _spawnFakeLlamaServer({
  String reply = 'pong',
  int statusCode = 200,
  Duration startupDelay = Duration.zero,
  bool malformedSse = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  if (startupDelay > Duration.zero) {
    // Defer accepting connections so the readiness probe has to retry
    // a few times before succeeding — covers the polling path.
    await Future<void>.delayed(startupDelay);
  }
  server.listen((req) async {
    final path = req.uri.path;
    if (req.method == 'GET' && path == '/v1/models') {
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'object': 'list',
        'data': [
          {'id': 'fake-model', 'object': 'model'}
        ],
      }));
      await req.response.close();
      return;
    }
    if (req.method == 'POST' && path == '/v1/chat/completions') {
      if (statusCode != 200) {
        req.response.statusCode = statusCode;
        req.response.write('upstream error');
        await req.response.close();
        return;
      }
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      // Drain the request body so we don't leave an open pipe.
      await req.cast<List<int>>().transform(utf8.decoder).join();
      if (malformedSse) {
        req.response.write('garbage that is not SSE\n\n');
        await req.response.close();
        return;
      }
      // Yield three small chunks then [DONE].
      for (final piece in [reply.substring(0, 1), reply.substring(1)]) {
        req.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': piece},
                  'finish_reason': null,
                }
              ],
            })}\n\n');
        await req.response.flush();
      }
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
      return;
    }
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  });
  final handle = _FakeServerHandle(server: server);
  return (server: server, handle: handle);
}

class _FakeServerHandle implements LlamaServerHandle {
  _FakeServerHandle({required HttpServer server})
      : _server = server,
        endpoint = 'http://127.0.0.1:${server.port}';

  final HttpServer _server;
  final Completer<int> _exit = Completer<int>();
  bool _killed = false;

  @override
  final String endpoint;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> kill({Duration grace = const Duration(seconds: 3)}) async {
    if (_killed) return;
    _killed = true;
    await _server.close(force: true);
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

void main() {
  group('LlamaServerBackend (with injected launcher)', () {
    late Directory tmp;
    late File modelFile;
    late File fakeBinary;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hamma_lsb_');
      modelFile = File('${tmp.path}/m.gguf')..writeAsBytesSync(const [0]);
      // The launcher is mocked, but isAvailable still checks the
      // binary path on disk — give it a real file to find.
      fakeBinary = File('${tmp.path}/llama-server-fake');
      fakeBinary.writeAsBytesSync(const [0]);
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('isAvailable reflects whether the binary exists on disk', () {
      final present = LlamaServerBackend(binaryPath: fakeBinary.path);
      expect(present.isAvailable, isTrue);
      final absent = LlamaServerBackend(binaryPath: '${tmp.path}/missing');
      expect(absent.isAvailable, isFalse);
    });

    test('loadModel throws when the binary path does not exist',
        () async {
      final backend = LlamaServerBackend(binaryPath: '${tmp.path}/missing');
      await expectLater(
        backend.loadModel(modelFile.path),
        throwsA(isA<StateError>()),
      );
    });

    test('loadModel throws when the model file does not exist', () async {
      final backend = LlamaServerBackend(binaryPath: fakeBinary.path);
      await expectLater(
        backend.loadModel('${tmp.path}/no-such-model.gguf'),
        throwsA(isA<StateError>()),
      );
    });

    test('loadModel waits for /v1/models to answer 200 before declaring ready',
        () async {
      // 200ms startup delay → readiness poll has to retry.
      final spawned = await _spawnFakeLlamaServer(
        startupDelay: const Duration(milliseconds: 200),
      );
      addTearDown(() async => spawned.handle.kill());
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            spawned.handle,
        startupTimeout: const Duration(seconds: 3),
      );
      addTearDown(backend.dispose);
      await backend.loadModel(modelFile.path, modelId: 'fake-model');
      expect(backend.isReady, isTrue);
      expect(backend.currentModelId, 'fake-model');
      expect(backend.spawnedEndpoint, spawned.handle.endpoint);
    });

    test('loadModel times out and tears down when the server never comes up',
        () async {
      // A handle whose endpoint points at a bound-but-unresponsive
      // server that never returns 200.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => dead.close());
      var killed = false;
      final handle = _ManualHandle(
        endpoint: 'http://127.0.0.1:${dead.port}',
        onKill: () => killed = true,
      );
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            handle,
        startupTimeout: const Duration(milliseconds: 600),
      );
      await expectLater(
        backend.loadModel(modelFile.path),
        throwsA(isA<StateError>()),
      );
      expect(killed, isTrue,
          reason: 'failed startup must tear down the spawned process');
      expect(backend.isReady, isFalse);
    });

    test('generate proxies POSTs to the spawned server and yields deltas',
        () async {
      final spawned = await _spawnFakeLlamaServer(reply: 'hi');
      addTearDown(() async => spawned.handle.kill());
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            spawned.handle,
      );
      addTearDown(backend.dispose);
      await backend.loadModel(modelFile.path);
      final out = await backend
          .generate(messages: const [
            {'role': 'user', 'content': 'ping'},
          ])
          .toList();
      expect(out.join(), 'hi');
    });

    test('generate surfaces upstream HTTP errors as StateError', () async {
      final spawned = await _spawnFakeLlamaServer(statusCode: 500);
      addTearDown(() async => spawned.handle.kill());
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            spawned.handle,
      );
      addTearDown(backend.dispose);
      await backend.loadModel(modelFile.path);
      await expectLater(
        backend
            .generate(messages: const [
              {'role': 'user', 'content': 'x'},
            ])
            .toList(),
        throwsA(isA<StateError>()),
      );
    });

    test('generate ignores malformed SSE lines without crashing', () async {
      final spawned = await _spawnFakeLlamaServer(malformedSse: true);
      addTearDown(() async => spawned.handle.kill());
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            spawned.handle,
      );
      addTearDown(backend.dispose);
      await backend.loadModel(modelFile.path);
      final out = await backend
          .generate(messages: const [
            {'role': 'user', 'content': 'x'},
          ])
          .toList();
      expect(out, isEmpty,
          reason: 'no valid deltas should be yielded for malformed SSE');
    });

    test('dispose kills the spawned process and clears state', () async {
      final spawned = await _spawnFakeLlamaServer();
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            spawned.handle,
      );
      await backend.loadModel(modelFile.path);
      expect(backend.isReady, isTrue);
      await backend.dispose();
      expect(backend.isReady, isFalse);
      expect(backend.currentModelId, isEmpty);
      // exitCode resolves once the fake handle is killed.
      expect(await spawned.handle.exitCode, 0);
    });

    test('loadModel called twice tears down the previous spawn', () async {
      final first = await _spawnFakeLlamaServer();
      final second = await _spawnFakeLlamaServer();
      addTearDown(() async => second.handle.kill());

      var nextHandle = first.handle;
      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            nextHandle,
      );
      addTearDown(backend.dispose);
      await backend.loadModel(modelFile.path);
      // First server should be torn down when we swap in the second.
      nextHandle = second.handle;
      await backend.loadModel(modelFile.path);
      expect(await first.handle.exitCode, 0,
          reason: 'previous spawn must die when loadModel is called again');
      expect(backend.spawnedEndpoint, second.handle.endpoint);
    });
  });

  group('BundledEngine ↔ LlamaServerBackend integration', () {
    test('end-to-end: BundledEngine HTTP shim → LlamaServerBackend → fake llama-server',
        () async {
      final tmp = await Directory.systemTemp.createTemp('hamma_e2e_');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
      final fakeBinary = File('${tmp.path}/llama-server-fake')
        ..writeAsBytesSync(const [0]);
      final modelFile = File('${tmp.path}/m.gguf')
        ..writeAsBytesSync(const [0]);
      final spawned = await _spawnFakeLlamaServer(reply: 'ok');
      addTearDown(() async => spawned.handle.kill());

      final backend = LlamaServerBackend(
        binaryPath: fakeBinary.path,
        launcher: ({required binaryPath, required modelPath, required contextSize}) async =>
            spawned.handle,
      );
      final engine = BundledEngine(backend: backend);
      addTearDown(engine.dispose);
      await engine.start(modelPath: modelFile.path, modelId: 'fake-model');

      // Hit the BundledEngine shim, not the fake server directly —
      // proves the whole proxy chain works end to end.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.postUrl(
        Uri.parse('${engine.endpoint!}/v1/chat/completions'),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': 'fake-model',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }));
      final resp = await req.close();
      expect(resp.statusCode, 200);
      final body = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final msg = (body['choices'] as List).first as Map;
      expect((msg['message'] as Map)['content'], 'ok');
    });
  });
}

/// A handle that just remembers if `kill()` was called — used for the
/// startup-timeout test.
class _ManualHandle implements LlamaServerHandle {
  _ManualHandle({required this.endpoint, required this.onKill});
  @override
  final String endpoint;
  final void Function() onKill;
  final Completer<int> _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> kill({Duration grace = const Duration(seconds: 3)}) async {
    onKill();
    if (!_exit.isCompleted) _exit.complete(143);
  }
}
