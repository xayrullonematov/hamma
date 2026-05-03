import 'vault_secret.dart';

/// Substitutes `${vault:NAME}` placeholders in a command string with
/// the matching secret value drawn from a scoped lookup.
///
/// The substituted command is what we hand to the SSH transport — but
/// the **original** placeholder string is what the in-app command
/// history retains, so the secret never lands in scrollback or
/// breadcrumbs. See [SshService.execute] for the call site.
class VaultInjector {
  /// Server-scoped secrets shadow globals of the same name.
  VaultInjector(List<VaultSecret> secrets)
      : _byName = _buildLookup(secrets);

  static Map<String, VaultSecret> _buildLookup(List<VaultSecret> secrets) {
    final out = <String, VaultSecret>{};
    for (final s in secrets) {
      final existing = out[s.name];
      if (existing == null || (existing.isGlobal && !s.isGlobal)) {
        out[s.name] = s;
      }
    }
    return out;
  }

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

  /// Wraps [command] so vault placeholders resolve via env vars
  /// instead of inline substitution. See `docs/secrets-vault.md`.
  /// Throws [VaultInjectionException] on an unknown placeholder.
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
    final substituted = _shellAwareSubstitute(command);
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

  /// POSIX shell quoting-aware substitution. Outside quotes →
  /// `"$NAME"`; inside `"…"` → bare `$NAME`; inside `'…'` → close,
  /// `"$NAME"`, reopen.
  static String _shellAwareSubstitute(String command) {
    final out = StringBuffer();
    bool inSingle = false;
    bool inDouble = false;
    int i = 0;
    while (i < command.length) {
      final c = command[i];
      if (!inSingle && c == r'\' && i + 1 < command.length) {
        out.write(c);
        out.write(command[i + 1]);
        i += 2;
        continue;
      }
      if (!inSingle && c == '"') {
        inDouble = !inDouble;
        out.write(c);
        i++;
        continue;
      }
      if (!inDouble && c == "'") {
        inSingle = !inSingle;
        out.write(c);
        i++;
        continue;
      }
      // Try to match `${vault:NAME}` starting at i.
      if (c == r'$' &&
          i + 1 < command.length &&
          command[i + 1] == '{') {
        final close = command.indexOf('}', i + 2);
        if (close > 0) {
          final inside = command.substring(i + 2, close);
          if (inside.startsWith('vault:')) {
            final name = inside.substring(6);
            if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
              if (inSingle) {
                // close ' then "${NAME}" then reopen '
                out.write("'\"\${$name}\"'");
              } else if (inDouble) {
                out.write('\${$name}');
              } else {
                out.write('"\${$name}"');
              }
              i = close + 1;
              continue;
            }
          }
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }
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
