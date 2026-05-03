import 'dart:async';

import '../../storage/log_triage_prefs.dart';
import '../ai_command_service.dart';
import '../ai_provider.dart';
import '../command_risk_assessor.dart';
import 'log_batcher.dart';
import 'log_triage_models.dart';

/// Runs each [LogBatch] through the local LLM and emits a structured
/// [InsightUpdate].
///
/// Zero-trust contract:
///   - The constructor refuses any non-local [AiCommandService]. Cloud
///     providers must be turned away at the call site (UI shows the
///     "Local AI required" banner) so log lines never leave loopback.
///
/// The service is stateless apart from the in-memory mute set seeded
/// from [LogTriagePrefs] on construction; persistence updates flow
/// through the same prefs object so other surfaces stay in sync.
class LogTriageService {
  LogTriageService._({
    required AiCommandService aiService,
    required LogTriagePrefs prefs,
    required Set<String> mutedFingerprints,
  })  : _ai = aiService,
        _prefs = prefs,
        _muted = mutedFingerprints;

  /// Builds the service after loading persisted mutes. Throws
  /// [LogTriageException] if [aiService] is not configured for the
  /// local provider.
  static Future<LogTriageService> create({
    required AiCommandService aiService,
    LogTriagePrefs? prefs,
  }) async {
    if (aiService.config.provider != AiProvider.local) {
      throw const LogTriageException(
        'Log triage requires the Local AI provider. Cloud providers '
        'are refused so log lines never leave the device.',
      );
    }
    final p = prefs ?? const LogTriagePrefs();
    final muted = await p.loadMutedFingerprints();
    return LogTriageService._(
      aiService: aiService,
      prefs: p,
      mutedFingerprints: muted,
    );
  }

  final AiCommandService _ai;
  final LogTriagePrefs _prefs;
  final Set<String> _muted;

  static const _systemInstruction =
      'You are a Linux observability assistant. You will receive a '
      'window of recent log lines from a server. '
      'Identify the single most concerning pattern (error spike, '
      'repeated stack trace, OOM, auth failures, restart loop, etc.). '
      'If nothing stands out, report severity NORMAL. '
      'You MUST return strictly valid JSON matching this schema: '
      '{ "severity": "normal|watch|warn|critical", '
      '"summary": "<one sentence describing the pattern, or \'no anomalies\' for NORMAL>", '
      '"suggestedCommand": "<a single safe shell command to investigate, or null>", '
      '"riskHints": ["<short hint about what the command does, may be empty>"] }. '
      'Never suggest destructive commands (rm -rf, mkfs, dd, etc.).';

  /// Snapshot of the muted fingerprint set. Reads only — mutate via
  /// [mute] / [unmute].
  Set<String> get mutedFingerprints => Set.unmodifiable(_muted);

  /// Subscribes to a stream of [LogBatch]es and emits one
  /// [InsightUpdate] per batch.
  ///
  /// Failures while triaging a batch are swallowed (logged via
  /// `addError`) so a single bad LLM round-trip doesn't tear down the
  /// watch session — the next batch gets a fresh chance.
  Stream<InsightUpdate> watch(Stream<LogBatch> batches) {
    final controller = StreamController<InsightUpdate>();
    StreamSubscription<LogBatch>? sub;

    // We process batches *sequentially* via a single tail-of-the-chain
    // future. This guarantees:
    //   1. Insight order matches batch order (no out-of-order delivery
    //      when the model is slow on one batch and fast on the next).
    //   2. There is at most one in-flight LLM round-trip per session,
    //      bounding memory and avoiding "thundering herd" against a
    //      local engine that's already CPU-bound.
    //   3. We have a single Future to await on close/cancel so the
    //      output controller doesn't shut before the final batch's
    //      insight has been delivered.
    Future<void> chain = Future<void>.value();
    var cancelled = false;
    var upstreamDone = false;

    Future<void> tryClose() async {
      if (upstreamDone && !controller.isClosed) {
        await controller.close();
      }
    }

    void enqueue(LogBatch batch) {
      chain = chain.then((_) async {
        if (cancelled || controller.isClosed) return;
        try {
          final update = await triageBatch(batch);
          if (cancelled || controller.isClosed) return;
          controller.add(update);
        } catch (e, st) {
          if (cancelled || controller.isClosed) return;
          controller.addError(e, st);
        }
      });
    }

    controller.onListen = () {
      sub = batches.listen(
        enqueue,
        onError: (Object e, StackTrace st) {
          if (!controller.isClosed) controller.addError(e, st);
        },
        onDone: () {
          upstreamDone = true;
          // Drain whatever is queued, then close.
          chain = chain.then((_) => tryClose());
        },
        cancelOnError: false,
      );
    };
    controller.onCancel = () async {
      cancelled = true;
      await sub?.cancel();
      // Wait for any in-flight triage to settle so we don't leave a
      // zombie LLM request scribbling onto a closed controller.
      await chain;
    };
    controller.onPause = () => sub?.pause();
    controller.onResume = () => sub?.resume();
    return controller.stream;
  }

  /// Triage a single batch. Public so callers can also drive the
  /// pipeline imperatively (e.g. "Re-analyse last window").
  Future<InsightUpdate> triageBatch(LogBatch batch) async {
    final prompt = _buildPrompt(batch);
    final raw = await _ai.generateChatResponse(
      prompt,
      history: [
        {'role': 'system', 'content': _systemInstruction},
      ],
    );

    final json = AiCommandService.parseJsonFromResponse(raw);
    if (json == null) {
      throw const LogTriageException(
        'Local AI returned a non-JSON response for log triage. '
        'Try a stricter / more capable model.',
      );
    }
    final insight = LogInsight.fromJson(json);

    CommandRiskLevel? cmdRisk;
    final cmd = insight.suggestedCommand;
    if (cmd != null && cmd.trim().isNotEmpty) {
      // Fast pass only — this is the same gate the copilot uses to
      // refuse one-tap execution of dangerous suggestions. A `null`
      // result means "no obviously-dangerous pattern matched", so the
      // UI may surface the run button.
      cmdRisk = CommandRiskAssessor.assessFast(cmd);
    }

    return InsightUpdate(
      insight: insight,
      batch: batch,
      muted: _muted.contains(insight.fingerprint),
      suggestedCommandRisk: cmdRisk,
    );
  }

  String _buildPrompt(LogBatch batch) {
    final buf = StringBuffer();
    buf.writeln(
      'Recent log window (${batch.lineCount} lines, '
      'spanning ${batch.duration.inSeconds}s):',
    );
    buf.writeln('---');
    // Cap each line so a single 10-MB stack trace can't blow the
    // model's context window. 2000 chars per line is plenty for any
    // real syslog / app log line.
    for (final line in batch.lines) {
      if (line.length > 2000) {
        buf.writeln('${line.substring(0, 2000)}…[truncated]');
      } else {
        buf.writeln(line);
      }
    }
    buf.writeln('---');
    buf.writeln(
      'Return JSON only, no prose. Use NORMAL severity if nothing is wrong.',
    );
    return buf.toString();
  }

  Future<void> mute(String fingerprint) async {
    if (fingerprint.trim().isEmpty) return;
    _muted.add(fingerprint);
    await _prefs.mute(fingerprint);
  }

  Future<void> unmute(String fingerprint) async {
    if (_muted.remove(fingerprint)) {
      await _prefs.unmute(fingerprint);
    }
  }

  bool isMuted(String fingerprint) => _muted.contains(fingerprint);
}
