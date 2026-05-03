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
}

class VaultInjectionException implements Exception {
  const VaultInjectionException(this.message);
  final String message;
  @override
  String toString() => message;
}
