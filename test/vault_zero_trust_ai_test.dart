import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/vault/vault_redactor.dart';
import 'package:hamma/core/vault/vault_secret.dart';

/// End-to-end zero-trust assertion: when a vault secret is registered
/// in [GlobalVaultRedactor], its raw value MUST NOT appear in any
/// outbound HTTP body the AI service sends — neither on the user
/// prompt, nor on the prepended history.
void main() {
  late HttpServer server;
  final receivedBodies = <String>[];

  setUp(() async {
    receivedBodies.clear();
    GlobalVaultRedactor.reset();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      receivedBodies.add(body);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
          }
        ],
      }));
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    GlobalVaultRedactor.reset();
  });

  test('vault secret never appears in the outbound chat request body',
      () async {
    const rawSecret = 'super-secret-token-abcdef-1234567890';
    GlobalVaultRedactor.set(
      VaultRedactor.from([
        VaultSecret(
          id: 'k',
          name: 'API_TOKEN',
          value: rawSecret,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ]),
    );

    final service = AiCommandService(
      config: AiApiConfig(
        provider: AiProvider.openAi,
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'sk-fake',
        model: 'gpt-test',
      ),
    );

    await service.generateChatResponse(
      'please use the token $rawSecret to authenticate',
      history: [
        {'role': 'user', 'content': 'previous message: $rawSecret'},
        {'role': 'assistant', 'content': 'noted'},
      ],
    );

    expect(receivedBodies, isNotEmpty);
    for (final body in receivedBodies) {
      expect(
        body.contains(rawSecret),
        isFalse,
        reason: 'Outbound body must not contain the raw vault value.\n$body',
      );
      expect(
        body.contains('vault: API_TOKEN'),
        isTrue,
        reason: 'Outbound body must contain the redaction marker.',
      );
    }
  });
}
