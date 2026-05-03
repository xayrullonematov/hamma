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
/// Note on semantics: the runner currently waits for the in-flight
/// command to finish before honouring cancellation (it uses the
/// blocking `SshService.execute` API). All subsequent steps are
/// then skipped with [RunbookStepStatus.cancelled]. This matches
/// the documented behaviour in `docs/runbooks.md`.
class RunbookCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

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
  /// returns its stdout. Defaults to `SshService.execute` in
  /// production; tests inject a fake.
  final Future<String> Function(String command) executeCommand;

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

    for (var i = 0; i < runbook.steps.length; i++) {
      final step = runbook.steps[i];

      if (cancellation.isCancelled || cancelled) {
        cancelled = true;
        results.add(_skipResult(
          step,
          status: RunbookStepStatus.cancelled,
          summary: 'Run was cancelled before this step.',
        ));
        _events.add(StepFinished(results.last, i));
        continue;
      }

      _events.add(StepStarted(step, i));

      // Conditional skip — applies regardless of step type.
      if (_shouldSkip(step)) {
        results.add(_skipResult(
          step,
          status: RunbookStepStatus.skipped,
          summary: 'Skipped: skipIfRegex matched referenced output.',
        ));
        _events.add(StepFinished(results.last, i));
        continue;
      }

      final stepStartedAt = DateTime.now().toUtc();
      try {
        final result = await _runStep(
          step,
          paramValues,
          stepStartedAt,
        );
        results.add(result);
        _events.add(StepFinished(result, i));
        // continueOnError applies to BOTH `failed` and `cancelled`
        // (e.g. a risk-gate refusal). The hard STOP button (the
        // global cancellation token) bypasses this — it's checked
        // at the top of the next loop iteration regardless.
        final softStop = result.status == RunbookStepStatus.failed ||
            result.status == RunbookStepStatus.cancelled;
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
        _events.add(StepFinished(r, i));
        if (!step.continueOnError) cancelled = true;
      }
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

  Future<RunbookStepResult> _runStep(
    RunbookStep step,
    Map<String, String> params,
    DateTime startedAt,
  ) async {
    switch (step.type) {
      case RunbookStepType.command:
        return _runCommand(step, params, startedAt);
      case RunbookStepType.promptUser:
        return _runPrompt(step, params, startedAt);
      case RunbookStepType.waitFor:
        return _runWait(step, startedAt);
      case RunbookStepType.aiSummarize:
        return _runAiSummarize(step, params, startedAt);
      case RunbookStepType.notify:
        return _runNotify(step, params, startedAt);
    }
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
      final stdout = await executeCommand(rendered).timeout(timeout);
      _stepStdout[step.id] = stdout;
      _events.add(StepStdout(step, stdout));
      return RunbookStepResult(
        step: step,
        status: RunbookStepStatus.succeeded,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        stdout: stdout,
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
            'type': r.step.type.name,
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
