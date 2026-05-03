import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/runbooks/runbook_ai_drafter.dart';
import 'package:hamma/core/storage/api_key_storage.dart';

void main() {
  const settings = AiSettings(provider: AiProvider.local);

  test('parses a clean JSON object response', () async {
    final drafter = RunbookAiDrafter(
      aiSettings: settings,
      overrideCall: (prompt) async {
        return '''
{
  "id": "ignored",
  "name": "Restart nginx",
  "description": "Validates config then restarts",
  "params": [],
  "steps": [
    {"id":"s1","label":"test","type":"command","command":"sudo nginx -t"}
  ]
}
''';
      },
    );
    final rb = await drafter.draftFromGoal('restart nginx');
    expect(rb.name, 'Restart nginx');
    expect(rb.steps, hasLength(1));
    expect(rb.steps.first.command, 'sudo nginx -t');
    expect(rb.team, isFalse);
    expect(rb.starter, isFalse);
    // Drafter MUST mint a fresh id rather than honouring the model's value.
    expect(rb.id, isNot('ignored'));
  });

  test('strips ```json fences before parsing', () async {
    final drafter = RunbookAiDrafter(
      aiSettings: settings,
      overrideCall: (_) async => '''
Here you go:
```json
{"id":"x","name":"Echo","steps":[{"id":"s1","label":"echo","type":"command","command":"echo hi"}]}
```
''',
    );
    final rb = await drafter.draftFromGoal('echo hi');
    expect(rb.name, 'Echo');
    expect(rb.steps.first.command, 'echo hi');
  });

  test('throws RunbookDrafterException on non-JSON output', () async {
    final drafter = RunbookAiDrafter(
      aiSettings: settings,
      overrideCall: (_) async => 'sorry I can\'t do that',
    );
    await expectLater(
      drafter.draftFromGoal('something'),
      throwsA(isA<RunbookDrafterException>()),
    );
  });

  test('throws when the draft fails schema validation', () async {
    final drafter = RunbookAiDrafter(
      aiSettings: settings,
      overrideCall: (_) async =>
          '{"id":"x","name":"","steps":[{"id":"s1","label":"x","type":"command"}]}',
    );
    await expectLater(
      drafter.draftFromGoal('something'),
      throwsA(isA<RunbookDrafterException>()),
    );
  });
}
