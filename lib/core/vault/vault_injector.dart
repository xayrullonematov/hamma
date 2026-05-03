import 'vault_secret.dart';

/// Substitutes `${vault:NAME}` placeholders in a command string with
/// the matching secret value drawn from a scoped lookup.
///
/// The substituted command is what we hand to the SSH transport — but
/// the **original** placeholder string is what the in-app command
/// history retains, so the secret never lands in scrollback or
/// breadcrumbs. See [SshService.execute] for the call site.
class VaultInjector {
  VaultInjector(List<VaultSecret> secrets)
      : _byName = {for (final s in secrets) s.name: s};

  final Map<String, VaultSecret> _byName;

  static final RegExp _placeholder =
      RegExp(r'\$\{vault:([A-Za-z_][A-Za-z0-9_]*)\}');

  /// Returns true when [command] contains at least one
  /// `${vault:NAME}` placeholder. Used by callers that want to know
  /// whether substitution will mutate the string before they decide
  /// what to keep in history.
  bool hasPlaceholders(String command) => _placeholder.hasMatch(command);

  /// Returns the names of every placeholder appearing in [command],
  /// in textual order with duplicates preserved. Useful for diagnostic
  /// breadcrumbs ("ran command with vault: DB_PASSWORD") that don't
  /// leak the value.
  List<String> placeholderNames(String command) {
    return _placeholder
        .allMatches(command)
        .map((m) => m.group(1)!)
        .toList();
  }

  /// Substitute every placeholder. Throws [VaultInjectionException] if
  /// a placeholder names a secret that isn't in scope — failing loud
  /// is the right call here: silently passing the literal `${vault:X}`
  /// to the remote shell would either confuse the user or leak the
  /// placeholder shape into logs.
  ///
  /// **Prefer [buildEnvCommand] for live SSH execution** — literal
  /// substitution puts the raw value into the command line, where it
  /// can collide with shell metacharacters in the secret value and
  /// (on interactive shells) be echoed back into history. [inject] is
  /// kept for tests and code paths that explicitly need the resolved
  /// string (e.g. dry-run preview that immediately discards it).
  String inject(String command) {
    return command.replaceAllMapped(_placeholder, (m) {
      final name = m.group(1)!;
      final secret = _byName[name];
      if (secret == null) {
        throw VaultInjectionException(
          'No vault secret named "$name" is in scope for this server.',
        );
      }
      return secret.value;
    });
  }

  /// Wraps [command] so each referenced vault secret is exposed via
  /// a per-command environment variable instead of being substituted
  /// inline. See `docs/secrets-vault.md` for the rewrite shape, the
  /// quoting rules, and the (documented) `argv` exposure trade-off.
  /// Throws [VaultInjectionException] if a placeholder is unknown.
  EnvInjectedCommand buildEnvCommand(String command) {
    final names = <String>{};
    final missing = <String>{};
    for (final m in _placeholder.allMatches(command)) {
      final name = m.group(1)!;
      if (_byName.containsKey(name)) {
        names.add(name);
      } else {
        missing.add(name);
      }
    }
    if (missing.isNotEmpty) {
      throw VaultInjectionException(
        'No vault secret named "${missing.first}" is in scope for this '
        'server.',
      );
    }
    if (names.isEmpty) {
      return EnvInjectedCommand(
        wrappedCommand: command,
        placeholderNames: const [],
        env: const {},
      );
    }
    final substituted = command.replaceAllMapped(
      _placeholder,
      (m) => '"\${${m.group(1)!}}"',
    );
    final env = {for (final n in names) n: _byName[n]!.value};
    final exportPrefix = names
        .map((n) => '$n=${_singleQuote(env[n]!)}')
        .join(' ');
    final wrapped =
        ' $exportPrefix bash -lc ${_singleQuote(substituted)}';
    return EnvInjectedCommand(
      wrappedCommand: wrapped,
      placeholderNames: names.toList(growable: false),
      env: env,
    );
  }

  static String _singleQuote(String s) =>
      "'${s.replaceAll("'", r"'\''")}'";
}

/// Result of [VaultInjector.buildEnvCommand]. The wrapped command is
/// what we hand to the SSH transport; [env] is exposed for tests so
/// they can assert that the secret value never appears in
/// [wrappedCommand] except as a single-quoted env-var assignment.
class EnvInjectedCommand {
  const EnvInjectedCommand({
    required this.wrappedCommand,
    required this.placeholderNames,
    required this.env,
  });

  final String wrappedCommand;
  final List<String> placeholderNames;
  final Map<String, String> env;
}

class VaultInjectionException implements Exception {
  const VaultInjectionException(this.message);
  final String message;
  @override
  String toString() => message;
}
