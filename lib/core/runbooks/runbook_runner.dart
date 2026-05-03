import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../ai/ai_command_service.dart';
import '../ai/command_risk_assessor.dart';
import '../ssh/ssh_service.dart';
import '../storage/api_key_storage.dart';
import 'runbook.dart';

/// Outcome reported for each step.
enum RunbookStepStatus { skipped, succeeded, failed, cancelled }

/// One row in the per-run timeline.
@immutable
class RunbookStepResult {
  const RunbookStepResult({
    required this.step,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.stdout = '',
    this.summary = '',
    this.error,
  });

  final RunbookStep step;
  final RunbookStepStatus status;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String stdout;
  final String summary;
  final String? error;

  Duration get duration => finishedAt.difference(startedAt);
}

/// Final outcome of a [RunbookRunner.run] call.
@immutable
class RunbookRunResult {
  const RunbookRunResult({
    required this.runbook,
    required this.results,
    required this.cancelled,
    required this.startedAt,
    required this.finishedAt,
  });

  final Runbook runbook;
  final List<RunbookStepResult> results;
  final bool cancelled;
  final DateTime startedAt;
  final DateTime finishedAt;

  bool get hasFailures =>
      results.any((r) => r.status == RunbookStepStatus.failed);
}

/// Events the runner emits over [RunbookRunner.events]. The UI maps
/// these straight to brutalist row updates.
abstract class RunbookEvent {
  const RunbookEvent();
}

class RunbookStarted extends RunbookEvent {
  const RunbookStarted(this.runbook);
  final Runbook runbook;
}

class StepStarted extends RunbookEvent {
  const StepStarted(this.step, this.index);
  final RunbookStep step;
  final int index;
}

class StepStdout extends RunbookEvent {
  const StepStdout(this.step, this.chunk);
  final RunbookStep step;
  final String chunk;
}

class StepFinished extends RunbookEvent {
  const StepFinished(this.result, this.index);
  final RunbookStepResult result;
  final int index;
}

class StepRiskGate extends RunbookEvent {
  const StepRiskGate(this.step, this.command, this.analysis);
  final RunbookStep step;
  final String command;
  final CommandAnalysis analysis;
}

class StepPromptUser extends RunbookEvent {
  const StepPromptUser(this.step);
  final RunbookStep step;
}

class StepNotify extends RunbookEvent {
  const StepNotify(this.step, this.message);
  final RunbookStep step;
  final String message;
}

class RunbookFinished extends RunbookEvent {
  const RunbookFinished(this.result);
  final RunbookRunResult result;
}

/// Cooperative cancellation token with a teardown registry so the
/// SSH adapter can close the in-flight session when STOP is pressed.
class RunbookCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  final List<void Function()> _listeners = [];

  void onCancel(void Function() listener) {
    if (_cancelled) {
      try {
        listener();
      } catch (_) {}
      return;
    }
    _listeners.add(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final snapshot = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final cb in snapshot) {
      try {
        cb();
      } catch (_) {}
    }
  }
}

/// Executor signalled the in-flight command was killed via STOP.
class RunbookCommandCancelled implements Exception {
  const RunbookCommandCancelled();
  @override
  String toString() => 'RunbookCommandCancelled';
}

