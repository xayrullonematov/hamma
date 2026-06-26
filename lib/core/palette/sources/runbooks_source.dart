import 'package:flutter/material.dart';

import '../../runbooks/runbook.dart';
import '../fuzzy_match.dart';
import '../palette_source.dart';

/// Palette source for saved and starter runbooks.
class RunbooksSource extends PaletteSource {
  const RunbooksSource({required this.loader, required this.onSelect});

  final Future<List<Runbook>> Function() loader;
  final Future<void> Function(Runbook runbook, BuildContext context) onSelect;

  @override
  String get id => 'runbooks';

  @override
  String get displayName => 'Runbooks';

  @override
  Future<List<PaletteResult>> query(String input) async {
    final runbooks = await loader();
    final results = <PaletteResult>[];
    for (final runbook in runbooks) {
      final stepText = runbook.steps.expand(
        (step) => [
          step.label,
          if (step.command != null) step.command!,
          if (step.notifyMessage != null) step.notifyMessage!,
        ],
      );
      final score = fuzzyBestScore(input, [
        runbook.name,
        runbook.description,
        if (runbook.serverId != null) runbook.serverId!,
        ...stepText,
      ]);
      if (score <= 0) continue;
      results.add(
        PaletteResult(
          id: runbook.id,
          sourceId: id,
          label: runbook.name,
          subtitle: _subtitle(runbook),
          icon: Icons.playlist_play_rounded,
          matchScore: score,
          onInvoke: (context) => onSelect(runbook, context),
        ),
      );
    }
    return results;
  }

  String _subtitle(Runbook runbook) {
    final flags = <String>[
      '${runbook.steps.length} step${runbook.steps.length == 1 ? '' : 's'}',
      if (runbook.starter) 'starter',
      if (runbook.team) 'team',
      if (runbook.serverId != null) 'server pinned',
    ];
    final description = runbook.description.trim();
    return description.isEmpty
        ? flags.join(' · ')
        : '${flags.join(' · ')} · $description';
  }
}
