import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/runbooks/runbook.dart';
import 'package:hamma/core/runbooks/runbook_runner.dart';

class _FakeSsh {
  _FakeSsh(this.responses);
  final Map<String, String> responses;
  final List<String> calls = [];

  Future<String> execute(String command) async {
    calls.add(command);
    if (responses.containsKey(command)) return responses[command]!;
    return '';
  }
}

void main() {
  group('renderTemplate', () {
    test('substitutes params and step.<id>.stdout tokens', () {
      final out = renderTemplate(
        'echo {{name}} && grep {{step.s1.stdout}}',
        params: {'name': 'hello'},
        stepStdout: {'s1': 'world'},
      );
      expect(out, 'echo hello && grep world');
    });

    test('leaves unknown tokens intact', () {
      final out = renderTemplate(
        'echo {{missing}}',
        params: const {},
        stepStdout: const {},
      );
      expect(out, 'echo {{missing}}');
    });
  });

  group('dryRunCommands', () {
    test('returns rendered command strings only', () {
      final rb = Runbook(
        id: 'rb',
        name: 'Demo',
        params: const [RunbookParam(name: 'p', label: 'p', defaultValue: 'X')],
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'cmd',
            type: RunbookStepType.command,
            command: 'echo {{p}}',
          ),
          RunbookStep(
            id: 's2',
            label: 'note',
            type: RunbookStepType.notify,
            notifyMessage: 'done',
          ),
        ],
      );
      final cmds = dryRunCommands(rb, {'p': 'X'});
      expect(cmds, ['echo X']);
    });
  });

  group('RunbookRunner.run', () {
    test('executes command + notify in order, captures stdout', () async {
      final ssh = _FakeSsh({'uname -a': 'Linux test 6.6.0'});
      final rb = Runbook(
        id: 'rb',
        name: 'OK',
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'uname',
            type: RunbookStepType.command,
            command: 'uname -a',
          ),
          RunbookStep(
            id: 's2',
            label: 'beep',
            type: RunbookStepType.notify,
            notifyMessage: 'all good',
          ),
        ],
      );
      final runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: ssh.execute,
      );
      final result = await runner.run();
      expect(result.results, hasLength(2));
      expect(result.results[0].status, RunbookStepStatus.succeeded);
      expect(result.results[0].stdout, contains('Linux'));
      expect(result.results[1].status, RunbookStepStatus.succeeded);
      expect(ssh.calls, ['uname -a']);
    });

    test('skipIfRegex skips a step when the referenced output matches',
        () async {
      final ssh = _FakeSsh({'check': 'ERROR detected'});
      final rb = Runbook(
        id: 'rb',
        name: 'Skip',
        steps: const [
          RunbookStep(
            id: 'check',
            label: 'check',
            type: RunbookStepType.command,
            command: 'check',
          ),
          RunbookStep(
            id: 'restart',
            label: 'restart',
            type: RunbookStepType.command,
            command: 'restart',
            skipIfRegex: r'ERROR',
            skipIfReferenceStepId: 'check',
          ),
        ],
      );
      final runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: ssh.execute,
      );
      final result = await runner.run();
      expect(result.results.last.status, RunbookStepStatus.skipped);
      expect(ssh.calls, ['check']);
    });

    test('failed step without continueOnError stops the run', () async {
      final ssh = _FakeSsh(const {});
      final rb = Runbook(
        id: 'rb',
        name: 'Stop',
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'fail',
            type: RunbookStepType.command,
            command: 'fail',
            timeoutSeconds: 1,
          ),
          RunbookStep(
            id: 's2',
            label: 'never',
            type: RunbookStepType.command,
            command: 'never',
          ),
        ],
      );
      final runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: (_) async => throw StateError('boom'),
      );
      final result = await runner.run();
      expect(result.results[0].status, RunbookStepStatus.failed);
      expect(result.results[1].status, RunbookStepStatus.cancelled);
      expect(ssh.calls, isEmpty);
    });

    test('risk-gated commands consult the confirm callback', () async {
      var prompted = 0;
      final ssh = _FakeSsh(const {});
      final rb = Runbook(
        id: 'rb',
        name: 'Risky',
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'sudo',
            type: RunbookStepType.command,
            command: 'sudo rm -rf /tmp/whatever',
          ),
        ],
      );
      final runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: ssh.execute,
        confirmRiskGate: (_, __, ___) async {
          prompted++;
          return false;
        },
      );
      final result = await runner.run();
      expect(prompted, greaterThan(0));
      expect(result.results.first.status, RunbookStepStatus.cancelled);
    });

    test('rejects an invalid runbook at construction time', () {
      final rb = Runbook(
        id: '',
        name: '',
        steps: const [],
      );
      expect(
        () => RunbookRunner(
          runbook: rb,
          params: const {},
          executeCommand: (_) async => '',
        ),
        throwsA(isA<RunbookSchemaException>()),
      );
    });

    test('aiSummarize calls the local LLM hook with the prior stdout',
        () async {
      final ssh = _FakeSsh({'tail': 'first line\nsecond line'});
      String? captured;
      final rb = Runbook(
        id: 'rb',
        name: 'AI',
        steps: const [
          RunbookStep(
            id: 'tail',
            label: 'tail',
            type: RunbookStepType.command,
            command: 'tail',
          ),
          RunbookStep(
            id: 'sum',
            label: 'summary',
            type: RunbookStepType.aiSummarize,
            aiPrompt: 'Read this:',
            aiReferenceStepId: 'tail',
          ),
        ],
      );
      final runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: ssh.execute,
        callLocalAi: (prompt) async {
          captured = prompt;
          return 'ALL CLEAR';
        },
      );
      final result = await runner.run();
      expect(captured, contains('Read this:'));
      expect(captured, contains('first line'));
      expect(result.results.last.summary, 'ALL CLEAR');
    });

    test('cancellation between steps marks subsequent steps cancelled',
        () async {
      final ssh = _FakeSsh({'a': 'one', 'b': 'two'});
      late RunbookRunner runner;
      final rb = Runbook(
        id: 'rb',
        name: 'Cancel',
        steps: const [
          RunbookStep(
              id: 'a',
              label: 'a',
              type: RunbookStepType.command,
              command: 'a'),
          RunbookStep(
              id: 'b',
              label: 'b',
              type: RunbookStepType.command,
              command: 'b'),
        ],
      );
      runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: (cmd) async {
          if (cmd == 'a') runner.cancellation.cancel();
          return ssh.execute(cmd);
        },
      );
      final result = await runner.run();
      expect(result.results[0].status, RunbookStepStatus.succeeded);
      expect(result.results[1].status, RunbookStepStatus.cancelled);
      expect(ssh.calls, ['a']);
    });
  });
}
