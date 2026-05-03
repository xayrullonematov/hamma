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

/// Cooperative cancellation token. Read by [RunbookRunner] between
/// steps; `cancel()` may be invoked from the UI's STOP button.
///
/// In addition to the polled `isCancelled` flag the token exposes
/// [onCancel] so the SSH adapter (or any other long-running
/// resource holder) can register a teardown callback. When STOP is
/// pressed the runner fires every registered callback before
/// returning, which is what kills the in-flight SSH session
/// cleanly rather than waiting for the remote command to drain.
class RunbookCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  final List<void Function()> _listeners = [];

  /// Register a callback to fire as soon as [cancel] is called. If
  /// [cancel] has already fired the callback runs immediately.
  void onCancel(void Function() listener) {
    if (_cancelled) {
      try {
        listener();
      } catch (_) {/* listener errors must not break the runner */}
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
      } catch (_) {/* ignore */}
    }
  }
}

/// Thrown by an [RunbookCommandExecutor] to signal the in-flight
/// command was killed because the user pressed STOP. The runner
/// maps this to [RunbookStepStatus.cancelled] without surfacing it
/// as an error.
class RunbookCommandCancelled implements Exception {
  const RunbookCommandCancelled();
  @override
  String toString() => 'RunbookCommandCancelled';
}

/// Thrown by an [RunbookCommandExecutor] when the underlying remote
/// command exited with a non-zero status (or was killed by a signal).
/// `dartssh2`'s `SSHSession.done` future completes on channel close
/// and does NOT fail on a non-zero exit, so the SSH adapter must
/// inspect `session.exitCode` / `session.exitSignal` itself and raise
/// this exception on failure — without it the runner would mark
/// failed deploys / restarts as succeeded and continue running
/// subsequent steps. The runner maps this to
/// [RunbookStepStatus.failed] (subject to `continueOnError`) and
/// preserves [stdout] / [stderr] in the resulting
/// [RunbookStepResult] so the UI can show the operator exactly what
/// the remote produced before failing.
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

/// Function signature the runner uses to execute a command. The
/// second argument is the runner's [RunbookCancellation] so the
/// adapter can register a teardown callback (see
/// [RunbookCancellation.onCancel]) and kill any underlying SSH
/// session immediately when the user presses STOP.
typedef RunbookCommandExecutor = Future<String> Function(
  String command,
  RunbookCancellation cancellation,
);

/// Callback the UI installs to confirm risk-gated commands. Return
/// `true` to proceed, `false` to abort the runbook.
typedef RiskGateConfirm = Future<bool> Function(
  RunbookStep step,
  String renderedCommand,
  CommandAnalysis analysis,
);

/// Callback the UI installs for `promptUser` steps. Return the value
/// to bind to [RunbookStep.paramName], or `null` to abort.
typedef PromptUserConfirm = Future<String?> Function(
  RunbookStep step,
  String? defaultValue,
);

/// Callback for `manual` waitFor steps. Return `true` to continue,
/// `false` to abort.
typedef ManualWaitConfirm = Future<bool> Function(RunbookStep step);

