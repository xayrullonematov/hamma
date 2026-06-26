/// Cheap, dependency-free fuzzy scorer used by every palette source.
///
/// Score in `[0.0, 1.0]`. Anything > 0 means "the input matches this
/// target somehow"; 0 means "no match, drop this row." The scale is
/// intentionally coarse — exact prefix beats substring beats
/// subsequence — because the palette tiebreaker is frecency, and
/// frecency is the signal we actually care about.
///
/// The matcher is case-insensitive. Empty input matches everything
/// with score 1.0 so an unfiltered palette shows results sorted by
/// frecency alone.
double fuzzyScore(String input, String target) {
  if (input.isEmpty) return 1.0;
  if (target.isEmpty) return 0.0;

  final i = input.toLowerCase();
  final t = target.toLowerCase();

  if (t == i) return 1.0;
  if (t.startsWith(i)) return 0.9;
  if (t.contains(i)) return 0.7;

  // Subsequence: every input char appears in target, in order.
  // The denser the match (shorter target relative to input), the
  // higher the score. Caps at 0.6 so a sparse subsequence never
  // outranks a substring hit.
  var iIdx = 0;
  for (var ti = 0; ti < t.length && iIdx < i.length; ti++) {
    if (t.codeUnitAt(ti) == i.codeUnitAt(iIdx)) iIdx++;
  }
  if (iIdx == i.length) {
    final density = i.length / t.length;
    return 0.3 + density * 0.3;
  }
  return 0.0;
}

/// Returns the best score across [candidates] — used when a target
/// has multiple searchable fields (e.g. a server's name AND its host).
double fuzzyBestScore(String input, Iterable<String> candidates) {
  var best = 0.0;
  for (final c in candidates) {
    final s = fuzzyScore(input, c);
    if (s > best) best = s;
    if (best == 1.0) return best;
  }
  return best;
}
