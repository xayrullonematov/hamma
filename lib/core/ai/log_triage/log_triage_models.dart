import '../command_risk_assessor.dart';
import 'log_batcher.dart';

/// Coarse severity bucket emitted by the triage LLM for a window of log
/// lines. Drives the colour of the right-pane border in the UI.
enum TriageSeverity { normal, watch, warn, critical }

extension TriageSeverityX on TriageSeverity {
  /// Stable, lower-case wire identifier used in JSON, prefs and
  /// fingerprints. Not localised.
  String get wire {
    switch (this) {
      case TriageSeverity.normal:
        return 'normal';
      case TriageSeverity.watch:
        return 'watch';
      case TriageSeverity.warn:
        return 'warn';
      case TriageSeverity.critical:
        return 'critical';
    }
  }

  /// Display label for the brutalist severity badge.
  String get label => wire.toUpperCase();
}

TriageSeverity triageSeverityFromWire(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'critical':
      return TriageSeverity.critical;
    case 'warn':
    case 'warning':
      return TriageSeverity.warn;
    case 'watch':
      return TriageSeverity.watch;
    case 'normal':
    case 'ok':
    case 'info':
    default:
      return TriageSeverity.normal;
  }
}

/// One LLM judgement over a [LogBatch].
class LogInsight {
  const LogInsight({
    required this.severity,
    required this.summary,
    this.suggestedCommand,
    this.riskHints = const <String>[],
  });

  final TriageSeverity severity;
  final String summary;
  final String? suggestedCommand;
  final List<String> riskHints;

  /// Parses the strict JSON the triage prompt asks the LLM to return.
  /// Tolerant of missing or oddly-typed fields — falls back to NORMAL
  /// rather than throwing, so a single sloppy response can't break the
  /// stream.
  factory LogInsight.fromJson(Map<String, dynamic> json) {
    final summaryRaw = json['summary'];
    final summary = summaryRaw is String ? summaryRaw.trim() : '';

    final cmdRaw = json['suggestedCommand'] ?? json['suggested_command'];
    String? cmd;
    if (cmdRaw is String && cmdRaw.trim().isNotEmpty) {
      cmd = cmdRaw.trim();
    }

    final hintsRaw = json['riskHints'] ?? json['risk_hints'];
    final hints = <String>[];
    if (hintsRaw is List) {
      for (final h in hintsRaw) {
        if (h == null) continue;
        final s = h.toString().trim();
        if (s.isNotEmpty) hints.add(s);
      }
    }

    return LogInsight(
      severity: triageSeverityFromWire(json['severity']?.toString()),
      summary: summary,
      suggestedCommand: cmd,
      riskHints: List<String>.unmodifiable(hints),
    );
  }

  /// Stable fingerprint used by the mute system. Combines severity
  /// with a normalised version of the summary so cosmetic differences
  /// (case, punctuation, repeated whitespace, trailing periods) don't
  /// produce different fingerprints.
  String get fingerprint => fingerprintFor(severity, summary);

  static String fingerprintFor(TriageSeverity severity, String summary) {
    final normalised = summary
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${severity.wire}::$normalised';
  }
}

/// One emission from `LogTriageService.watch()`. Carries the insight,
/// the originating batch, and the assessor's view on the suggested
/// command (if any) so the UI can gate execution.
class InsightUpdate {
  const InsightUpdate({
    required this.insight,
    required this.batch,
    required this.muted,
    this.suggestedCommandRisk,
  });

  final LogInsight insight;
  final LogBatch batch;
  final bool muted;

  /// Result of [CommandRiskAssessor.assessFast] applied to
  /// `insight.suggestedCommand`. `null` when there is no suggested
  /// command or the fast pass found nothing dangerous (i.e. safe to
  /// surface as a one-tap suggestion). When this is `critical`, the
  /// UI must NOT offer a one-tap run button.
  final CommandRiskLevel? suggestedCommandRisk;

  bool get hasSuggestedCommand =>
      (insight.suggestedCommand ?? '').trim().isNotEmpty;

  bool get suggestedCommandIsCritical =>
      suggestedCommandRisk == CommandRiskLevel.critical;
}

/// Thrown when the triage service is misused — most importantly, when
/// the AI provider isn't a local one. Triage MUST stay loopback-only;
/// surfacing this exception is preferable to silently shipping log
/// lines off-device.
class LogTriageException implements Exception {
  const LogTriageException(this.message);
  final String message;
  @override
  String toString() => 'LogTriageException: $message';
}