/// Pure-Dart executor for [Runbook]s.
///
/// Construction parameters are all injectable so the runner is fully
/// unit-testable against fakes (see test/runbook_runner_test.dart).
/// In production the dashboard wires it up against the real
/// [SshService] for the active server and the active [AiSettings].
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

  /// Initial values for [Runbook.params]. May be augmented at runtime
  /// by `promptUser` steps. The runner copies this map so the caller
  /// is free to keep the original around for retries.
  final Map<String, String> params;

  /// Executes the command on a real (or fake) SSH session and
  /// returns its stdout. The second argument is the runner's
  /// cancellation token: the adapter is expected to register an
  /// `onCancel` listener so STOP can kill the in-flight session.
  final RunbookCommandExecutor executeCommand;

  /// AI configuration used by `aiSummarize` steps. Optional — if
  /// absent the steps are skipped with a placeholder summary.
  final AiSettings? aiSettings;

  /// Override hook for unit tests so they can fake the LLM call
  /// without bringing up the real `AiCommandService`. Production
  /// leaves this null and the runner builds a service from
  /// [aiSettings].
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

  /// Live event feed. Subscribe BEFORE calling [run] so the
  /// `RunbookStarted` event isn't missed.
  Stream<RunbookEvent> get events => _events.stream;

  /// Captured stdout, keyed by step id, for `{{step.id.stdout}}`
  /// interpolation and skipIf evaluation.
  final Map<String, String> _stepStdout = {};

  Future<RunbookRunResult> run() async {
    final paramValues = Map<String, String>.from(params);
    final results = <RunbookStepResult>[];
    final startedAt = DateTime.now().toUtc();
    _events.add(RunbookStarted(runbook));

    bool cancelled = false;

    // The runner walks an instruction pointer rather than a plain
    // for-loop because `branch` steps can jump forward or backward.
    // We cap at `steps.length * 8` total step executions so a
    // pathological runbook (e.g. an infinite loop branch) halts
    // loudly with a cancellation rather than spinning forever.
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

      // Conditional skip — applies regardless of step type.
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
        // continueOnError applies to BOTH `failed` and `cancelled`
        // (e.g. a risk-gate refusal). The hard STOP button (the
        // global cancellation token) bypasses this — it's checked
        // at the top of the next loop iteration regardless.
        final softStop =
            outcome.result.status == RunbookStepStatus.failed ||
                outcome.result.status == RunbookStepStatus.cancelled;
        if (softStop && !step.continueOnError) {
          cancelled = true;
        }
      } catch (e) {
        // Defensive: the step runner itself shouldn't throw, but if
        // it does we surface it as a failed step rather than letting
        // the runbook crash mid-flight.
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

    // Final `cancelled` reflects ANY non-success exit path, not
    // just the STOP button: a risk-gate refusal or a prompt abort
    // also count.
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

    try {
      final timeout = step.timeoutSeconds != null
          ? Duration(seconds: step.timeoutSeconds!)
          : _defaultTimeout;
      final stdout =
          await executeCommand(rendered, cancellation).timeout(timeout);
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
      // STOP button reached the SSH adapter and killed the session
      // cleanly. Surface as cancelled, not failed.
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.cancelled,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        summary: 'Command cancelled by STOP.',
      );
    } on RunbookCommandFailed catch (e) {
      // Remote command exited non-zero. Preserve whatever stdout
      // we DID collect so the operator can see how far the script
      // got before failing — this is critical context for runbook
      // recovery branches that key off prior output.
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
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        error: 'Command exceeded timeout.',
      );
    } catch (e) {
      // If the user pressed STOP mid-command and the SSH session
      // surfaced the close as a generic error, treat it as
      // cancelled rather than a real failure.
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

  /// Test-only access to the captured per-step stdout map.
  @visibleForTesting
  Map<String, String> get debugStepStdout => Map.unmodifiable(_stepStdout);
}

/// Internal helper: a step's [RunbookStepResult] plus an optional
/// jump target id (only branch steps use this).
class _StepOutcome {
  _StepOutcome(this.result, {this.jumpToStepId});
  final RunbookStepResult result;
  final String? jumpToStepId;
}

/// Replace `{{paramName}}` with the matching param value and
/// `{{step.id.stdout}}` with the captured stdout from a previous
/// step. Unknown tokens are left intact (the runner treats this as a
/// runtime warning rather than a hard failure so partially-rendered
/// commands are visible in the UI).
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

/// Helper used by the dry-run editor button: returns the list of
/// fully-rendered commands the runner WOULD execute, in order, with
/// no SSH side effects.
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

// JSON helpers ----------------------------------------------------------------

/// Encode the run timeline so the post-run summary screen can persist
/// or share it (one-tap "save outputs as snippet" lives in the UI).
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
