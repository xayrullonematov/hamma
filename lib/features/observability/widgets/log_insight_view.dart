import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/ai/command_risk_assessor.dart';
import '../../../core/ai/log_triage/log_triage_models.dart';
import '../../../core/theme/app_colors.dart';

/// Shared brutalist renderer for a [LogInsight] payload.
///
/// Used by both the log-triage flow and the observability "Explain
/// this spike" flow so a single parser/UI pair owns the severity
/// badge, summary, suggested-command card (with [CommandRiskAssessor]
/// gating), and risk hints — keeping copy / safety behaviour
/// identical no matter where the insight came from.
class LogInsightView extends StatelessWidget {
  const LogInsightView({
    super.key,
    required this.insight,
    required this.headline,
    this.suggestedCommandRisk,
    this.onClose,
  });

  final LogInsight insight;
  final String headline;
  final CommandRiskLevel? suggestedCommandRisk;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final severity = insight.severity.label;
    final color = _colorFor(severity);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: color, width: 1),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(border: Border.all(color: color)),
                child: Text(
                  severity,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    letterSpacing: 1.4,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    letterSpacing: 1.4,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(
                    Icons.close,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            insight.summary.isEmpty ? '(no summary)' : insight.summary,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if ((insight.suggestedCommand ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _SuggestedCommandBlock(
              command: insight.suggestedCommand!,
              risk: suggestedCommandRisk,
            ),
          ],
          if (insight.riskHints.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final h in insight.riskHints)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• $h',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static Color _colorFor(String severity) {
    switch (severity) {
      case 'CRITICAL':
      case 'WARN':
        return AppColors.danger;
      case 'WATCH':
        return AppColors.accent;
      default:
        return AppColors.textMuted;
    }
  }
}

class _SuggestedCommandBlock extends StatelessWidget {
  const _SuggestedCommandBlock({required this.command, required this.risk});

  final String command;
  final CommandRiskLevel? risk;

  @override
  Widget build(BuildContext context) {
    final blocked = risk == CommandRiskLevel.critical ||
        risk == CommandRiskLevel.high;
    final critical = risk == CommandRiskLevel.critical;
    final color = blocked ? AppColors.danger : AppColors.accent;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            blocked
                ? (critical ? 'BLOCKED — CRITICAL RISK' : 'BLOCKED — HIGH RISK')
                : 'SUGGESTED COMMAND',
            style: TextStyle(
              color: color,
              fontSize: 9,
              letterSpacing: 1.4,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            command,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (!blocked)
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 12),
                  label: const Text('COPY'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 28),
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
