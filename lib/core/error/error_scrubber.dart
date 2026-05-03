import '../vault/vault_redactor.dart';

/// Strips likely-sensitive substrings from error messages before they are
/// displayed to the user or sent to a remote crash reporter.
///
/// **Best effort.** Regex-based scrubbing cannot guarantee removal of
/// every secret; never log raw sensitive data in the first place.
///
/// Patterns covered:
///  - `password=...`, `password: ...`
///  - `pin=...`, `pin: ...`
///  - `secret=...`, `secret: ...`
///  - `token=...`, `token: ...`
///  - `apiKey=...`, `api_key=...`, `api-key=...`
///  - `Authorization: Bearer <token>` headers
///  - `Authorization: Basic <base64>` headers
///  - OpenAI-style `sk-...` keys
///  - PEM-armored private keys (`-----BEGIN ... PRIVATE KEY----- ... -----END ... PRIVATE KEY-----`)
class ErrorScrubber {
  ErrorScrubber._();

  static const String _redacted = '[SCRUBBED]';

  // Field/value pairs (key=value or key: value). Captures the key so we
  // can preserve it (helps debugging) while replacing the value.
  static final RegExp _fieldPair = RegExp(
    r'(?<key>password|pin|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key)'
    r'(?<sep>\s*[:=]\s*)'
    r'(?<val>"[^"]*"|' r"'[^']*'" r'|\S+)',
    caseSensitive: false,
  );

  // Authorization headers — both Bearer and Basic schemes.
  static final RegExp _authHeader = RegExp(
    r'(?<scheme>Bearer|Basic)\s+[A-Za-z0-9+/=._\-]{8,}',
    caseSensitive: false,
  );

  // OpenAI-style API keys: `sk-` followed by ≥20 base64-ish characters.
  // Matches the actual key format Hamma uses.
  static final RegExp _openaiKey = RegExp(r'sk-[A-Za-z0-9_\-]{20,}');

  // Standalone JWTs (header.payload.signature). The leading `eyJ` is
  // the base64url encoding of `{"` — the start of every well-formed
  // JWT header and payload. Requiring it on both segments dramatically
  // reduces false positives compared to a generic 3-base64url-segment
  // pattern. Minimum 5 chars per segment to avoid matching trivial
  // strings.
  static final RegExp _jwt = RegExp(
    r'eyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}',
  );

  // PEM private key blocks. The `?` makes `.` non-greedy so we don't
  // swallow trailing content if multiple blocks exist.
  static final RegExp _pemPrivateKey = RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
  );

  /// Returns [input] with sensitive substrings replaced by `[SCRUBBED]`.
  ///
  /// Safe to call on any string, including `null` (returns empty string)
  /// and arbitrary lengths. Does not throw.
  static String scrub(String? input) {
    if (input == null || input.isEmpty) return '';

    // Pre-pass: redact any literal vault secret value first, so the
    // generic regex passes never see (and therefore never partially
    // shadow) a secret. The global redactor is set by the host app
    // whenever the vault state changes; tests and bare callers see
    // the empty redactor and pay zero cost.
    var s = GlobalVaultRedactor.current.redact(input);

    // Order matters: the most specific patterns run first to avoid
    // partial overlap (e.g., a PEM block contains the literal word
    // `PRIVATE KEY` which would otherwise match the field-pair rule).
    s = s.replaceAll(_pemPrivateKey, '[SCRUBBED PRIVATE KEY]');
    s = s.replaceAllMapped(_authHeader, (m) {
      final match = m as RegExpMatch;
      return '${match.namedGroup('scheme')} $_redacted';
    });
    // JWT before openai-key so a JWT that happens to be embedded in a
    // longer string can't be partially shadowed by other patterns.
    s = s.replaceAll(_jwt, '[SCRUBBED JWT]');
    s = s.replaceAll(_openaiKey, 'sk-$_redacted');
    s = s.replaceAllMapped(_fieldPair, (m) {
      final match = m as RegExpMatch;
      final key = match.namedGroup('key');
      final sep = match.namedGroup('sep');
      return '$key$sep$_redacted';
    });

    return s;
  }
}
