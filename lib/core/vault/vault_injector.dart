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
  VaultInjector(List<VaultSecret> secrets,
      {Map<String, List<VaultSecret>>? secretsByGroup})
      : _byName = _buildLookup(secrets),
        _byGroup = secretsByGroup ?? const {};

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
  final Map<String, List<VaultSecret>> _byGroup;

  static final RegExp _placeholder =
      RegExp(r'\$\{vault:([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\}');

  VaultSecret? _lookupSecret(String name) {
    if (name.contains('.')) {
      final parts = name.split('.');
      final groupName = parts[0].toUpperCase();
      final fieldName = parts[1].toUpperCase();
      final group = _byGroup[groupName];
      if (group != null) {
        for (final s in group) {
          if (s.name.toUpperCase() == fieldName) {
            return s;
          }
        }
      }
    }
    return _byName[name];
  }

  /// Returns true when [command] contains at least one
  /// `${vault:NAME}` or `${vault:GROUP.FIELD}` placeholder.
  bool hasPlaceholders(String command) => _placeholder.hasMatch(command);

  /// Returns the names of every placeholder appearing in [command],
  /// in textual order with duplicates preserved.
  List<String> placeholderNames(String command) {
    return _placeholder
        .allMatches(command)
        .map((m) => m.group(1)!)
        .toList();
  }

  /// Substitute every placeholder. Throws [VaultInjectionException] if
  /// a placeholder names a secret that isn't in scope.
  String inject(String command) {
    return command.replaceAllMapped(_placeholder, (m) {
      final name = m.group(1)!;
      final secret = _lookupSecret(name);
      if (secret == null) {
        throw VaultInjectionException(
          'No vault secret named "$name" is in scope for this server.',
        );
      }
      return secret.value;
    });
  }

  /// Wraps [command] so vault placeholders resolve via env vars.
  EnvInjectedCommand buildEnvCommand(String command) {
    final names = <String>{};
    final missing = <String>{};
    for (final m in _placeholder.allMatches(command)) {
      final name = m.group(1)!;
      if (_lookupSecret(name) != null) {
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
    final env = {for (final n in names) n: _lookupSecret(n)!.value};
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

  /// Injects all secrets in [groupName] as env vars and wraps [command].
  EnvInjectedCommand buildGroupEnvCommand(String groupName, String command) {
    final group = _byGroup[groupName.toUpperCase()];
    if (group == null) {
      throw VaultInjectionException(
        'No vault group named "$groupName" is in scope.',
      );
    }

    final env = <String, String>{};
    final names = <String>[];
    for (final s in group) {
      env[s.name] = s.value;
      names.add(s.name);
    }

    final exportPrefix = names
        .map((n) => '$n=${_singleQuote(env[n]!)}')
        .join(' ');

    final wrapped = ' $exportPrefix bash -lc ${_singleQuote(command)}';

    return EnvInjectedCommand(
      wrappedCommand: wrapped,
      placeholderNames: names,
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
            if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?$')
                .hasMatch(name)) {
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
