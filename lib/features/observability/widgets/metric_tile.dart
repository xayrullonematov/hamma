import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import 'sparkline.dart';

/// Single brutalist metric tile: label, big value, sparkline, optional
/// anomaly badge + action buttons.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.history,
    this.subtitle,
    this.anomalous = false,
    this.yMax,
    this.onExpand,
    this.onExplain,
    this.onWatch,
    this.explainBusy = false,
  });

  final String label;
  final String value;
  final String unit;
  final List<double> history;
  final String? subtitle;
  final bool anomalous;
  final double? yMax;
  final VoidCallback? onExpand;
  final VoidCallback? onExplain;
  final VoidCallback? onWatch;
  final bool explainBusy;

  @override
  Widget build(BuildContext context) {
    final borderColor = anomalous ? AppColors.danger : AppColors.border;
    return InkWell(
      onTap: onExpand,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: borderColor, width: 1),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label.toUpperCase(),
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
                if (anomalous)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.danger),
                    ),
                    child: const Text(
                      'ANOMALY',
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 8,
                        letterSpacing: 1.3,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  subtitle!,
                  style: const TextStyle(
                    color: AppColors.textFaint,
                    fontSize: 10,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Sparkline(values: history, anomalous: anomalous, yMax: yMax),
            if (onExplain != null || onWatch != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (onExplain != null)
                    _TileButton(
                      label: explainBusy ? 'EXPLAINING…' : 'EXPLAIN',
                      onTap: explainBusy ? null : onExplain,
                      emphasised: anomalous,
                    ),
                  if (onExplain != null && onWatch != null)
                    const SizedBox(width: 6),
                  if (onWatch != null)
                    _TileButton(label: 'WATCH', onTap: onWatch),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TileButton extends StatelessWidget {
  const _TileButton({
    required this.label,
    required this.onTap,
    this.emphasised = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? AppColors.textFaint
        : (emphasised ? AppColors.danger : AppColors.textPrimary);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 9,
            letterSpacing: 1.4,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
