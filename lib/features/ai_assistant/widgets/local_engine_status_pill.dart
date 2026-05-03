import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/ai/local_engine_health_monitor.dart';
import '../../../core/theme/app_colors.dart';

/// Brutalist pill showing the live status of the configured local AI
/// engine. Designed to sit in the AI assistant / copilot header.
///
/// The pill is purely a presenter: it expects an externally-managed
/// [LocalEngineHealthMonitor] (so multiple surfaces can share one timer
/// and one HTTP cycle).
///
/// States rendered:
///  - **Online + loaded model**: green `LOCAL · ONLINE · {model}`
///  - **Online, no model loaded**: green `LOCAL · ONLINE`
///  - **Loading / first probe**: amber `LOCAL · LOADING…` (spinner)
///  - **Offline**: red `LOCAL · OFFLINE` (tap to retry)
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

  /// When `true`, hides the version label and trims long model names so
  /// the pill fits in cramped headers.
  final bool compact;

  @override
  State<LocalEngineStatusPill> createState() => _LocalEngineStatusPillState();
}

class _LocalEngineStatusPillState extends State<LocalEngineStatusPill> {
  static const _zeroTrustGreen = Color(0xFF00FF88);
  static const _loadingAmber = Color(0xFFFFB000);

  /// Tracks an in-flight retry probe so the pill can show a spinner and
  /// debounce duplicate taps until the request resolves.
  bool _retrying = false;

  /// Fires an out-of-band probe and forces a rebuild as soon as the
  /// result lands so the user sees the new status without waiting for
  /// the next polling tick.
  Future<void> _probeFromTap() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      widget.onRetry?.call();
      await widget.monitor.probeNow();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  /// Strip a trailing `:latest` so the pill stays compact.
  String _shortName(String tag) {
    if (tag.endsWith(':latest')) {
      return tag.substring(0, tag.length - ':latest'.length);
    }
    return tag;
  }

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
          LocalEngineHealthStatus.loading => _loadingAmber,
          LocalEngineHealthStatus.loadingModel => _loadingAmber,
          LocalEngineHealthStatus.offline => AppColors.danger,
        };

        // Online label includes the first loaded-in-RAM model, mirroring
        // the spec ("Online · gemma3"). Falls back to plain ONLINE when
        // the engine is up but the engine doesn't expose a model list.
        String label;
        switch (status) {
          case LocalEngineHealthStatus.online:
            final loaded = health?.loadedModels ?? const [];
            if (loaded.isNotEmpty) {
              final name = _shortName(loaded.first);
              label = 'LOCAL · ONLINE · ${name.toUpperCase()}';
            } else {
              label = 'LOCAL · ONLINE';
            }
          case LocalEngineHealthStatus.loadingModel:
            label = 'LOCAL · LOADING MODEL';
          case LocalEngineHealthStatus.loading:
            label = 'LOCAL · CONNECTING…';
          case LocalEngineHealthStatus.offline:
            label = 'LOCAL · OFFLINE';
        }

        final tooltip = switch (status) {
          LocalEngineHealthStatus.online =>
            health?.version?.isNotEmpty ?? false
                ? 'Local engine online · v${health!.version}'
                : 'Local engine online',
          LocalEngineHealthStatus.loadingModel =>
            'Engine reachable — no model warm in RAM yet. The next request will trigger a model load.',
          LocalEngineHealthStatus.loading => 'Pinging local engine…',
          LocalEngineHealthStatus.offline => health?.error ?? 'Engine offline',
        };

        final canRetry = status == LocalEngineHealthStatus.offline;
        // Offline tap = one-shot probe (immediate recovery feedback);
        // any other state opens the details sheet so users can inspect
        // endpoint, version, loaded models, and retry from there.
        VoidCallback onTap;
        if (canRetry) {
          onTap = () => unawaited(_probeFromTap());
        } else {
          onTap = () => _showEngineDetailsSheet(context, health);
        }

        final pill = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1),
            color: Colors.black,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_retrying ||
                  status == LocalEngineHealthStatus.loading ||
                  status == LocalEngineHealthStatus.loadingModel)
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
            onTap: onTap,
            onLongPress: () => _showEngineDetailsSheet(context, health),
            child: pill,
          ),
        );
      },
    );
  }

  /// Opens a brutalist bottom sheet with the engine endpoint, version,
  /// status, loaded models, last checked time, and a "Retry now" button
  /// that triggers an out-of-band probe. Used as the universal pill-tap
  /// destination so users can inspect health from any state — not just
  /// when offline.
  void _showEngineDetailsSheet(
    BuildContext context,
    LocalEngineHealth? health,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (sheetContext) => _LocalEngineDetailsSheet(
        endpoint: widget.monitor.endpoint,
        initial: health,
        monitor: widget.monitor,
        onRetry: widget.onRetry,
      ),
    );
  }
}

