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
  group('VaultInjector.buildEnvCommand — env-var injection', () {
    test('passthrough when no placeholders', () {
      final injector = VaultInjector([_s('TOKEN', 'abc123secret')]);
      final wrapped = injector.buildEnvCommand('echo hi');
      expect(wrapped.wrappedCommand, 'echo hi');
      expect(wrapped.placeholderNames, isEmpty);
      expect(wrapped.env, isEmpty);
    });

    test('replaces placeholder with "\${NAME}" reference and prepends '
        'env-var assignment, never the literal value', () {
      final injector = VaultInjector([_s('DBPASS', 'super-secret-value')]);
      final wrapped = injector.buildEnvCommand(
        'psql -h db -U app -W \${vault:DBPASS}',
      );

      // The wire-side command body must NOT contain the literal value
      // anywhere except as a single-quoted env-var assignment.
      expect(
        wrapped.wrappedCommand.contains('psql -h db -U app -W "\${DBPASS}"'),
        isTrue,
        reason: 'command body should reference env var, not raw value',
      );
      expect(
        wrapped.wrappedCommand.contains("DBPASS='super-secret-value'"),
        isTrue,
        reason: 'env var should be single-quoted assignment',
      );
      // The substituted body itself must not contain the raw value.
      final body = wrapped.wrappedCommand.split('bash -lc ').last;
      expect(
        body.contains('super-secret-value'),
        isFalse,
        reason:
            'the bash -lc body must reference \${DBPASS}, never the value',
      );
      expect(wrapped.placeholderNames, contains('DBPASS'));
      expect(wrapped.env['DBPASS'], 'super-secret-value');
    });

    test('safely escapes single quotes in the secret value', () {
      final injector = VaultInjector([_s('PWD', "it's-a-trap")]);
      final wrapped = injector.buildEnvCommand('cat <<< \${vault:PWD}');
      // The escaped form is the close-and-reopen idiom: 'it'\''s-a-trap'
      expect(
        wrapped.wrappedCommand.contains(r"PWD='it'\''s-a-trap'"),
        isTrue,
        reason: 'single quotes in value must be escaped via close/reopen',
      );
    });

    test('shell metacharacters in the secret value cannot break out', () {
      // \$, backtick, double-quote, newline, semicolon — all of these
      // would be catastrophic under literal substitution. Single-quoted
      // bash strings disable every metacharacter except the single
      // quote itself, so they must survive verbatim inside the env
      // assignment.
      const tricky = r'$(rm -rf /)`evil`"hi";'
          '\n'
          'newline';
      final injector = VaultInjector([_s('EVIL', tricky)]);
      final wrapped = injector.buildEnvCommand('echo \${vault:EVIL}');
      // Make sure none of the metacharacters appear inside the
      // bash -lc body — they must only live inside the single-quoted
      // env block.
      final parts = wrapped.wrappedCommand.split('bash -lc ');
      final body = parts.last;
      expect(body.contains(r'rm -rf /'), isFalse);
      expect(body.contains('newline'), isFalse);
      expect(body.contains('"hi"'), isFalse);
    });

    test('throws VaultInjectionException on unknown placeholder', () {
      final injector = VaultInjector([_s('KNOWN', 'value-here')]);
      expect(
        () => injector.buildEnvCommand('echo \${vault:UNKNOWN}'),
        throwsA(isA<VaultInjectionException>()),
      );
    });

    test('deduplicates repeated placeholders in the env block', () {
      final injector = VaultInjector([_s('TOK', 'aaaaaa-token')]);
      final wrapped = injector.buildEnvCommand(
        'echo \${vault:TOK} && curl -H "Auth: \${vault:TOK}"',
      );
      // env assignment appears exactly once even though the
      // placeholder appears twice.
      final assignments = 'TOK='.allMatches(wrapped.wrappedCommand).length;
      expect(assignments, 1);
      expect(wrapped.placeholderNames, ['TOK']);
    });
  });
}
