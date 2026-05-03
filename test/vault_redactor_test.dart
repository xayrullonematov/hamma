import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_redactor.dart';
import 'package:hamma/core/vault/vault_secret.dart';

VaultSecret _s(String name, String value) => VaultSecret(
      id: name,
      name: name,
      value: value,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('VaultRedactor', () {
    test('empty redactor returns input unchanged', () {
      expect(VaultRedactor.empty.redact('hello world'), 'hello world');
    });

    test('redacts a single occurrence with the marker form', () {
      final r = VaultRedactor.from([_s('DB_PASSWORD', 's3cret-token-xyz')]);
      expect(
        r.redact('connecting with s3cret-token-xyz now'),
        'connecting with ••••••• (vault: DB_PASSWORD) now',
      );
    });

    test('redacts every occurrence (multi-occurrence)', () {
      final r = VaultRedactor.from([_s('K', 'abcdef-1234')]);
      expect(
        r.redact('abcdef-1234 then again abcdef-1234 done'),
        '••••••• (vault: K) then again ••••••• (vault: K) done',
      );
    });

    test('skips values shorter than the false-positive floor', () {
      // "pi" is 2 chars — well below the 6-char floor.
      final r = VaultRedactor.from([_s('PI', 'pi')]);
      expect(r.redact('the pi value'), 'the pi value');
      expect(r.isEmpty, isTrue);
    });

    test('skips invalid secrets (empty value)', () {
      final r = VaultRedactor.from([_s('EMPTY', '')]);
      expect(r.redact('anything'), 'anything');
      expect(r.isEmpty, isTrue);
    });

    test('matches longest first to avoid prefix shadowing', () {
      // Both secrets share a common prefix; longest must win.
      final r = VaultRedactor.from([
        _s('SHORT', 'token-abc'),
        _s('LONG', 'token-abc-extended'),
      ]);
      expect(
        r.redact('value=token-abc-extended'),
        'value=••••••• (vault: LONG)',
      );
    });

    test('is unicode-safe (operates on code units, no false matches)', () {
      final r = VaultRedactor.from([_s('GREETING', 'こんにちは世界')]);
      expect(
        r.redact('payload: こんにちは世界 trailing'),
        'payload: ••••••• (vault: GREETING) trailing',
      );
      // Unrelated unicode is untouched.
      expect(r.redact('hello'), 'hello');
    });

    test('case-sensitive — Token and token are different secrets', () {
      final r = VaultRedactor.from([_s('UPPER', 'TOKENVALUE')]);
      expect(r.redact('see tokenvalue here'), 'see tokenvalue here');
      expect(
        r.redact('see TOKENVALUE here'),
        'see ••••••• (vault: UPPER) here',
      );
    });

    test('null and empty input return empty string safely', () {
      final r = VaultRedactor.from([_s('K', 'abcdef')]);
      expect(r.redact(null), '');
      expect(r.redact(''), '');
    });
  });

  group('GlobalVaultRedactor', () {
    setUp(GlobalVaultRedactor.reset);
    tearDown(GlobalVaultRedactor.reset);

    test('defaults to the empty redactor', () {
      expect(GlobalVaultRedactor.current.isEmpty, isTrue);
    });

    test('can be set and read back', () {
      GlobalVaultRedactor.set(
        VaultRedactor.from([_s('K', 'shared-secret-12345')]),
      );
      expect(
        GlobalVaultRedactor.current.redact('use shared-secret-12345'),
        'use ••••••• (vault: K)',
      );
    });
  });
}
