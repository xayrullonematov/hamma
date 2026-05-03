import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_injector.dart';
import 'package:hamma/core/vault/vault_secret.dart';

VaultSecret _s(String name, String value, {String? scope}) => VaultSecret(
      id: name,
      name: name,
      value: value,
      scope: scope,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('VaultInjector.inject', () {
    test('substitutes a single placeholder', () {
      final inj = VaultInjector([_s('DB_PASSWORD', 'hunter2')]);
      expect(
        inj.inject(r'PGPASSWORD=${vault:DB_PASSWORD} psql -h db'),
        'PGPASSWORD=hunter2 psql -h db',
      );
    });

    test('substitutes multiple distinct placeholders', () {
      final inj = VaultInjector([
        _s('USER', 'alice'),
        _s('PASS', 'rosebud'),
      ]);
      expect(
        inj.inject(r'login --user=${vault:USER} --pass=${vault:PASS}'),
        'login --user=alice --pass=rosebud',
      );
    });

    test('substitutes the same placeholder more than once', () {
      final inj = VaultInjector([_s('TOKEN', 'abc-xyz')]);
      expect(
        inj.inject(r'echo ${vault:TOKEN} && curl -H "X: ${vault:TOKEN}"'),
        'echo abc-xyz && curl -H "X: abc-xyz"',
      );
    });

    test('throws VaultInjectionException on an unknown placeholder', () {
      final inj = VaultInjector(const []);
      expect(
        () => inj.inject(r'echo ${vault:MISSING}'),
        throwsA(isA<VaultInjectionException>()),
      );
    });

    test('hasPlaceholders / placeholderNames report accurately', () {
      final inj = VaultInjector(const []);
      expect(inj.hasPlaceholders('plain command'), isFalse);
      expect(
        inj.hasPlaceholders(r'use ${vault:K}'),
        isTrue,
      );
      expect(
        inj.placeholderNames(r'a=${vault:A} b=${vault:B} a=${vault:A}'),
        ['A', 'B', 'A'],
      );
    });

    test('leaves a non-vault \${...} expression alone', () {
      final inj = VaultInjector(const []);
      // A normal shell expansion is not a vault placeholder.
      expect(
        inj.inject(r'echo $HOME and ${OTHER}'),
        r'echo $HOME and ${OTHER}',
      );
    });
  });
}
