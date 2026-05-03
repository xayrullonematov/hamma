import 'dart:convert';

import '../ai/ai_command_service.dart';
import '../ai/ai_provider.dart';
import '../ai/command_risk_assessor.dart';
import '../ai/log_triage/log_triage_models.dart';
import '../ssh/ssh_service.dart';
import 'metric_snapshot.dart';
import 'rolling_buffer.dart';

/// Result of one "Explain this spike" call. Wraps a [LogInsight] (so
/// the UI can re-use the same card the log-triage screen already
/// renders) plus the assessor's verdict on the suggested command.
class ExplanationResult {
  const ExplanationResult({
    required this.insight,
    this.suggestedCommandRisk,
  });

  final LogInsight insight;
  final CommandRiskLevel? suggestedCommandRisk;

  bool get suggestedCommandIsCritical =>
      suggestedCommandRisk == CommandRiskLevel.critical;
}

/// Thrown when the explainer is invoked with a non-local AI provider.
/// Mirrors the [LogTriageException] contract — surfacing this is
/// preferable to silently shipping host metrics + log lines off-device.
class ObservabilityExplainerException implements Exception {
  const ObservabilityExplainerException(this.message);
  final String message;
  @override
  String toString() => 'ObservabilityExplainerException: $message';
}

/// Builds the prompt payload for the local LLM and parses the strict
/// JSON response into a [LogInsight].
///
/// Zero-trust: refuses any provider other than [AiProvider.local].
class ObservabilityExplainer {
  ObservabilityExplainer({
    required this.ai,
    required this.provider,
    required this.sshService,
    this.logTailLines = 200,
  });

  final AiCommandService ai;
  final AiProvider provider;
  final SshService sshService;
  final int logTailLines;

  Future<ExplanationResult> explain({
    required String metricName,
    required RollingBuffer buffer,
    required String unit,
    Duration pollInterval = const Duration(seconds: 5),
    Duration windowDuration = const Duration(minutes: 10),
    HostCapabilities? capabilities,
  }) async {
    if (provider != AiProvider.local) {
      throw const ObservabilityExplainerException(
        'Local AI required: explainer refuses to ship host metrics off-device.',
      );
    }

    // Time-based window: ~last [windowDuration] worth of samples,
    // converted to a count via the actual current poll cadence so
    // the prompt always carries a consistent wall-clock slice
    // regardless of whether the user is polling every 2 s or 30 s.
    final intervalSecs = pollInterval.inSeconds <= 0
        ? 5
        : pollInterval.inSeconds;
    final windowCount =
        (windowDuration.inSeconds ~/ intervalSecs).clamp(20, buffer.capacity);
    final window = buffer.tail(windowCount);
    final logTail = await _fetchLogTail();

    final prompt = _buildPrompt(
      metricName: metricName,
      unit: unit,
      window: window,
      logTail: logTail,
    );

    final raw = await ai.generateChatResponse(prompt);
    final json = _extractJson(raw);
    final insight = LogInsight.fromJson(json);
    final cmd = insight.suggestedCommand?.trim();
    final risk = (cmd == null || cmd.isEmpty)
        ? null
        : CommandRiskAssessor.assessFast(cmd);
    return ExplanationResult(insight: insight, suggestedCommandRisk: risk);
  }

  Future<String> _fetchLogTail() async {
    // Try journalctl first, fall back to syslog. We deliberately do
    // both reads silently — a missing journal is normal on Alpine /
    // some embedded boxes, and the explainer should still produce
    // useful output from metrics alone in that case.
    try {
      final j = await sshService
          .execute('journalctl -n $logTailLines --no-pager 2>/dev/null');
      if (j.trim().isNotEmpty) return j;
    } catch (_) {}
    try {
      final s = await sshService
          .execute('tail -n $logTailLines /var/log/syslog 2>/dev/null');
      if (s.trim().isNotEmpty) return s;
    } catch (_) {}
    return '';
  }

  String _buildPrompt({
    required String metricName,
    required String unit,
    required List<({DateTime t, double v})> window,
    required String logTail,
  }) {
    final samples = window
        .map((s) => '${s.t.toUtc().toIso8601String()}\t${s.v.toStringAsFixed(2)}')
        .join('\n');
    final logBlock = logTail.trim().isEmpty
        ? '(no log tail available — metrics only)'
        : logTail;
    return '''
You are a Linux SRE assistant running ENTIRELY on the operator's local machine. Diagnose a sudden change in a host metric.

Metric: $metricName ($unit)
Recent samples (UTC timestamp <TAB> value, oldest first, ~one per poll interval):
$samples

Recent system log tail (most recent last):
---
$logBlock
---

Return a single JSON object and NOTHING else. Schema:
{
  "severity": "normal" | "watch" | "warn" | "critical",
  "summary": "<one or two sentences explaining the most likely cause>",
  "suggestedCommand": "<a single safe shell command the operator can run to investigate, or omit>",
  "riskHints": ["<short note about what the command does or why it's safe>"]
}

Rules:
- "summary" must be concrete and reference the metric trend.
- "suggestedCommand" must be read-only or status-only (e.g. systemctl status, ps, journalctl, top -bn1). Never suggest destructive commands.
- If the trend looks normal or the data is too sparse to call, return severity "normal" and say so.
''';
  }

  /// Tolerant JSON extraction — local models occasionally wrap the
  /// JSON in markdown fences or prepend a chatty preamble. We pick
  /// the first balanced `{...}` block.
  static Map<String, dynamic> _extractJson(String raw) {
    final trimmed = raw.trim();
    final start = trimmed.indexOf('{');
    if (start < 0) return const {'severity': 'normal', 'summary': ''};
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < trimmed.length; i++) {
      final c = trimmed[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == r'\') {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) {
          final block = trimmed.substring(start, i + 1);
          try {
            final decoded = jsonDecode(block);
            if (decoded is Map<String, dynamic>) return decoded;
          } catch (_) {}
          break;
        }
      }
    }
    return const {'severity': 'normal', 'summary': ''};
  }
}
