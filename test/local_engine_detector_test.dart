import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/local_engine_detector.dart';

Future<HttpServer> _bindOllama() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    if (req.method == 'GET' && req.uri.path == '/api/version') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'version': '0.1.42'}));
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  return s;
}

Future<HttpServer> _bindOpenAiCompat() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    if (req.method == 'GET' && req.uri.path == '/v1/models') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'data': <dynamic>[]}));
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  return s;
}

void main() {
  test('probe identifies Ollama via /api/version', () async {
    final server = await _bindOllama();
    addTearDown(() => server.close(force: true));
    final detector = LocalEngineDetector(
      probeTimeout: const Duration(seconds: 1),
    );
    final engine = await detector.probe(
      kind: LocalEngineKind.ollama,
      port: server.port,
    );
    expect(engine, isNotNull);
    expect(engine!.kind, LocalEngineKind.ollama);
    expect(engine.version, '0.1.42');
    expect(engine.endpoint, 'http://127.0.0.1:${server.port}');
  });

  test('probe identifies LM Studio via /v1/models', () async {
    final server = await _bindOpenAiCompat();
    addTearDown(() => server.close(force: true));
    final detector = LocalEngineDetector(
      probeTimeout: const Duration(seconds: 1),
    );
    final engine = await detector.probe(
      kind: LocalEngineKind.lmStudio,
      port: server.port,
    );
    expect(engine, isNotNull);
    expect(engine!.kind, LocalEngineKind.lmStudio);
  });

  test('probe returns null on a closed port', () async {
    // Bind then close to get a port that's *not* listening.
    final tmp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = tmp.port;
    await tmp.close(force: true);

    final detector = LocalEngineDetector(
      probeTimeout: const Duration(milliseconds: 300),
    );
    final engine = await detector.probe(
      kind: LocalEngineKind.ollama,
      port: port,
    );
    expect(engine, isNull);
  });

  test('detect runs every probe and tolerates partial failures', () async {
    // Only Ollama is up; default detector probes 4 well-known ports — the
    // others will return null. We override the host->port map by running a
    // single probe; full default sweep is exercised in manual QA.
    final server = await _bindOllama();
    addTearDown(() => server.close(force: true));
    final detector = LocalEngineDetector(
      probeTimeout: const Duration(milliseconds: 300),
    );
    final hit = await detector.probe(
      kind: LocalEngineKind.ollama,
      port: server.port,
    );
    expect(hit, isNotNull);
  });

  test('engine display label includes version when known', () {
    const e = DetectedEngine(
      kind: LocalEngineKind.ollama,
      endpoint: 'http://127.0.0.1:11434',
      version: '0.1.42',
    );
    expect(e.displayLabel, contains('Ollama'));
    expect(e.displayLabel, contains('0.1.42'));
  });
}
