import 'package:meta/meta.dart';

import 'vault_secret.dart';

/// Pure-Dart, side-effect-free redactor that replaces every literal
/// occurrence of a vault secret's value with `••••••• (vault: NAME)`.
///
/// **Wired into**: terminal command echo, command-history pane,
/// AI prompt builder (both user message and history), [ErrorScrubber]
/// pass, and the Sentry `beforeSend` transport hook.
///
/// Design notes:
///  - **Multi-occurrence**: a value that appears N times in a string is
///    replaced N times.
///  - **Unicode-safe**: substitution operates on raw code units via
///    `String.replaceAll`, which is grapheme-agnostic but correct for
///    the common case of ASCII / UTF-8 secrets. We deliberately do not
///    fold case — `Token` and `token` are different secrets.
///  - **False-positive floor**: values shorter than [_minLength] code
///    units are skipped. A 2-char "secret" like `pi` would otherwise
///    redact half the documentation. Production secrets are always
///    well above this floor; the redactor is best-effort, not a
///    DLP product.
///  - **Longest-first**: when one secret value is a prefix/substring
///    of another, the longer one is matched first so the shorter one
///    can't shadow it.
///  - **Empty / global instance**: callers can use [VaultRedactor.empty]
///    as a no-op when no vault state is loaded yet.
@immutable
class VaultRedactor {
  /// Minimum secret length that participates in redaction. Anything
  /// shorter would generate too many false positives.
  static const int _minLength = 6;

  const VaultRedactor._(this._entries);

  /// No-op redactor. Returns input strings unchanged.
  static const VaultRedactor empty = VaultRedactor._(<_RedactionEntry>[]);

  /// Build a redactor over [secrets]. Filters out invalid / too-short
  /// values and sorts by descending value length so longest matches
  /// run first.
  factory VaultRedactor.from(Iterable<VaultSecret> secrets) {
    final entries = <_RedactionEntry>[];
    for (final s in secrets) {
      if (!s.isValid) continue;
      if (s.value.length < _minLength) continue;
      entries.add(_RedactionEntry(name: s.name, value: s.value));
    }
    // Longest first to avoid prefix-shadowing.
    entries.sort((a, b) => b.value.length.compareTo(a.value.length));
    // De-duplicate identical values that map to multiple names — the
    // first (longest, then insertion-order) winner wins.
    final seenValues = <String>{};
    final deduped = <_RedactionEntry>[];
    for (final e in entries) {
      if (seenValues.add(e.value)) deduped.add(e);
    }
    return VaultRedactor._(List.unmodifiable(deduped));
  }

  final List<_RedactionEntry> _entries;

  bool get isEmpty => _entries.isEmpty;

  /// Returns [input] with every occurrence of every tracked secret
  /// replaced by its redaction marker. Safe to call with `null`
  /// (returns empty string) and never throws.
  String redact(String? input) {
    if (input == null || input.isEmpty || _entries.isEmpty) {
      return input ?? '';
    }
    var s = input;
    for (final e in _entries) {
      if (!s.contains(e.value)) continue;
      s = s.replaceAll(e.value, '••••••• (vault: ${e.name})');
    }
    return s;
  }
}

class _RedactionEntry {
  const _RedactionEntry({required this.name, required this.value});
  final String name;
  final String value;
}

/// Process-global redactor handle. Mutated by the host app whenever the
/// vault state changes (via [VaultChangeBus]) and read by every
/// transport-side scrubber that doesn't have an injectable instance
/// (e.g. the static [ErrorScrubber] pass and the Sentry `beforeSend`
/// hook). Defaults to [VaultRedactor.empty] so tests and code paths
/// that never load the vault are unaffected.
class GlobalVaultRedactor {
  GlobalVaultRedactor._();

  static VaultRedactor _current = VaultRedactor.empty;

  static VaultRedactor get current => _current;

  static void set(VaultRedactor redactor) {
    _current = redactor;
  }

  static void reset() {
    _current = VaultRedactor.empty;
  }
}