/// Executor signalled a non-zero remote exit. dartssh2's `done`
/// resolves on channel close regardless of exit status, so the SSH
/// adapter must inspect `session.exitCode`/`exitSignal` itself.
class RunbookCommandFailed implements Exception {
  const RunbookCommandFailed({
    required this.stdout,
    required this.stderr,
    this.exitCode,
    this.exitSignal,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
  final String? exitSignal;

  @override
  String toString() {
    final code = exitCode != null ? 'exit $exitCode' : null;
    final sig = exitSignal != null ? 'signal $exitSignal' : null;
    final reason = [code, sig].whereType<String>().join(' / ');
    final tail = stderr.trim().isNotEmpty
        ? stderr.trim()
        : stdout.trim();
    return 'Command failed (${reason.isEmpty ? 'non-zero exit' : reason})'
        '${tail.isEmpty ? '' : ': $tail'}';
  }
}

/// Executes a command and returns its stdout. The cancellation
/// token lets the adapter register a teardown that closes the SSH
/// session on STOP/timeout.
typedef RunbookCommandExecutor = Future<String> Function(
  String command,
  RunbookCancellation cancellation,
);

typedef RiskGateConfirm = Future<bool> Function(
  RunbookStep step,
  String renderedCommand,
  CommandAnalysis analysis,
);

typedef PromptUserConfirm = Future<String?> Function(
  RunbookStep step,
  String? defaultValue,
);

typedef ManualWaitConfirm = Future<bool> Function(RunbookStep step);

/// Pure-Dart executor for [Runbook]s. All collaborators are
/// injectable for unit tests.
class RunbookRunner {
  RunbookRunner({
    required this.runbook,
    required this.params,
    required this.executeCommand,
    this.aiSettings,
    this.callLocalAi,
    this.riskAssessor = const CommandRiskAssessor(),
    this.confirmRiskGate,
    this.promptUser,
    this.confirmManualWait,
    Duration? defaultTimeout,
    Duration Function(int seconds)? sleepFactory,
  })  : _defaultTimeout = defaultTimeout ?? const Duration(minutes: 2),
        _sleepFactory = sleepFactory ?? _defaultSleepFactory {
    final problems = runbook.validate();
    if (problems.isNotEmpty) {
      throw RunbookSchemaException(
        'Refusing to run invalid runbook:\n  - ${problems.join("\n  - ")}',
      );
    }
  }

  final Runbook runbook;
  final Map<String, String> params;
  final RunbookCommandExecutor executeCommand;
  final AiSettings? aiSettings;
  final Future<String> Function(String prompt)? callLocalAi;
  final CommandRiskAssessor riskAssessor;
  final RiskGateConfirm? confirmRiskGate;
  final PromptUserConfirm? promptUser;
  final ManualWaitConfirm? confirmManualWait;

  final Duration _defaultTimeout;
  final Duration Function(int seconds) _sleepFactory;

  final RunbookCancellation cancellation = RunbookCancellation();

  final StreamController<RunbookEvent> _events =
      StreamController<RunbookEvent>.broadcast();

  Stream<RunbookEvent> get events => _events.stream;

  final Map<String, String> _stepStdout = {};

  Future<RunbookRunResult> run() async {
    final paramValues = Map<String, String>.from(params);
    final results = <RunbookStepResult>[];
    final startedAt = DateTime.now().toUtc();
    _events.add(RunbookStarted(runbook));

    bool cancelled = false;

    // Branch steps may jump, so cap total iterations to avoid loops.
    int ip = 0;
    int execCount = 0;
    final maxExec = runbook.steps.length * 8;

    while (ip < runbook.steps.length) {
      if (execCount++ >= maxExec) {
        cancelled = true;
        results.add(_skipResult(
          runbook.steps[ip],
          status: RunbookStepStatus.cancelled,
          summary: 'Aborted: branch loop exceeded $maxExec executions.',
        ));
        _events.add(StepFinished(results.last, ip));
        break;
      }

      final step = runbook.steps[ip];

      if (cancellation.isCancelled || cancelled) {
        cancelled = true;
        results.add(_skipResult(
          step,
          status: RunbookStepStatus.cancelled,
          summary: 'Run was cancelled before this step.',
        ));
        _events.add(StepFinished(results.last, ip));
        ip++;
        continue;
      }

      _events.add(StepStarted(step, ip));

      if (_shouldSkip(step)) {
        results.add(_skipResult(
          step,
          status: RunbookStepStatus.skipped,
          summary: 'Skipped: skipIfRegex matched referenced output.',
        ));
        _events.add(StepFinished(results.last, ip));
        ip++;
        continue;
      }

      final stepStartedAt = DateTime.now().toUtc();
      int? jumpToIndex;
      try {
        final outcome = await _runStep(
          step,
          paramValues,
          stepStartedAt,
        );
        results.add(outcome.result);
        _events.add(StepFinished(outcome.result, ip));
        if (outcome.jumpToStepId != null) {
          final idx = runbook.steps
              .indexWhere((s) => s.id == outcome.jumpToStepId);
          if (idx >= 0) jumpToIndex = idx;
        }
        final softStop =
            outcome.result.status == RunbookStepStatus.failed ||
                outcome.result.status == RunbookStepStatus.cancelled;
        if (softStop && !step.continueOnError) {
          cancelled = true;
        }
      } catch (e) {
        final r = RunbookStepResult(
          step: step,
          status: RunbookStepStatus.failed,
          startedAt: stepStartedAt,
          finishedAt: DateTime.now().toUtc(),
          error: e.toString(),
        );
        results.add(r);
        _events.add(StepFinished(r, ip));
        if (!step.continueOnError) cancelled = true;
      }

      ip = jumpToIndex ?? (ip + 1);
    }

    final anyCancelled = cancellation.isCancelled ||
        results.any((r) => r.status == RunbookStepStatus.cancelled);
    final final_ = RunbookRunResult(
      runbook: runbook,
      results: results,
      cancelled: anyCancelled,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
    );
    _events.add(RunbookFinished(final_));
    await _events.close();
    return final_;
  }

  bool _shouldSkip(RunbookStep step) {
    final pattern = step.skipIfRegex;
    if (pattern == null || pattern.isEmpty) return false;
    final refId = step.skipIfReferenceStepId;
    final source = refId == null
        ? (_stepStdout.values.isEmpty ? '' : _stepStdout.values.last)
        : (_stepStdout[refId] ?? '');
    try {
      return RegExp(pattern, multiLine: true).hasMatch(source);
    } catch (_) {
      return false;
    }
  }

  Future<_StepOutcome> _runStep(
    RunbookStep step,
    Map<String, String> params,
    DateTime startedAt,
  ) async {
    switch (step.type) {
      case RunbookStepType.command:
        return _StepOutcome(await _runCommand(step, params, startedAt));
      case RunbookStepType.promptUser:
        return _StepOutcome(await _runPrompt(step, params, startedAt));
      case RunbookStepType.waitFor:
        return _StepOutcome(await _runWait(step, startedAt));
      case RunbookStepType.aiSummarize:
        return _StepOutcome(await _runAiSummarize(step, params, startedAt));
      case RunbookStepType.notify:
        return _StepOutcome(await _runNotify(step, params, startedAt));
      case RunbookStepType.branch:
        return _runBranch(step, startedAt);
    }
  }

  _StepOutcome _runBranch(RunbookStep step, DateTime startedAt) {
    final refId = step.branchReferenceStepId;
    final source = refId == null
        ? (_stepStdout.values.isEmpty ? '' : _stepStdout.values.last)
        : (_stepStdout[refId] ?? '');
    final pattern = step.branchRegex ?? '';
    bool matched;
    String? error;
    try {
      matched = RegExp(pattern, multiLine: true).hasMatch(source);
    } catch (e) {
      matched = false;
      error = 'branchRegex did not compile: $e';
    }
    final target =
        matched ? step.branchTrueGoToStepId : step.branchFalseGoToStepId;
    return _StepOutcome(
      RunbookStepResult(
        step: step,
        status: error != null
            ? RunbookStepStatus.failed
            : RunbookStepStatus.succeeded,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        summary: error ??
            'Branch ${matched ? "matched" : "did not match"}; '
                '${target == null ? "fell through" : "jumped to $target"}.',
        error: error,
      ),
      jumpToStepId: target,
    );
  }

  Future<RunbookStepResult> _runCommand(
    RunbookStep step,
    Map<String, String> params,
    DateTime startedAt,
  ) async {
    final rendered = renderTemplate(
      step.command ?? '',
      params: params,
      stepStdout: _stepStdout,
    );

    final analysis = riskAssessor.assess(rendered);
    if (analysis.riskLevel != CommandRiskLevel.low) {
      _events.add(StepRiskGate(step, rendered, analysis));
      final ok = await (confirmRiskGate?.call(step, rendered, analysis) ??
          Future<bool>.value(false));
      if (!ok) {
        return RunbookStepResult(
          step: step,
          status: RunbookStepStatus.cancelled,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          summary: 'Risk gate refused (level '
              '${analysis.riskLevel.name.toUpperCase()}).',
        );
      }
    }

    // Per-command token, chained to the global one. Fired on timeout
    // so the executor closes the SSH session before we move on.
    final commandCancel = RunbookCancellation();
    cancellation.onCancel(commandCancel.cancel);

    final timeout = step.timeoutSeconds != null
        ? Duration(seconds: step.timeoutSeconds!)
        : _defaultTimeout;

    Future<String>? execFuture;
    try {
      execFuture = executeCommand(rendered, commandCancel);
      final stdout = await execFuture.timeout(
        timeout,
        onTimeout: () {
          commandCancel.cancel();
          throw TimeoutException('Command exceeded timeout.');
        },
      );
      _stepStdout[step.id] = stdout;
      _events.add(StepStdout(step, stdout));
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.succeeded,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        stdout: stdout,
      );
    } on RunbookCommandCancelled {
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.cancelled,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        summary: 'Command cancelled by STOP.',
      );
    } on RunbookCommandFailed catch (e) {
      // Preserve stdout so skipIf/branch refs see what ran.
      _stepStdout[step.id] = e.stdout;
      if (e.stdout.isNotEmpty) _events.add(StepStdout(step, e.stdout));
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        stdout: e.stdout,
        error: e.toString(),
      );
    } on TimeoutException {
      if (execFuture != null) {
        try {
          await execFuture;
        } catch (_) {}
      }
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        error: 'Command exceeded timeout.',
      );
    } catch (e) {
      if (cancellation.isCancelled) {
        return RunbookStepResult(
          step: step,
          status: RunbookStepStatus.cancelled,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          summary: 'Command cancelled by STOP.',
        );
      }
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        error: e.toString(),
      );
    }
  }

  Future<RunbookStepResult> _runPrompt(
    RunbookStep step,
    Map<String, String> params,
    DateTime startedAt,
  ) async {
    _events.add(StepPromptUser(step));
    final value =
        await (promptUser?.call(step, step.defaultValue) ?? Future.value(null));
    if (value == null) {
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.cancelled,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        summary: 'User aborted at prompt.',
      );
    }
    params[step.paramName ?? step.id] = value;
    return RunbookStepResult(
      step: step,
      status: RunbookStepStatus.succeeded,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      summary: 'Bound ${step.paramName} = "$value".',
    );
  }

  Future<RunbookStepResult> _runWait(
    RunbookStep step,
    DateTime startedAt,
  ) async {
    final mode = step.waitMode;
    switch (mode) {
      case 'time':
        await Future<void>.delayed(_sleepFactory(step.waitSeconds ?? 0));
        return RunbookStepResult(
          step: step,
          status: RunbookStepStatus.succeeded,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          summary: 'Slept ${step.waitSeconds}s.',
        );
      case 'manual':
        final ok = await (confirmManualWait?.call(step) ??
            Future<bool>.value(false));
        return RunbookStepResult(
          step: step,
          status: ok
              ? RunbookStepStatus.succeeded
              : RunbookStepStatus.cancelled,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          summary: ok ? 'Operator approved.' : 'Operator cancelled.',
        );
      case 'regex':
        final refId = step.waitReferenceStepId;
        final source = refId == null
            ? (_stepStdout.values.isEmpty ? '' : _stepStdout.values.last)
            : (_stepStdout[refId] ?? '');
        final pattern = step.waitRegex ?? '';
        final matched = RegExp(pattern, multiLine: true).hasMatch(source);
        return RunbookStepResult(
          step: step,
          status:
              matched ? RunbookStepStatus.succeeded : RunbookStepStatus.failed,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          summary: matched
              ? 'Pattern matched in referenced output.'
              : 'Pattern did not match referenced output.',
        );
      default:
        return RunbookStepResult(
          step: step,
          status: RunbookStepStatus.failed,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          error: 'Unknown waitMode: $mode',
        );
    }
  }

  Future<RunbookStepResult> _runAiSummarize(
    RunbookStep step,
    Map<String, String> params,
    DateTime startedAt,
  ) async {
    final refId = step.aiReferenceStepId;
    final source = refId == null
        ? (_stepStdout.values.isEmpty ? '' : _stepStdout.values.last)
        : (_stepStdout[refId] ?? '');
    final basePrompt = renderTemplate(
      step.aiPrompt ??
          'Summarize the following command output for an SRE in 3 bullets, '
              'flagging anything risky or anomalous:',
      params: params,
      stepStdout: _stepStdout,
    );
    final fullPrompt = '$basePrompt\n\n---\n$source';

    try {
      final summary = await _callLocalAi(fullPrompt);
      _stepStdout[step.id] = summary;
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.succeeded,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        summary: summary,
      );
    } catch (e) {
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        error: 'AI summary failed: $e',
      );
    }
  }

  Future<RunbookStepResult> _runNotify(
    RunbookStep step,
    Map<String, String> params,
    DateTime startedAt,
  ) async {
    final message = renderTemplate(
      step.notifyMessage ?? '',
      params: params,
      stepStdout: _stepStdout,
    );
    _events.add(StepNotify(step, message));
    return RunbookStepResult(
      step: step,
      status: RunbookStepStatus.succeeded,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      summary: message,
    );
  }

  Future<String> _callLocalAi(String prompt) async {
    if (callLocalAi != null) return callLocalAi!(prompt);
    final settings = aiSettings;
    if (settings == null) {
      throw const RunbookSchemaException(
        'No AI settings configured for aiSummarize step.',
      );
    }
    final apiKey = settings.apiKeys[settings.provider] ?? '';
    final service = AiCommandService.forProvider(
      provider: settings.provider,
      apiKey: apiKey,
      openRouterModel: settings.openRouterModel,
      localEndpoint: settings.localEndpoint,
      localModel: settings.localModel,
    );
    return service.generateChatResponse(prompt);
  }

  RunbookStepResult _skipResult(
    RunbookStep step, {
    required RunbookStepStatus status,
    String summary = '',
  }) {
    final now = DateTime.now().toUtc();
    return RunbookStepResult(
      step: step,
      status: status,
      startedAt: now,
      finishedAt: now,
      summary: summary,
    );
  }

  @visibleForTesting
  Map<String, String> get debugStepStdout => Map.unmodifiable(_stepStdout);
}

