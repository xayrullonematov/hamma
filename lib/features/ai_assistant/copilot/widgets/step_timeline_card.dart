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
        boxShadow: [
          BoxShadow(
            color: kCopilotShadowColor,
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.zero,
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                    color: stateColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (warningText != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.zero,
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
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            maxLines: null,
            onChanged: onChanged,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.panel,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: const BorderSide(color: AppColors.border, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: const BorderSide(color: AppColors.border, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: const BorderSide(
                  color: AppColors.textPrimary,
                  width: 1.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              RiskBadge(label: riskLabel, color: riskColor),
              Text(
                riskExplanation,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: isBusy ? null : onRun,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.textPrimary,
                foregroundColor: AppColors.scaffoldBackground,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              icon:
                  isRunning
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.scaffoldBackground,
                        ),
                      )
                      : const Icon(Icons.play_arrow_rounded),
              label: const Text('Run'),
            ),
          ),
        ],
      ),
    );
  }
}
