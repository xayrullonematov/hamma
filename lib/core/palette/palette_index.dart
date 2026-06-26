import '../storage/frecency_storage.dart';
import 'palette_source.dart';

/// Aggregates [PaletteSource]s. The dialog talks to one of these and
/// gets back a ready-to-render, frecency-weighted, sorted list.
///
/// Blend formula: `match * (1 + frecencyBoost)`. Multiplying instead
/// of adding keeps non-matches (`match == 0`) out of the results no
/// matter how strong their frecency is — frecency lifts hits, never
/// resurrects misses.
class PaletteIndex {
  PaletteIndex({
    required this.sources,
    required this.frecency,
    this.perSourceCap = 12,
    this.totalCap = 30,
  });

  final List<PaletteSource> sources;
  final FrecencyStorage frecency;

  /// Hard cap on rows kept per source after blending. Prevents one
  /// chatty source (recents, plugin actions) from dominating the
  /// list.
  final int perSourceCap;

  /// Hard cap on rows returned overall. The dialog renders this
  /// directly, so it doubles as the visible result count.
  final int totalCap;

  /// Run [input] across [sources] in parallel, blend, sort, cap.
  Future<List<PaletteResult>> query(String input) async {
    final perSource = await Future.wait(sources.map((s) => s.query(input)));

    final scored = <_Scored>[];
    for (var sIdx = 0; sIdx < sources.length; sIdx++) {
      final source = sources[sIdx];
      final results = perSource[sIdx];
      final frecencies = await frecency.scoresForCategory(source.id);

      final sourceScored = <_Scored>[];
      for (final r in results) {
        if (r.matchScore <= 0) continue;
        final boost = frecencies[r.effectiveFrecencyKey] ?? 0.0;
        sourceScored.add(_Scored(r, r.matchScore * (1.0 + boost)));
      }
      sourceScored.sort((a, b) => b.combined.compareTo(a.combined));
      scored.addAll(sourceScored.take(perSourceCap));
    }

    scored.sort((a, b) => b.combined.compareTo(a.combined));
    return scored.take(totalCap).map((s) => s.result).toList(growable: false);
  }

  /// Run [input] against a single source (used by the `Tab` scope
  /// cycle so the dialog can show "Servers >" filtered results).
  Future<List<PaletteResult>> queryScoped(String sourceId, String input) async {
    final source = sources.firstWhere(
      (s) => s.id == sourceId,
      orElse: () => throw ArgumentError('Unknown palette source: $sourceId'),
    );
    final results = await source.query(input);
    final frecencies = await frecency.scoresForCategory(source.id);
    final scored = <_Scored>[];
    for (final r in results) {
      if (r.matchScore <= 0) continue;
      final boost = frecencies[r.effectiveFrecencyKey] ?? 0.0;
      scored.add(_Scored(r, r.matchScore * (1.0 + boost)));
    }
    scored.sort((a, b) => b.combined.compareTo(a.combined));
    return scored.take(totalCap).map((s) => s.result).toList(growable: false);
  }

  /// Record the user's choice so future ranking reflects it.
  /// Called from the dialog right before [PaletteResult.onInvoke].
  Future<void> recordInvocation(PaletteResult result) {
    return frecency.record(result.sourceId, result.effectiveFrecencyKey);
  }
}

class _Scored {
  const _Scored(this.result, this.combined);
  final PaletteResult result;
  final double combined;
}