/// Bottom sheet body kept as a separate StatefulWidget so it can rebuild
/// in response to fresh probe results without rebuilding the host pill.
class _LocalEngineDetailsSheet extends StatefulWidget {
  const _LocalEngineDetailsSheet({
    required this.endpoint,
    required this.monitor,
    this.initial,
    this.onRetry,
  });

  final String endpoint;
  final LocalEngineHealthMonitor monitor;
  final LocalEngineHealth? initial;
  final VoidCallback? onRetry;

  @override
  State<_LocalEngineDetailsSheet> createState() =>
      _LocalEngineDetailsSheetState();
}

class _LocalEngineDetailsSheetState extends State<_LocalEngineDetailsSheet> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      if (widget.onRetry != null) {
        widget.onRetry!();
      }
      await widget.monitor.probeNow();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  String _formatStatus(LocalEngineHealthStatus s) {
    switch (s) {
      case LocalEngineHealthStatus.online:
        return 'ONLINE';
      case LocalEngineHealthStatus.loadingModel:
        return 'LOADING MODEL';
      case LocalEngineHealthStatus.loading:
        return 'CONNECTING';
      case LocalEngineHealthStatus.offline:
        return 'OFFLINE';
    }
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final delta = now.difference(t);
    if (delta.inSeconds < 5) return 'just now';
    if (delta.inMinutes < 1) return '${delta.inSeconds}s ago';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    return '${delta.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LocalEngineHealth>(
      stream: widget.monitor.watch(),
      initialData: widget.initial ?? widget.monitor.last,
      builder: (context, snapshot) {
        final h = snapshot.data;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LOCAL AI ENGINE',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 11,
                    color: AppColors.textMuted,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: 'STATUS',
                  value: h == null ? '—' : _formatStatus(h.status),
                ),
                _DetailRow(label: 'ENDPOINT', value: widget.endpoint),
                _DetailRow(
                  label: 'VERSION',
                  value: (h?.version ?? '').isEmpty ? '—' : 'v${h!.version}',
                ),
                _DetailRow(
                  label: 'LOADED',
                  value: (h?.loadedModels.isEmpty ?? true)
                      ? '— (no model warm)'
                      : h!.loadedModels.join(', '),
                ),
                _DetailRow(
                  label: 'CHECKED',
                  value: h == null ? '—' : _formatTime(h.checkedAt),
                ),
                if ((h?.error ?? '').isNotEmpty)
                  _DetailRow(
                    label: 'ERROR',
                    value: h!.error!,
                    valueColor: AppColors.danger,
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _retrying ? null : _retry,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero,
                          ),
                          side: const BorderSide(color: Color(0xFF00FF88)),
                          foregroundColor: const Color(0xFF00FF88),
                        ),
                        icon: _retrying
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00FF88),
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 16),
                        label: Text(
                          _retrying ? 'PROBING…' : 'RETRY NOW',
                          style: TextStyle(
                            fontFamily: AppColors.monoFamily,
                            fontSize: 12,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero,
                          ),
                          side: BorderSide(color: AppColors.textMuted),
                          foregroundColor: AppColors.textPrimary,
                        ),
                        child: Text(
                          'CLOSE',
                          style: TextStyle(
                            fontFamily: AppColors.monoFamily,
                            fontSize: 12,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 10,
                color: AppColors.textMuted,
                letterSpacing: 1.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 12,
                color: valueColor ?? AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
