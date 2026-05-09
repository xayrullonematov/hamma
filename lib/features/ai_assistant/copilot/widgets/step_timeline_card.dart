import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import 'copilot_chrome.dart';

class StepTimelineCard extends StatelessWidget {
  const StepTimelineCard({
    super.key,
    required this.title,
    required this.controller,
    required this.stateLabel,
    required this.stateColor,
    required this.riskLabel,
    required this.riskColor,
    required this.riskExplanation,
    required this.warningText,
    required this.isRunning,
    required this.isBusy,
    required this.onChanged,
    required this.onRun,
  });

  final String title;
  final TextEditingController controller;
  final String stateLabel;
  final Color stateColor;
  final String riskLabel;
  final Color riskColor;
  final String riskExplanation;
  final String? warningText;
  final bool isRunning;
  final bool isBusy;
  final ValueChanged<String> onChanged;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.zero,
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                stateLabel,
                style: TextStyle(
                  color: stateColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          if (warningText != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.1),
                border: Border.all(color: AppColors.danger.withValues(alpha: 0.2)),
              ),
              child: Text(
                warningText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: null,
            onChanged: onChanged,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.panel,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: AppColors.border, width: 0.5),
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: AppColors.border, width: 0.5),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(
                  color: AppColors.textPrimary,
                  width: 0.8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RiskBadge(label: riskLabel, color: riskColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  riskExplanation,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                    height: 1.4,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: isBusy ? null : onRun,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.border, width: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              icon:
                  isRunning
                      ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppColors.textPrimary,
                        ),
                      )
                      : const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text(
                'RUN',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
