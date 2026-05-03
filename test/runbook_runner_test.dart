import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/runbooks/runbook.dart';
import 'package:hamma/core/runbooks/runbook_runner.dart';

class _FakeSsh {
  _FakeSsh(this.responses);
  final Map<String, String> responses;
  final List<String> calls = [];

  Future<String> execute(String command, RunbookCancellation _) async {
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
        executeCommand: (_, __) async => throw StateError('boom'),
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
          executeCommand: (_, __) async => '',
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

    test('branch step jumps to true target on regex match', () async {
      final ssh = _FakeSsh({'check': 'STATUS=ok healthy'});
      final rb = Runbook(
        id: 'rb',
        name: 'Branch',
        steps: const [
          RunbookStep(
            id: 'check',
            label: 'check',
            type: RunbookStepType.command,
            command: 'check',
          ),
          RunbookStep(
            id: 'gate',
            label: 'gate',
            type: RunbookStepType.branch,
            branchRegex: r'STATUS=ok',
            branchReferenceStepId: 'check',
            branchTrueGoToStepId: 'finish',
          ),
          RunbookStep(
            id: 'recover',
            label: 'recover',
            type: RunbookStepType.command,
            command: 'recover',
          ),
          RunbookStep(
            id: 'finish',
            label: 'finish',
            type: RunbookStepType.notify,
            notifyMessage: 'done',
          ),
        ],
      );
      final runner = RunbookRunner(
        runbook: rb,
        params: const {},
        executeCommand: ssh.execute,
      );
      final result = await runner.run();
      // recover must be SKIPPED entirely (never executed because we
      // jumped over it).
      expect(ssh.calls, ['check']);
      expect(
        result.results.map((r) => r.step.id),
        ['check', 'gate', 'finish'],
      );
      expect(result.results.last.status, RunbookStepStatus.succeeded);
    });

    test('JSON round-trip uses hyphenated step type discriminators', () {
      final rb = Runbook(
        id: 'rb',
        name: 'Wire',
        steps: const [
          RunbookStep(
            id: 'a',
            label: 'a',
            type: RunbookStepType.promptUser,
            paramName: 'x',
            question: 'X?',
          ),
          RunbookStep(
            id: 'b',
            label: 'b',
            type: RunbookStepType.waitFor,
            waitMode: 'time',
            waitSeconds: 1,
          ),
          RunbookStep(
            id: 'c',
            label: 'c',
            type: RunbookStepType.aiSummarize,
            aiPrompt: 'tldr',
          ),
          RunbookStep(
            id: 'd',
            label: 'd',
            type: RunbookStepType.branch,
            branchRegex: 'ok',
            branchTrueGoToStepId: 'a',
          ),
        ],
      );
      final json = rb.toJson();
      final stepTypes = (json['steps'] as List)
          .map((s) => (s as Map)['type'] as String)
          .toList();
      expect(
        stepTypes,
        ['prompt-user', 'wait-for', 'ai-summarize', 'branch'],
      );
      // Round-trip back through the parser, including a back-compat
      // entry that uses the old camelCase name.
      final mutated = Map<String, dynamic>.from(json);
      final mutatedSteps = (mutated['steps'] as List)
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
      mutatedSteps[0]['type'] = 'promptUser'; // legacy name
      mutated['steps'] = mutatedSteps;
      final parsed = Runbook.fromJson(mutated);
      expect(parsed.steps.map((s) => s.type), [
        RunbookStepType.promptUser,
        RunbookStepType.waitFor,
        RunbookStepType.aiSummarize,
        RunbookStepType.branch,
      ]);
    });

    test('cancellation onCancel listener fires when STOP is pressed',
        () async {
      final cancel = RunbookCancellation();
      var fired = 0;
      cancel.onCancel(() => fired++);
      cancel.onCancel(() => fired++);
      cancel.cancel();
      cancel.cancel(); // idempotent
      expect(cancel.isCancelled, isTrue);
      expect(fired, 2);
      // listener registered AFTER cancel still fires immediately
      cancel.onCancel(() => fired++);
      expect(fired, 3);
    });

    test(
      'non-zero exit (RunbookCommandFailed) marks step failed, preserves stdout, stops the run',
      () async {
        final rb = Runbook(
          id: 'rb',
          name: 'Deploy',
          steps: const [
            RunbookStep(
              id: 'pull',
              label: 'git pull',
              type: RunbookStepType.command,
              command: 'git pull',
            ),
            RunbookStep(
              id: 'restart',
              label: 'systemctl restart',
              type: RunbookStepType.command,
              command: 'systemctl restart app',
            ),
          ],
        );
        final runner = RunbookRunner(
          runbook: rb,
          params: const {},
          executeCommand: (cmd, _) async {
            // Simulates the real SSH adapter: dartssh2's
            // session.done resolves on close, the adapter checks
            // session.exitCode and throws this on non-zero.
            throw const RunbookCommandFailed(
              stdout: 'fetching origin/main...\n',
              stderr: 'fatal: not a git repository\n',
              exitCode: 128,
            );
          },
        );
        final result = await runner.run();
        expect(result.results[0].status, RunbookStepStatus.failed);
        expect(result.results[0].stdout,
            'fetching origin/main...\n');
        expect(result.results[0].error, contains('exit 128'));
        expect(result.results[0].error, contains('not a git repository'));
        // Critical safety property: the second command MUST NOT
        // execute after a failed precondition unless
        // continueOnError is set.
        expect(result.results[1].status, RunbookStepStatus.cancelled);
        expect(result.hasFailures, isTrue);
      },
    );

    test(
      'non-zero exit with continueOnError keeps going to subsequent steps',
      () async {
        var calls = 0;
        final rb = Runbook(
          id: 'rb',
          name: 'Soft',
          steps: const [
            RunbookStep(
              id: 'a',
              label: 'a',
              type: RunbookStepType.command,
              command: 'a',
              continueOnError: true,
            ),
            RunbookStep(
              id: 'b',
              label: 'b',
              type: RunbookStepType.command,
              command: 'b',
            ),
          ],
        );
        final runner = RunbookRunner(
          runbook: rb,
          params: const {},
          executeCommand: (cmd, _) async {
            calls++;
            if (cmd == 'a') {
              throw const RunbookCommandFailed(
                stdout: '',
                stderr: 'oops',
                exitCode: 1,
              );
            }
            return 'b-out';
          },
        );
        final result = await runner.run();
        expect(calls, 2);
        expect(result.results[0].status, RunbookStepStatus.failed);
        expect(result.results[1].status, RunbookStepStatus.succeeded);
      },
    );

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
        executeCommand: (cmd, cancel) async {
          if (cmd == 'a') runner.cancellation.cancel();
          return ssh.execute(cmd, cancel);
        },
      );
      final result = await runner.run();
      expect(result.results[0].status, RunbookStepStatus.succeeded);
      expect(result.results[1].status, RunbookStepStatus.cancelled);
      expect(ssh.calls, ['a']);
    });
  });
}
