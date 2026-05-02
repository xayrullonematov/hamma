import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';

void main() {
  const service = AiCommandService(
    config: AiApiConfig(
      provider: AiProvider.openAi,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      model: 'test-model',
    ),
  );

  test('config reports configured when api key is present', () {
    const config = AiApiConfig(
      provider: AiProvider.gemini,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      model: 'test-model',
    );

    expect(config.isConfigured, isTrue);
  });

  test('service throws clear error for empty prompt', () async {
    await expectLater(
      service.generateCommand('   '),
      throwsA(
        isA<AiCommandServiceException>().having(
          (error) => error.message,
          'message',
          'Prompt cannot be empty.',
        ),
      ),
    );
  });

  group('AiCommandService.parseJsonFromResponse', () {
    // ── Strategy 1: direct parse (clean API response) ─────────────────────
    group('strategy 1 — direct parse', () {
      test('parses pure JSON object', () {
        final result = AiCommandService.parseJsonFromResponse(
          '{"command":"ls","risk_level":"low","explanation":"List files"}',
        );

        expect(result, isNotNull);
        expect(result!['command'], 'ls');
        expect(result['risk_level'], 'low');
        expect(result['explanation'], 'List files');
      });

      test('parses pure JSON with surrounding whitespace', () {
        final result = AiCommandService.parseJsonFromResponse(
          '\n  {"command":"pwd"}  \n',
        );

        expect(result, isNotNull);
        expect(result!['command'], 'pwd');
      });

      test('parses nested JSON object', () {
        final result = AiCommandService.parseJsonFromResponse(
          '{"command":"ls","meta":{"safe":true,"tags":["read"]}}',
        );

        expect(result, isNotNull);
        expect(result!['meta'], isA<Map>());
        expect((result['meta'] as Map)['safe'], isTrue);
      });

      test('returns null when input is a JSON array (not an object)', () {
        // Schema requires Map<String, dynamic>; arrays must fail.
        final result = AiCommandService.parseJsonFromResponse(
          '["a","b","c"]',
        );

        expect(result, isNull);
      });

      test('returns null when input is a JSON string scalar', () {
        final result = AiCommandService.parseJsonFromResponse('"just a string"');

        expect(result, isNull);
      });
    });

    // ── Strategy 2: code-fence extraction ─────────────────────────────────
    group('strategy 2 — code fence extraction', () {
      test('extracts JSON from ```json ... ``` fence with preamble', () {
        const response = '''
Sure! Here's the JSON object you requested:

```json
{"command":"uptime","risk_level":"low","explanation":"Show uptime"}
```

Hope that helps!
''';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'uptime');
        expect(result['explanation'], 'Show uptime');
      });

      test('extracts JSON from generic ``` ``` fence (no language tag)', () {
        const response = '''
Here you go:

```
{"action":"deploy","target_server":"web-1"}
```
''';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['action'], 'deploy');
        expect(result['target_server'], 'web-1');
      });

      test('extracts JSON from ```json fence even when prose contains braces', () {
        // Pure brace-scan would get confused by braces in surrounding text;
        // the code-fence path handles this cleanly.
        const response = '''
The schema is { key: value }. Here's the result:

```json
{"command":"df -h"}
```
''';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'df -h');
      });
    });

    // ── Strategy 3: brace-depth scan (string-aware) ───────────────────────
    group('strategy 3 — brace-depth scan', () {
      test('finds JSON embedded in unstructured prose', () {
        const response =
            'Sure, the answer is {"command":"whoami","risk_level":"low"} '
            'as you can see above.';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'whoami');
      });

      test('handles closing brace inside a JSON string value (string-aware)', () {
        // The greedy-regex implementation would NOT correctly handle this:
        // a naive scan stops at the first '}' which is inside the string.
        const response =
            'Here is the result: '
            '{"command":"ls","explanation":"shows files like { and } chars"}';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'ls');
        expect(
          result['explanation'],
          'shows files like { and } chars',
        );
      });

      test('handles escaped quotes inside string values', () {
        const response =
            r'Output: {"command":"echo \"hi\"","explanation":"prints hi"}';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], r'echo "hi"');
      });

      test('handles deeply nested JSON inside prose', () {
        const response =
            'Sure: {"a":1,"b":{"c":{"d":42}},"e":"end"} done.';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['a'], 1);
        expect(((result['b'] as Map)['c'] as Map)['d'], 42);
      });

      test('ignores stray closing braces in prose before JSON', () {
        // Stray '}' should not drive depth negative or break later parsing.
        const response =
            'I think } is interesting. The result: {"command":"id"}';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'id');
      });

      test('returns first valid JSON object when multiple are present', () {
        const response =
            'First {"command":"ls"} and second {"command":"pwd"} object.';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'ls');
      });

      test('recovers when first {...} candidate is invalid JSON', () {
        // Common LLM output pattern: model writes a sketch object first,
        // then the real one. The scan must keep going past the failed
        // decode rather than giving up.
        const response =
            'I was thinking {schema like this} but actually the answer is '
            '{"command":"uptime","risk_level":"low"}';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'uptime');
      });

      test('falls through to brace scan when fence content is invalid', () {
        // Fence regex matches greedily; if its content isn't valid JSON,
        // the parser must still find the prose-embedded valid object.
        const response = '''
Initial draft:

```
{not actually json}
```

Final answer: {"command":"id","risk_level":"low"}
''';

        final result = AiCommandService.parseJsonFromResponse(response);

        expect(result, isNotNull);
        expect(result!['command'], 'id');
      });
    });

    // ── Failure modes ─────────────────────────────────────────────────────
    group('failure modes', () {
      test('returns null for empty input', () {
        expect(AiCommandService.parseJsonFromResponse(''), isNull);
      });

      test('returns null for whitespace-only input', () {
        expect(AiCommandService.parseJsonFromResponse('   \n\t  '), isNull);
      });

      test('returns null when no JSON is present anywhere', () {
        expect(
          AiCommandService.parseJsonFromResponse(
            'Sorry, I cannot help with that request.',
          ),
          isNull,
        );
      });

      test('returns null for unbalanced braces', () {
        expect(
          AiCommandService.parseJsonFromResponse('{ "command": "ls"'),
          isNull,
        );
      });

      test('returns null for malformed JSON inside braces', () {
        expect(
          AiCommandService.parseJsonFromResponse(
            '{this is not valid json at all}',
          ),
          isNull,
        );
      });
    });
  });
}
