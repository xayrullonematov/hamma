import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/ai/local_engine_detector.dart';
import 'package:hamma/core/ai/local_engine_health_monitor.dart';
import 'package:hamma/core/ai/ollama_client.dart';

/// HttpClient that records every URL it dials and refuses to actually
/// open a socket. Used as a tripwire: if any "local AI" component tries
/// to talk to a non-loopback host, we want this test to fail loudly.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this.calls);
  final List<Uri> calls;

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  bool autoUncompress = true;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    calls.add(url);
    // Throw a SocketException so the tripwire surfaces as "engine offline"
    // (which the components handle gracefully), instead of leaking a real
    // network connection.
    throw const SocketException('blocked by zero-trust guard');
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  void close({bool force = false}) {}

  @override
  set authenticate(
      Future<bool> Function(Uri url, String scheme, String? realm)? f) {}
  @override
  set authenticateProxy(
      Future<bool> Function(
              String host, int port, String scheme, String? realm)?
          f) {}
  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {}
  @override
  set findProxy(String Function(Uri url)? f) {}
  @override
  set keyLog(void Function(String line)? callback) {}
  @override
  void addCredentials(
      Uri url, String realm, HttpClientCredentials credentials) {}
  @override
  void addProxyCredentials(String host, int port, String realm,
      HttpClientCredentials credentials) {}
  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
              Uri url, String? proxyHost, int? proxyPort)?
          f) {}
}

bool _isLoopback(Uri u) {
  final h = u.host;
  if (h == 'localhost') return true;
  if (h == '127.0.0.1') return true;
  if (h == '::1') return true;
  // 127.0.0.0/8 is the loopback block.
  if (RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(h)) return true;
  return false;
}

void main() {
  group('zero-trust network guard — local AI components must stay loopback',
      () {
    test(
      'OllamaClient never dials a non-loopback host',
      () async {
        final calls = <Uri>[];
        final client = OllamaClient(
          endpoint: 'http://127.0.0.1:11434',
          httpClientFactory: () => _RecordingHttpClient(calls),
        );

        // Each call below is expected to throw because the recording
        // client refuses to connect — we only care that the URL it tried
        // to dial was on loopback.
        await expectLater(
            client.version(), throwsA(isA<OllamaUnavailableException>()));
        await expectLater(
            client.listModels(), throwsA(isA<OllamaUnavailableException>()));
        await expectLater(client.deleteModel('foo'),
            throwsA(isA<OllamaUnavailableException>()));
        await expectLater(client.pullModel('foo').toList(),
            throwsA(isA<OllamaUnavailableException>()));
        await expectLater(
          client.streamChat(
            model: 'gemma3',
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
          ).toList(),
          throwsA(isA<OllamaUnavailableException>()),
        );

        expect(calls, isNotEmpty,
            reason: 'expected the client to attempt at least one call');
        for (final u in calls) {
          expect(_isLoopback(u), isTrue,
              reason: 'OllamaClient dialled non-loopback URL: $u');
        }
      },
    );

    test(
      'LocalEngineDetector only dials 127.0.0.1',
      () async {
        final calls = <Uri>[];
        final detector = LocalEngineDetector(
          httpClientFactory: () => _RecordingHttpClient(calls),
        );
        final found = await detector.detect();
        // Recording client rejects every probe → no detected engines.
        expect(found, isEmpty);
        expect(calls, isNotEmpty);
        for (final u in calls) {
          expect(_isLoopback(u), isTrue,
              reason: 'detector dialled non-loopback URL: $u');
        }
      },
    );

    test(
      'LocalEngineHealthMonitor only dials loopback',
      () async {
        final calls = <Uri>[];
        final client = OllamaClient(
          endpoint: 'http://127.0.0.1:11434',
          httpClientFactory: () => _RecordingHttpClient(calls),
        );
        final monitor = LocalEngineHealthMonitor(
          endpoint: 'http://127.0.0.1:11434',
          interval: const Duration(milliseconds: 50),
          client: client,
        );
        final snap = await monitor.probeNow();
        expect(snap.isOffline, isTrue);
        await monitor.dispose();
        expect(calls, isNotEmpty);
        for (final u in calls) {
          expect(_isLoopback(u), isTrue,
              reason: 'health monitor dialled non-loopback URL: $u');
        }
      },
    );

    test(
      'AiCommandService streamChatResponse(local) only hits the endpoint we configured',
      () async {
        // Bind a real loopback server so we can be sure the SSE path
        // doesn't accidentally hit anywhere else.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final endpoint = 'http://127.0.0.1:${server.port}';
        final hits = <Uri>[];
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          hits.add(req.uri);
          req.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          req.response.write(
              'data: ${jsonEncode({'choices': [{'delta': {'content': 'ok'}, 'finish_reason': 'stop'}]})}\n\n');
          req.response.write('data: [DONE]\n\n');
          await req.response.close();
        });

        final svc = AiCommandService.forProvider(
          provider: AiProvider.local,
          apiKey: '',
          localEndpoint: endpoint,
          localModel: 'gemma3',
        );
        final out = await svc.streamChatResponse('hi').toList();
        expect(out, ['ok']);
        // Server got exactly one request, and it was to /v1/chat/completions
        // on loopback — nothing else.
        expect(hits, isNotEmpty);
        expect(hits.every((u) => u.path == '/v1/chat/completions'), isTrue);
      },
    );
  });
}
