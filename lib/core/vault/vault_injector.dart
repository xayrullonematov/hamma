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

  /// Builds a non-interactive shell command that exposes each
  /// referenced vault secret as a per-command environment variable
  /// instead of pasting the literal value into the command line.
  ///
  /// For a command like `psql -h db -U app -W ${vault:DBPASS}` with
  /// a secret `DBPASS = "p@$$"`, the result is:
  ///
  ///   `DBPASS='p@$$' bash -lc 'psql -h db -U app -W "${DBPASS}"'`
  ///
  /// Why this shape:
  /// - The secret value never appears literally in the user-visible
  ///   command body — only `"${DBPASS}"` does — so a stray screenshot
  ///   of `ps`/`history`/breadcrumbs cannot leak it. (Note: the env
  ///   block itself does pass through `argv` on the remote host; the
  ///   `env` command would be a stronger isolation boundary but isn't
  ///   universally available. This is a documented trade-off in
  ///   `docs/secrets-vault.md`.)
  /// - Single-quoted bash strings disable every metacharacter except
  ///   the single quote itself, which we escape via the
  ///   `'\''` close-and-reopen idiom.
  /// - `bash -lc` is used because non-interactive shells do not write
  ///   `~/.bash_history`, so the resolved command never lands in
  ///   shell history on the remote box.
  /// - A leading space is prepended for `HISTCONTROL=ignorespace`
  ///   environments where the outer login shell *does* try to record
  ///   the wrapper command for some reason.
  ///
  /// Throws [VaultInjectionException] if any referenced placeholder
  /// is not in scope.
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
