import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_redactor.dart';
import 'package:hamma/core/vault/vault_secret.dart';

VaultSecret _s(String name, String value) => VaultSecret(
      id: name.toLowerCase(),
      name: name,
      value: value,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('StreamingVaultRedactor', () {
    test('passthrough when no secrets are registered', () {
      final r = StreamingVaultRedactor(VaultRedactor.empty);
      expect(r.feed('anything goes'), 'anything goes');
      expect(r.flush(), '');
    });

    test('catches a secret split across two chunks (single boundary)',
        () async {
      final secret = 'super-secret-value';
      final redactor = VaultRedactor.from([_s('TOK', secret)]);
      final r = StreamingVaultRedactor(redactor);

      // Split the secret in half across a chunk boundary.
      final mid = secret.length ~/ 2;
      final first = 'prefix ${secret.substring(0, mid)}';
      final second = '${secret.substring(mid)} suffix';

      final out1 = r.feed(first);
      // The first emit MUST NOT contain any leading half of the secret
      // (otherwise the on-screen buffer leaks it).
      expect(
        out1.contains(secret.substring(0, mid)),
        isFalse,
        reason: 'leading half must be held back, not emitted',
      );

      final out2 = r.feed(second);
      final tail = r.flush();
      final all = out1 + out2 + tail;
      expect(all.contains(secret), isFalse,
          reason: 'full secret value must never appear in the merged output');
      expect(all.contains('••••••• (vault: TOK)'), isTrue,
          reason: 'redaction marker must be present');
      expect(all.startsWith('prefix '), isTrue);
      expect(all.endsWith('suffix'), isTrue);
    });

    test('catches a secret split across MANY tiny chunks (one byte each)',
        () async {
      final secret = 'pwd-rotated-2026';
      final redactor = VaultRedactor.from([_s('PASS', secret)]);
      final r = StreamingVaultRedactor(redactor);

      final stream = 'echo $secret done';
      final out = StringBuffer();
      for (final ch in stream.split('')) {
        out.write(r.feed(ch));
      }
      out.write(r.flush());
      final all = out.toString();

      expect(all.contains(secret), isFalse);
      expect(all.contains('••••••• (vault: PASS)'), isTrue);
      expect(all.startsWith('echo '), isTrue);
      expect(all.endsWith(' done'), isTrue);
    });

    test('flush emits the trailing carry redacted on EOF', () async {
      final secret = 'trailing-secret-pwd';
      final redactor = VaultRedactor.from([_s('END', secret)]);
      final r = StreamingVaultRedactor(redactor);

      // Whole secret arrives at the very tail of the stream — the
      // safe-prefix algorithm holds it back until flush().
      final out1 = r.feed('output: ');
      final out2 = r.feed(secret);
      final tail = r.flush();
      final all = out1 + out2 + tail;
      expect(all.contains(secret), isFalse);
      expect(all.contains('••••••• (vault: END)'), isTrue);
    });

    test('updateRedactor mid-stream catches a newly-registered secret',
        () async {
      final r = StreamingVaultRedactor(VaultRedactor.empty);
      // Empty redactor → first chunk passes through.
      final out1 = r.feed('hello world ');
      expect(out1, 'hello world ');

      // Now register a secret that appears in the next chunk.
      r.updateRedactor(VaultRedactor.from([_s('LATE', 'late-token-xyz')]));
      final out2 = r.feed('here comes late-token-xyz now');
      final tail = r.flush();
      final all = out1 + out2 + tail;
      expect(all.contains('late-token-xyz'), isFalse);
      expect(all.contains('••••••• (vault: LATE)'), isTrue);
    });
  });
}
