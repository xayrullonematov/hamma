import 'package:flutter/material.dart';

import '../../../core/observability/observability_explainer.dart';
import 'log_insight_view.dart';

/// Thin wrapper around [LogInsightView] for the observability flow.
/// Kept as its own type so the Health tab can reuse exactly the same
/// rendering / risk-gating that log-triage uses, while still passing
/// the metric-specific [ExplanationResult] envelope.
class ExplanationCard extends StatelessWidget {
  const ExplanationCard({
    super.key,
    required this.result,
    required this.metricName,
    this.onClose,
  });

  final ExplanationResult result;
  final String metricName;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return LogInsightView(
      insight: result.insight,
      headline: 'EXPLAIN: $metricName',
      suggestedCommandRisk: result.suggestedCommandRisk,
      onClose: onClose,
    );
  }
}
