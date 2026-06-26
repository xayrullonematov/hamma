import 'package:flutter/material.dart';

import '../../audit/execution_audit_entry.dart';
import '../fuzzy_match.dart';
import '../palette_source.dart';

/// Palette source backed by [ExecutionAuditService.recentEntries].
///
/// It does not execute anything itself. Invocation is delegated to the
/// host shell so the command can be previewed and risk-assessed before
/// execution.
class RecentCommandsSource extends PaletteSource {
  const RecentCommandsSource({required this.loader, required this.onSelect});

  final Future<List<ExecutionAuditEntry>> Function() loader;
  final Future<void> Function(ExecutionAuditEntry entry, BuildContext context)
  onSelect;

  @override
  String get id => 'recent_commands';

  @override
  String get displayName => 'Commands';

  @override
  Future<List<PaletteResult>> query(String input) async {
    final entries = await loader();
    final results = <PaletteResult>[];
    for (final entry in entries) {
      final score = fuzzyBestScore(input, [
        entry.proposedCommand,
        entry.naturalLanguageIntent,
        entry.serverName,
        entry.riskLevel.name,
      ]);
      if (score <= 0) continue;
      results.add(
        PaletteResult(
          id: entry.id,
          sourceId: id,
          label: entry.proposedCommand,
          subtitle: _subtitle(entry),
          icon: Icons.history_rounded,
          matchScore: score,
          onInvoke: (context) => onSelect(entry, context),
        ),
      );
    }
    return results;
  }

  String _subtitle(ExecutionAuditEntry entry) {
    final intent = entry.naturalLanguageIntent.trim();
    final bits = <String>[
      if (entry.serverName.trim().isNotEmpty) entry.serverName.trim(),
      entry.riskLevel.name.toUpperCase(),
      entry.status.name,
      if (intent.isNotEmpty) intent,
    ];
    return bits.join(' · ');
  }
}
