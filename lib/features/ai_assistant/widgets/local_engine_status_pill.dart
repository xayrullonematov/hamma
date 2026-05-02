import 'package:flutter/material.dart';

import '../../../core/ai/local_engine_health_monitor.dart';
import '../../../core/theme/app_colors.dart';

/// Brutalist pill showing the live status of the configured local AI
/// engine. Designed to sit in the AI assistant / copilot header.
///
/// The pill is purely a presenter: it expects an externally-managed
/// [LocalEngineHealthMonitor] (so multiple surfaces can share one timer
/// and one HTTP cycle).
class LocalEngineStatusPill extends StatefulWidget {
  const LocalEngineStatusPill({
    super.key,
    required this.monitor,
    this.onRetry,
    this.compact = false,
  });

  final LocalEngineHealthMonitor monitor;

  /// Optional callback fired when the user taps the pill while it is
  /// offline. If omitted, the pill triggers `monitor.probeNow()` itself.
  final VoidCallback? onRetry;

  /// When `true`, hides the version label to save space.
  final bool compact;

  @override
  State<LocalEngineStatusPill> createState() => _LocalEngineStatusPillState();
}

class _LocalEngineStatusPillState extends State<LocalEngineStatusPill> {
  static const _zeroTrustGreen = Color(0xFF00FF88);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LocalEngineHealth>(
      stream: widget.monitor.watch(),
      initialData: widget.monitor.last,
      builder: (context, snapshot) {
        final health = snapshot.data;
        final status = health?.status ?? LocalEngineHealthStatus.loading;

        final color = switch (status) {
          LocalEngineHealthStatus.online => _zeroTrustGreen,
          LocalEngineHealthStatus.loading => AppColors.textMuted,
          LocalEngineHealthStatus.offline => AppColors.danger,
        };

        final label = switch (status) {
          LocalEngineHealthStatus.online => 'LOCAL · ONLINE',
          LocalEngineHealthStatus.loading => 'LOCAL · CHECKING',
          LocalEngineHealthStatus.offline => 'LOCAL · OFFLINE',
        };

        final tooltip = switch (status) {
          LocalEngineHealthStatus.online =>
            health?.version?.isNotEmpty ?? false
                ? 'Local engine online · v${health!.version}'
                : 'Local engine online',
          LocalEngineHealthStatus.loading => 'Pinging local engine…',
          LocalEngineHealthStatus.offline => health?.error ?? 'Engine offline',
        };

        final canRetry = status == LocalEngineHealthStatus.offline;

        final pill = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1),
            color: Colors.black,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status == LocalEngineHealthStatus.loading)
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.rectangle,
                  ),
                ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppColors.monoFamily,
                  fontSize: 10,
                  color: color,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (!widget.compact &&
                  status == LocalEngineHealthStatus.online &&
                  (health?.version?.isNotEmpty ?? false)) ...[
                const SizedBox(width: 6),
                Text(
                  'v${health!.version}',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 10,
                    color: AppColors.textMuted,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
              if (canRetry) ...[
                const SizedBox(width: 6),
                Icon(Icons.refresh_rounded, size: 12, color: color),
              ],
            ],
          ),
        );

        return Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: canRetry
                ? () {
                    if (widget.onRetry != null) {
                      widget.onRetry!();
                    } else {
                      widget.monitor.probeNow();
                    }
                  }
                : null,
            child: pill,
          ),
        );
      },
    );
  }
}