class _StepOutcome {
  _StepOutcome(this.result, {this.jumpToStepId});
  final RunbookStepResult result;
  final String? jumpToStepId;
}

/// Substitutes `{{param}}` and `{{step.id.stdout}}` tokens.
/// Unknown tokens are left intact so partial renders are visible.
String renderTemplate(
  String template, {
  required Map<String, String> params,
  required Map<String, String> stepStdout,
}) {
  final pattern = RegExp(r'\{\{\s*([\w\.]+)\s*\}\}');
  return template.replaceAllMapped(pattern, (m) {
    final token = m.group(1)!;
    if (token.startsWith('step.') && token.endsWith('.stdout')) {
      final id = token.substring(5, token.length - '.stdout'.length);
      final out = stepStdout[id];
      return out ?? m.group(0)!;
    }
    final v = params[token];
    return v ?? m.group(0)!;
  });
}

Duration _defaultSleepFactory(int seconds) => Duration(seconds: seconds);

/// Returns the list of rendered commands the runner would execute.
List<String> dryRunCommands(Runbook runbook, Map<String, String> params) {
  final out = <String>[];
  for (final step in runbook.steps) {
    if (step.type != RunbookStepType.command) continue;
    out.add(renderTemplate(
      step.command ?? '',
      params: params,
      stepStdout: const {},
    ));
  }
  return out;
}

/// Encode the run timeline as JSON for persisting or sharing.
String encodeRunResult(RunbookRunResult result) {
  return jsonEncode({
    'runbookId': result.runbook.id,
    'runbookName': result.runbook.name,
    'cancelled': result.cancelled,
    'startedAt': result.startedAt.toIso8601String(),
    'finishedAt': result.finishedAt.toIso8601String(),
    'steps': result.results
        .map(
          (r) => {
            'stepId': r.step.id,
            'label': r.step.label,
            'type': r.step.type.wireName,
            'status': r.status.name,
            'durationMs': r.duration.inMilliseconds,
            if (r.stdout.isNotEmpty) 'stdout': r.stdout,
            if (r.summary.isNotEmpty) 'summary': r.summary,
            if (r.error != null) 'error': r.error,
          },
        )
        .toList(),
  });
}
