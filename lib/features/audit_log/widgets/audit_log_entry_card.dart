import 'package:flutter/material.dart';

import '../../../core/audit/execution_audit_entry.dart';
import '../../../core/ai/command_risk_assessor.dart';
import '../../../core/theme/app_colors.dart';

/// Brutalist card displaying a single [ExecutionAuditEntry].
///
/// Shows server name, natural language intent, the proposed command in
/// monospace, risk level badge, execution status, relative timestamp, and
/// duration. Tap to expand stdout/stderr output.
class AuditLogEntryCard extends StatefulWidget {
  const AuditLogEntryCard({super.key, required this.entry});

  final ExecutionAuditEntry entry;

  @override
  State<AuditLogEntryCard> createState() => _AuditLogEntryCardState();
}

class _AuditLogEntryCardState extends State<AuditLogEntryCard> {
  bool _expanded = false;

  // --- Risk display helpers ---

  Color _riskColor(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.low:
        return AppColors.textMuted;
      case CommandRiskLevel.moderate:
        return AppColors.warning;
      case CommandRiskLevel.high:
      case CommandRiskLevel.critical:
        return AppColors.danger;
    }
  }

  String _riskLabel(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.low:
        return 'LOW';
      case CommandRiskLevel.moderate:
        return 'MODERATE';
      case CommandRiskLevel.high:
        return 'HIGH';
      case CommandRiskLevel.critical:
        return 'CRITICAL';
    }
  }

  // --- Status display helpers ---

  Color _statusColor(ExecutionStatus status) {
    switch (status) {
      case ExecutionStatus.approved:
        return AppColors.textMuted;
      case ExecutionStatus.executed:
        return AppColors.accent;
      case ExecutionStatus.failed:
        return AppColors.danger;
    }
  }

  String _statusLabel(ExecutionStatus status) {
    switch (status) {
      case ExecutionStatus.approved:
        return 'APPROVED';
      case ExecutionStatus.executed:
        return 'EXECUTED';
      case ExecutionStatus.failed:
        return 'FAILED';
    }
  }

  /// Formats [dateTime] as a relative time string (e.g. '2m ago', '1h ago').
  String _relativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final riskColor = _riskColor(entry.riskLevel);
    final hasOutput =
        (entry.stdout != null && entry.stdout!.isNotEmpty) ||
        (entry.stderr != null && entry.stderr!.isNotEmpty);

    return GestureDetector(
      onTap: hasOutput ? () => setState(() => _expanded = !_expanded) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.zero,
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: server name + timestamp
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.panel,
                border: Border(
                  bottom: BorderSide(color: AppColors.border, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.serverName.toUpperCase(),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                      ),
                    ),
                  ),
                  Text(
                    _relativeTime(entry.approvedAt),
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                    ),
                  ),
                ],
              ),
            ),

            // Body: intent + command
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Natural language intent
                  Text(
                    entry.naturalLanguageIntent,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.4,
                      fontFamily: AppColors.sansFamily,
                      fontFamilyFallback: AppColors.sansFallback,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Command in monospace
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.scaffoldBackground,
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: AppColors.border, width: 1),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '\$ ',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontFamily: AppColors.monoFamily,
                            fontFamilyFallback: AppColors.monoFallback,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            entry.proposedCommand,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontFamily: AppColors.monoFamily,
                              fontFamilyFallback: AppColors.monoFallback,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Footer: risk badge + status + duration
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.border, width: 1),
                ),
              ),
              child: Row(
                children: [
                  // Risk badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: riskColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: riskColor, width: 1),
                    ),
                    child: Text(
                      _riskLabel(entry.riskLevel),
                      style: TextStyle(
                        color: riskColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                        letterSpacing: 1.2,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.zero,
                      border: Border.all(
                        color: _statusColor(entry.status),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _statusLabel(entry.status),
                      style: TextStyle(
                        color: _statusColor(entry.status),
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                        letterSpacing: 1.0,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Duration
                  if (entry.executionDurationMs != null)
                    Text(
                      '${entry.executionDurationMs}ms',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                      ),
                    ),
                  if (hasOutput) ...[
                    const SizedBox(width: 10),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: AppColors.textMuted,
                      size: 18,
                    ),
                  ],
                ],
              ),
            ),

            // Expanded output section
            if (_expanded && hasOutput)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: AppColors.scaffoldBackground,
                  border: Border(
                    top: BorderSide(color: AppColors.border, width: 1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (entry.stdout != null && entry.stdout!.isNotEmpty) ...[
                      const Text(
                        'STDOUT',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.stdout!,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 11,
                          height: 1.5,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                        ),
                      ),
                    ],
                    if (entry.stderr != null && entry.stderr!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'STDERR',
                        style: TextStyle(
                          color: AppColors.danger,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.stderr!,
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 11,
                          height: 1.5,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
