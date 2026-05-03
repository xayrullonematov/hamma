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

    test('placeholder inside single-quoted string: closes-and-reopens '
        'so the env var actually expands', () {
      final injector = VaultInjector([_s('TOKEN', 'bearer-xyz-1234')]);
      final wrapped = injector.buildEnvCommand(
        "curl -H 'Authorization: Bearer \${vault:TOKEN}' https://api",
      );
      // The bash -lc body must contain the close+reopen idiom
      // 'lit'"\${TOKEN}"'lit', NOT a literal `\${TOKEN}` left
      // inside a single-quoted string (which would never expand).
      final body = wrapped.wrappedCommand.split('bash -lc ').last;
      expect(
        body.contains("'\"\${TOKEN}\"'"),
        isTrue,
        reason:
            'placeholder inside \'…\' must be rewritten as '
            "'\"\${TOKEN}\"' so the env var expands at runtime",
      );
      expect(
        body.contains('bearer-xyz-1234'),
        isFalse,
        reason: 'literal value must NOT appear inside the bash -lc body',
      );
    });

    test('placeholder inside double-quoted string: bare \${NAME} '
        '(no extra quotes — surrounding "…" already covers it)', () {
      final injector = VaultInjector([_s('TOK', 'val-1234567')]);
      final wrapped = injector.buildEnvCommand(
        'echo "Bearer \${vault:TOK} done"',
      );
      final body = wrapped.wrappedCommand.split('bash -lc ').last;
      expect(body.contains('"Bearer \${TOK} done"'), isTrue);
      expect(body.contains('val-1234567'), isFalse);
    });

    test('mixed quoting in the same command', () {
      final injector = VaultInjector([
        _s('A', 'aaaaaa-secret'),
        _s('B', 'bbbbbb-secret'),
      ]);
      final wrapped = injector.buildEnvCommand(
        "echo \${vault:A} 'inside-\${vault:B}-end'",
      );
      final body = wrapped.wrappedCommand.split('bash -lc ').last;
      expect(body.contains('"\${A}"'), isTrue,
          reason: 'unquoted A becomes "\${A}"');
      expect(body.contains("'\"\${B}\"'"), isTrue,
          reason: "single-quoted B becomes 'lit'\"\${B}\"'lit'");
      expect(body.contains('aaaaaa-secret'), isFalse);
      expect(body.contains('bbbbbb-secret'), isFalse);
    });

    test('server-scoped secret wins over a global secret of the same name',
        () {
      final global = VaultSecret(
        id: 'g',
        name: 'TOKEN',
        value: 'GLOBAL-VALUE-ZZZ',
        scope: null,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final scoped = VaultSecret(
        id: 's',
        name: 'TOKEN',
        value: 'SCOPED-VALUE-AAA',
        scope: 'server-42',
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      // Pass them in either order — the scoped one MUST win.
      for (final order in [
        [global, scoped],
        [scoped, global],
      ]) {
        final injector = VaultInjector(order);
        final wrapped = injector.buildEnvCommand('echo \${vault:TOKEN}');
        expect(wrapped.env['TOKEN'], 'SCOPED-VALUE-AAA',
            reason: 'server-scoped secret must override global');
        expect(
          wrapped.wrappedCommand.contains('GLOBAL-VALUE-ZZZ'),
          isFalse,
          reason: 'wrong-host disclosure: global value must not leak '
              'when a scoped one exists',
        );
      }
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
