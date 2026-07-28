import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/runbooks/runbook.dart';

void main() {
  group('RunbookStepType', () {
    test('tryParse works for valid strings', () {
      expect(RunbookStepType.tryParse('command'), RunbookStepType.command);
      expect(RunbookStepType.tryParse('prompt-user'), RunbookStepType.promptUser);
      expect(RunbookStepType.tryParse('promptUser'), RunbookStepType.promptUser);
    });

    test('tryParse returns null for invalid strings', () {
      expect(RunbookStepType.tryParse('invalid'), isNull);
    });
  });

  group('RunbookParam', () {
    test('fromJson and toJson round-trip', () {
      final json = {
        'name': 'param1',
        'label': 'Label 1',
        'defaultValue': 'def',
        'required': true,
      };

      final param = RunbookParam.fromJson(json);
      expect(param.name, 'param1');
      expect(param.label, 'Label 1');
      expect(param.defaultValue, 'def');
      expect(param.required, true);

      expect(param.toJson(), json);
    });

    test('fromJson handles missing fields with defaults', () {
      final json = {
        'name': 'param2',
      };

      final param = RunbookParam.fromJson(json);
      expect(param.name, 'param2');
      expect(param.label, 'param2'); // defaults to name
      expect(param.defaultValue, isNull);
      expect(param.required, false);

      expect(param.toJson(), {
        'name': 'param2',
        'label': 'param2',
        'required': false,
      });
    });
  });

  group('RunbookStep', () {
    test('fromJson and toJson round-trip for command', () {
      final json = {
        'id': 's1',
        'label': 'Step 1',
        'type': 'command',
        'command': 'echo hello',
        'timeoutSeconds': 30,
        'continueOnError': false,
      };

      final step = RunbookStep.fromJson(json);
      expect(step.id, 's1');
      expect(step.label, 'Step 1');
      expect(step.type, RunbookStepType.command);
      expect(step.command, 'echo hello');
      expect(step.timeoutSeconds, 30);
      expect(step.continueOnError, false);

      expect(step.toJson(), json);
    });

    test('copyWith works correctly', () {
      const step = RunbookStep(
        id: 's1',
        label: 'Step 1',
        type: RunbookStepType.command,
        command: 'echo hello',
      );

      final copied = step.copyWith(
        label: 'Step 1 updated',
        timeoutSeconds: 15,
        continueOnError: true,
      );

      expect(copied.id, 's1');
      expect(copied.label, 'Step 1 updated');
      expect(copied.type, RunbookStepType.command);
      expect(copied.command, 'echo hello');
      expect(copied.timeoutSeconds, 15);
      expect(copied.continueOnError, true);
    });

    test('fromJson throws RunbookSchemaException for unknown type', () {
      final json = {
        'id': 's2',
        'label': 'Step 2',
        'type': 'unknown-type',
      };

      expect(
        () => RunbookStep.fromJson(json),
        throwsA(isA<RunbookSchemaException>()),
      );
    });
  });

  group('Runbook', () {
    test('fromJson and toJson round-trip', () {
      final json = {
        'id': 'r1',
        'name': 'Runbook 1',
        'description': 'A test runbook',
        'params': [
          {
            'name': 'p1',
            'label': 'P1',
            'required': false,
          }
        ],
        'steps': [
          {
            'id': 's1',
            'label': 'Step 1',
            'type': 'command',
            'continueOnError': false,
            'command': 'echo 1',
          }
        ],
        'serverId': 'srv-1',
        'team': true,
        'starter': false,
      };

      final runbook = Runbook.fromJson(json);
      expect(runbook.id, 'r1');
      expect(runbook.name, 'Runbook 1');
      expect(runbook.description, 'A test runbook');
      expect(runbook.params.length, 1);
      expect(runbook.steps.length, 1);
      expect(runbook.serverId, 'srv-1');
      expect(runbook.team, true);
      expect(runbook.starter, false);

      expect(runbook.toJson(), json);
    });

    test('fromJson handles minimal fields', () {
      final json = {
        'id': 'r2',
        'name': 'Runbook 2',
        'steps': [
          {
            'id': 's1',
            'label': 'Step 1',
            'type': 'command',
            'continueOnError': false,
          }
        ],
      };

      final runbook = Runbook.fromJson(json);
      expect(runbook.id, 'r2');
      expect(runbook.name, 'Runbook 2');
      expect(runbook.description, '');
      expect(runbook.params, isEmpty);
      expect(runbook.steps.length, 1);
      expect(runbook.serverId, isNull);
      expect(runbook.team, false);
      expect(runbook.starter, false);
    });

    test('fromJson throws RunbookSchemaException if steps is not a list', () {
      final json = {
        'id': 'r3',
        'name': 'Runbook 3',
        'steps': 'not-a-list',
      };

      expect(
        () => Runbook.fromJson(json),
        throwsA(isA<RunbookSchemaException>()),
      );
    });

    test('fromJson throws RunbookSchemaException if a step is not a map', () {
      final json = {
        'id': 'r4',
        'name': 'Runbook 4',
        'steps': ['not-a-map'],
      };

      expect(
        () => Runbook.fromJson(json),
        throwsA(isA<RunbookSchemaException>()),
      );
    });

    test('copyWith works correctly', () {
      const runbook = Runbook(
        id: 'r1',
        name: 'Runbook 1',
        steps: [
          RunbookStep(id: 's1', label: 'Step 1', type: RunbookStepType.command)
        ],
      );

      final copied = runbook.copyWith(
        name: 'Runbook 1 updated',
        description: 'New desc',
        serverId: 'srv-2',
      );

      expect(copied.id, 'r1');
      expect(copied.name, 'Runbook 1 updated');
      expect(copied.description, 'New desc');
      expect(copied.steps.length, 1);
      expect(copied.serverId, 'srv-2');
      expect(copied.team, false);

      final cleared = copied.copyWith(clearServerId: true);
      expect(cleared.serverId, isNull);
    });
  });
}
