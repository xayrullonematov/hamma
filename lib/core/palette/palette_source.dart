import 'package:flutter/widgets.dart';

/// One row the palette can show. Sources produce these; the index
/// blends them by combined score; the dialog renders the sorted list.
///
/// [onInvoke] is the closure the dialog calls on Enter / click. It
/// receives a [BuildContext] from the palette dialog so the closure
/// can `Navigator.push`, `showDialog`, or whatever else it needs
/// without the source having to thread context around.
///
/// **Command-producing results MUST route through
/// `CommandRiskAssessor` inside their [onInvoke] closure.** That's
/// hard invariant #4 — no palette path may bypass the risk gate. For
/// navigation-only results (servers, screens), the closure is just a
/// route push.
@immutable
class PaletteResult {
  const PaletteResult({
    required this.id,
    required this.sourceId,
    required this.label,
    required this.icon,
    required this.matchScore,
    required this.onInvoke,
    this.subtitle,
    this.frecencyKey,
  });

  /// Stable, source-scoped id for this row. Forms the frecency key
  /// when [frecencyKey] is null. Sources should pick something that
  /// survives across runs (server profile id, screen enum name, etc.).
  final String id;

  /// Id of the source that produced this row. Drives the frecency
  /// category and lets the dialog group / scope results.
  final String sourceId;

  /// Top-line display text.
  final String label;

  /// Secondary line (host, file path, etc.). Free-form, optional.
  final String? subtitle;

  /// Brutalist palette uses outline icons throughout; the source
  /// picks one that hints at the category at a glance.
  final IconData icon;

  /// Score in `[0.0, 1.0]` returned by the fuzzy matcher. The index
  /// multiplies this against frecency to get the final ranking. Match
  /// of 0 should be filtered before reaching the index.
  final double matchScore;

  /// Closure invoked when the user picks this row. Async so navigation
  /// awaits can settle before the dialog closes.
  final Future<void> Function(BuildContext context) onInvoke;

  /// Override key for frecency tracking. Defaults to [id]. Useful when
  /// a source surfaces the same underlying item under multiple ids
  /// (e.g. an alias) but you want them to share a frecency record.
  final String? frecencyKey;

  String get effectiveFrecencyKey => frecencyKey ?? id;
}

/// Contributor to the palette. Sources are queried in parallel by
/// [PaletteIndex.query] and contribute results to the unified list.
///
/// One source per category — `servers`, `screens`, `runbooks`,
/// `sftp_files`, `recent_commands`, `plugin_actions`, etc.
abstract class PaletteSource {
  const PaletteSource();

  /// Stable identifier — used as the frecency category and as the
  /// scope label when the user presses Tab to narrow the palette.
  String get id;

  /// Short, capitalised label shown in the scope chip (`"Servers"`,
  /// `"Files"`). Free-form; not user-localized in v1.
  String get displayName;

  /// Returns matching results for [input]. Sources should:
  ///   * Use `fuzzyScore` / `fuzzyBestScore` from `fuzzy_match.dart`
  ///     so ranking stays consistent across the palette.
  ///   * Filter zero-score rows themselves — the index trusts what
  ///     comes back.
  ///   * Cap their own output at a reasonable per-source limit
  ///     (10-20) to keep blending O(small).
  Future<List<PaletteResult>> query(String input);
}
