import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';

void main() {
  group('decodeOpenAiSseBody', () {
    test('parses SSE-prefixed delta chunks and stops at [DONE]', () async {
      final lines = Stream.fromIterable([
        'data: {"choices":[{"delta":{"content":"Hello"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":" world"}}]}',
        'data: {"choices":[{"delta":{"content":"!"},"finish_reason":null}]}',
        'data: [DONE]',
        // Anything after [DONE] must NOT be emitted.
        'data: {"choices":[{"delta":{"content":"IGNORED"}}]}',
      ]);
      final out =
          await AiCommandService.decodeOpenAiSseBody(lines).toList();
      expect(out, ['Hello', ' world', '!']);
    });

    test('parses raw NDJSON (no `data:` prefix)', () async {
      final lines = Stream.fromIterable([
        '{"choices":[{"delta":{"content":"foo"}}]}',
        '{"choices":[{"delta":{"content":"bar"}}]}',
        '{"choices":[{"delta":{},"finish_reason":"stop"}]}',
      ]);
      final out =
          await AiCommandService.decodeOpenAiSseBody(lines).toList();
      expect(out, ['foo', 'bar']);
    });

    test('falls back to message.content when delta is missing', () async {
      final lines = Stream.fromIterable([
        '{"choices":[{"message":{"content":"single shot"}}]}',
      ]);
      final out =
          await AiCommandService.decodeOpenAiSseBody(lines).toList();
      expect(out, ['single shot']);
    });

    test('skips blank lines and malformed JSON', () async {
      final lines = Stream.fromIterable([
        '',
        '   ',
        'data: not-json',
        'data: {"choices":[{"delta":{"content":"ok"}}]}',
        'data: [DONE]',
      ]);
      final out =
          await AiCommandService.decodeOpenAiSseBody(lines).toList();
      expect(out, ['ok']);
    });
  });

  group('AiCommandService.streamChatResponse against a loopback server', () {
    late HttpServer server;
    late String localEndpoint;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      localEndpoint = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        if (req.method == 'POST' &&
            req.uri.path == '/v1/chat/completions') {
          // Verify the client asked for streaming and did NOT send Authorization.
          final body = await utf8.decoder.bind(req).join();
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          expect(decoded['stream'], isTrue);
          expect(req.headers.value(HttpHeaders.authorizationHeader), isNull);

          req.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          req.response.write(
              'data: ${jsonEncode({'choices': [{'delta': {'content': 'Hi'}}]})}\n\n');
          req.response.write(
              'data: ${jsonEncode({'choices': [{'delta': {'content': ' there'}}]})}\n\n');
          req.response.write(
              'data: ${jsonEncode({'choices': [{'delta': {'content': '!'}, 'finish_reason': 'stop'}]})}\n\n');
          req.response.write('data: [DONE]\n\n');
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

    test('local provider streams content deltas in order', () async {
      final svc = AiCommandService.forProvider(
        provider: AiProvider.local,
        apiKey: '',
        localEndpoint: localEndpoint,
        localModel: 'gemma3',
      );
      final out = <String>[];
      await for (final delta in svc.streamChatResponse('hi')) {
        out.add(delta);
      }
      expect(out, ['Hi', ' there', '!']);
    });

    test('rejects empty prompt', () async {
      final svc = AiCommandService.forProvider(
        provider: AiProvider.local,
        apiKey: '',
        localEndpoint: localEndpoint,
        localModel: 'gemma3',
      );
      await expectLater(
        svc.streamChatResponse('   ').toList(),
        throwsA(isA<AiCommandServiceException>()),
      );
    });

    test('non-local provider with no API key throws', () async {
      final svc = AiCommandService.forProvider(
        provider: AiProvider.openAi,
        apiKey: '',
      );
      await expectLater(
        svc.streamChatResponse('hi').toList(),
        throwsA(isA<AiCommandServiceException>()),
      );
    });
  });
}
