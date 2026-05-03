import 'package:meta/meta.dart';

import 'vault_secret.dart';

/// Pure-Dart redactor that replaces every literal occurrence of a
/// vault secret's value with `••••••• (vault: NAME)`. See
/// `docs/secrets-vault.md` for the wiring map and known gaps. Use
/// [StreamingVaultRedactor] when feeding chunked input (e.g. SSH
/// stdout) — calling [redact] independently on each chunk can leak a
/// secret that straddles a chunk boundary.
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

/// Buffered redactor for chunked input streams (SSH stdout/stderr).
///
/// Calling [VaultRedactor.redact] independently on each chunk leaks
/// any secret whose value straddles a chunk boundary — neither chunk
/// contains the full value, so neither match. This wrapper holds back
/// the trailing `(maxSecretLength - 1)` code units of each chunk as
/// a carry, prepends them to the next chunk, and only emits the
/// safe-to-flush prefix.
///
/// Properties:
///  - The carry is held in raw form (we have not yet decided whether
///    it is part of a secret), but it is NEVER emitted until enough
///    bytes follow to disambiguate. So the on-screen buffer / AI
///    scrollback / log file only ever sees fully-classified text.
///  - On end-of-stream the caller MUST invoke [flush] to emit any
///    remaining carry; that final flush is also redacted, so a secret
///    that ends exactly at EOF is still scrubbed.
///  - When the redactor is empty (no secrets registered) we degrade
///    to passthrough — there is nothing that could span a boundary.
class StreamingVaultRedactor {
  StreamingVaultRedactor(VaultRedactor redactor)
      : _redactor = redactor,
        _maxLen = _maxValueLength(redactor);

  VaultRedactor _redactor;
  int _maxLen;
  String _carry = '';

  static int _maxValueLength(VaultRedactor r) => r._entries.isEmpty
      ? 0
      : r._entries
          .map((e) => e.value.length)
          .reduce((a, b) => a > b ? a : b);

  /// Process [chunk]. Returns the safely-redacted prefix of
  /// `_carry + chunk`; the unsafe tail is held until the next
  /// [feed] / [flush].
  ///
  /// "Safe" means: no occurrence of any registered secret value
  /// straddles the emit/carry boundary. We find the earliest
  /// position `i` in `combined` from which a secret prefix matches
  /// the in-flight tail, and emit only `combined[0..i]`. Everything
  /// from `i` onwards is held as carry — it is either the start of
  /// a real secret (will be redacted on the next round) or
  /// harmless plaintext (will be emitted on the next round once the
  /// disambiguating bytes arrive).
  String feed(String chunk) {
    if (_redactor.isEmpty) return _redactor.redact(chunk);
    final combined = _carry + chunk;
    final emitLen = _safeEmitLength(combined);
    if (emitLen == 0) {
      _carry = combined;
      return '';
    }
    final safePrefix = combined.substring(0, emitLen);
    _carry = combined.substring(emitLen);
    return _redactor.redact(safePrefix);
  }

  /// Largest `i` such that `combined[0..i]` cannot contain the
  /// leading bytes of an as-yet-incomplete secret. Equivalently:
  /// the earliest position from which any secret value is a
  /// possible prefix-match of the unfinished tail.
  int _safeEmitLength(String combined) {
    int emitLen = combined.length;
    final scanFrom = combined.length - (_maxLen - 1);
    final lo = scanFrom < 0 ? 0 : scanFrom;
    for (int i = combined.length - 1; i >= lo; i--) {
      for (final e in _redactor._entries) {
        final L = e.value.length;
        if (i + L <= combined.length) continue; // fits — already redactable
        final tailLen = combined.length - i;
        if (tailLen >= L) continue;
        bool match = true;
        for (int j = 0; j < tailLen; j++) {
          if (combined.codeUnitAt(i + j) != e.value.codeUnitAt(j)) {
            match = false;
            break;
          }
        }
        if (match && i < emitLen) {
          emitLen = i;
          break;
        }
      }
      if (emitLen == 0) break;
    }
    return emitLen;
  }

  /// Flush any remaining carry. Call when the stream closes so a
  /// trailing secret cannot be stranded in the buffer.
  String flush() {
    if (_carry.isEmpty) return '';
    final out = _redactor.redact(_carry);
    _carry = '';
    return out;
  }

  /// Swap in a new redactor (e.g. after [VaultChangeBus] fires).
  /// Preserves the in-flight carry so a secret newly registered
  /// mid-stream still has a chance to match on the next [feed].
  void updateRedactor(VaultRedactor next) {
    _redactor = next;
    _maxLen = _maxValueLength(next);
  }
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
