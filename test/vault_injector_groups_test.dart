import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_injector.dart';
import 'package:hamma/core/vault/vault_secret.dart';

VaultSecret _s(String name, String value) => VaultSecret(
      id: name.toLowerCase(),
      name: name,
      value: value,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('VaultInjector with Groups', () {
    final secrets = [_s('FLAT', 'flat-val')];
    final groups = {
      'AWS': [_s('KEY', 'aws-key-val'), _s('SECRET', 'aws-secret-val')],
      'PROD_DB': [_s('PASSWORD', 'db-pass-val')],
    };

    test('supports dotted syntax for group lookup', () {
      final injector = VaultInjector(secrets, secretsByGroup: groups);
      
      expect(injector.inject('echo \${vault:AWS.KEY}'), 'echo aws-key-val');
      expect(injector.inject('echo \${vault:PROD_DB.PASSWORD}'), 'echo db-pass-val');
    });

    test('falls back to flat name if dotted lookup fails', () {
      final mixed = [_s('MY.DOTTED', 'dotted-flat-val')];
      final injector = VaultInjector(mixed, secretsByGroup: groups);
      
      expect(injector.inject('echo \${vault:MY.DOTTED}'), 'echo dotted-flat-val');
    });

    test('buildEnvCommand handles dotted names and shell quoting', () {
      final injector = VaultInjector(secrets, secretsByGroup: groups);
      final wrapped = injector.buildEnvCommand('echo \${vault:AWS.KEY}');
      
      expect(wrapped.env['AWS.KEY'], 'aws-key-val');
      expect(wrapped.placeholderNames, ['AWS.KEY']);
      expect(wrapped.wrappedCommand.contains("AWS.KEY='aws-key-val'"), isTrue);
      expect(wrapped.wrappedCommand.contains('"\${AWS.KEY}"'), isTrue);
    });

    test('buildGroupEnvCommand injects all secrets in a group', () {
      final injector = VaultInjector(secrets, secretsByGroup: groups);
      final wrapped = injector.buildGroupEnvCommand('AWS', 'deploy.sh');
      
      expect(wrapped.env['KEY'], 'aws-key-val');
      expect(wrapped.env['SECRET'], 'aws-secret-val');
      expect(wrapped.placeholderNames, containsAll(['KEY', 'SECRET']));
      expect(wrapped.wrappedCommand.contains("KEY='aws-key-val'"), isTrue);
      expect(wrapped.wrappedCommand.contains("SECRET='aws-secret-val'"), isTrue);
      expect(wrapped.wrappedCommand.contains("bash -lc 'deploy.sh'"), isTrue);
    });

    test('placeholderNames returns full dotted name', () {
      final injector = VaultInjector(secrets, secretsByGroup: groups);
      final names = injector.placeholderNames('echo \${vault:AWS.KEY} and \${vault:FLAT}');
      
      expect(names, ['AWS.KEY', 'FLAT']);
    });

    test('throws exception for unknown group or unknown field', () {
      final injector = VaultInjector(secrets, secretsByGroup: groups);
      
      expect(() => injector.inject('\${vault:UNKNOWN.FIELD}'), throwsA(isA<VaultInjectionException>()));
      expect(() => injector.inject('\${vault:AWS.UNKNOWN}'), throwsA(isA<VaultInjectionException>()));
    });
  });
}
