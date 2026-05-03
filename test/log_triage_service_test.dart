import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/ai/command_risk_assessor.dart';
import 'package:hamma/core/ai/log_triage/log_batcher.dart';
import 'package:hamma/core/ai/log_triage/log_triage_models.dart';

void main() {
  group('LogInsight.fromJson', () {
    test('parses a fully-populated payload', () {
      final insight = LogInsight.fromJson({
        'severity': 'critical',
        'summary': 'OOM killer reaped postgres twice in 30s.',
        'suggestedCommand': 'systemctl status postgresql',
        'riskHints': ['Read-only — safe to run.'],
      });
      expect(insight.severity, TriageSeverity.critical);
      expect(insight.summary, contains('OOM killer'));
      expect(insight.suggestedCommand, 'systemctl status postgresql');
      expect(insight.riskHints, hasLength(1));
    });

    test('snake_case field names are accepted (model variance)', () {
      final insight = LogInsight.fromJson({
        'severity': 'warn',
        'summary': 'auth failures spiking',
        'suggested_command': 'lastb -n 20',
        'risk_hints': ['Read-only.'],
      });
      expect(insight.severity, TriageSeverity.warn);
      expect(insight.suggestedCommand, 'lastb -n 20');
      expect(insight.riskHints, ['Read-only.']);
    });

    test('falls back to NORMAL on unknown severity strings', () {
      final insight = LogInsight.fromJson({
        'severity': 'spicy',
        'summary': 'whatever',
      });
      expect(insight.severity, TriageSeverity.normal);
    });

    test('missing optional fields produce a safe insight', () {
      final insight = LogInsight.fromJson({'severity': 'watch'});
      expect(insight.severity, TriageSeverity.watch);
      expect(insight.summary, '');
      expect(insight.suggestedCommand, isNull);
      expect(insight.riskHints, isEmpty);
    });

    test('blank/whitespace suggestedCommand is normalised to null', () {
      final insight = LogInsight.fromJson({
        'severity': 'normal',
        'summary': 'all good',
        'suggestedCommand': '   ',
      });
      expect(insight.suggestedCommand, isNull);
    });
  });

  group('LogInsight.fingerprint', () {
    test('is stable across cosmetic differences in summary', () {
      final a = LogInsight.fromJson({
        'severity': 'warn',
        'summary': 'Auth failures spiking on sshd!!',
      });
      final b = LogInsight.fromJson({
        'severity': 'warn',
        'summary': '  auth   failures spiking on sshd  ',
      });
      expect(a.fingerprint, b.fingerprint);
    });

    test('differs when severity changes', () {
      final a = LogInsight.fromJson({
        'severity': 'warn',
        'summary': 'auth failures spiking',
      });
      final b = LogInsight.fromJson({
        'severity': 'critical',
        'summary': 'auth failures spiking',
      });
      expect(a.fingerprint, isNot(b.fingerprint));
    });
  });

  group('InsightUpdate command-risk gating', () {
    LogBatch dummyBatch() => LogBatch(
          lines: const ['x'],
          startedAt: DateTime.utc(2024, 1, 1),
          endedAt: DateTime.utc(2024, 1, 1, 0, 0, 1),
        );

    test('treats a critical fast-assessment as blocked', () {
      final insight = LogInsight.fromJson({
        'severity': 'warn',
        'summary': 'rogue cleanup recommended',
        'suggestedCommand': 'rm -rf /var/log',
      });
      // Sanity: the assessor itself flags this command as critical.
      expect(
        CommandRiskAssessor.assessFast(insight.suggestedCommand!),
        CommandRiskLevel.critical,
      );
      final update = InsightUpdate(
        insight: insight,
        batch: dummyBatch(),
        muted: false,
        suggestedCommandRisk: CommandRiskLevel.critical,
      );
      expect(update.suggestedCommandIsCritical, isTrue);
      expect(update.hasSuggestedCommand, isTrue);
    });

    test('safe suggestion passes the gate', () {
      const cmd = 'systemctl status nginx';
      expect(CommandRiskAssessor.assessFast(cmd), isNull);
      final insight = LogInsight.fromJson({
        'severity': 'watch',
        'summary': 'investigate nginx',
        'suggestedCommand': cmd,
      });
      final update = InsightUpdate(
        insight: insight,
        batch: dummyBatch(),
        muted: false,
        suggestedCommandRisk: null,
      );
      expect(update.suggestedCommandIsCritical, isFalse);
      expect(update.hasSuggestedCommand, isTrue);
    });

    test('no suggestion → hasSuggestedCommand=false regardless of risk', () {
      final insight = LogInsight.fromJson({
        'severity': 'normal',
        'summary': 'all good',
      });
      final update = InsightUpdate(
        insight: insight,
        batch: dummyBatch(),
        muted: false,
        suggestedCommandRisk: null,
      );
      expect(update.hasSuggestedCommand, isFalse);
    });
  });
}
