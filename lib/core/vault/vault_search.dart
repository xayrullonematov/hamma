import 'vault_group.dart';
import 'vault_secret.dart';

enum VaultMatchSource { groupName, fieldName, tag, secretName }

/// Result of a search query against the vault index.
class VaultSearchResult {
  /// The ID of the group that matched, or the group containing the matching field.
  final String? groupId;

  /// The ID of the specific secret that matched.
  final String? secretId;

  /// Which field in the model triggered the match.
  final VaultMatchSource matchedOn;

  VaultSearchResult({
    this.groupId,
    this.secretId,
    required this.matchedOn,
  });
}

/// In-memory index for searching and filtering vault contents.
///
/// This index stores group names, field labels, and tags. It NEVER stores
/// secret values to avoid sensitive data lingering in plaintext memory
/// outside of the secure storage boundaries.
class VaultSearchIndex {
  List<VaultGroup> _groups = [];
  List<VaultSecret> _secrets = [];

  /// Refresh the index with the latest state from storage.
  void buildIndex(List<VaultGroup> groups, List<VaultSecret> secrets) {
    _groups = List.from(groups);
    _secrets = List.from(secrets);
  }

  /// Returns results matching [query] across names, fields, and tags.
  List<VaultSearchResult> search(String query) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    final results = <VaultSearchResult>[];

    // Search groups
    for (final g in _groups) {
      if (g.name.toLowerCase().contains(q)) {
        results.add(VaultSearchResult(
          groupId: g.id,
          matchedOn: VaultMatchSource.groupName,
        ));
      }
      for (final tag in g.tags) {
        if (tag.toLowerCase().contains(q)) {
          results.add(VaultSearchResult(
            groupId: g.id,
            matchedOn: VaultMatchSource.tag,
          ));
          break; // One match per group for tags
        }
      }
    }

    // Search secrets (field labels/names)
    for (final s in _secrets) {
      if (s.name.toLowerCase().contains(q)) {
        if (s.groupId != null) {
          results.add(VaultSearchResult(
            groupId: s.groupId,
            secretId: s.id,
            matchedOn: VaultMatchSource.fieldName,
          ));
        } else {
          results.add(VaultSearchResult(
            secretId: s.id,
            matchedOn: VaultMatchSource.secretName,
          ));
        }
      }
    }

    return results;
  }

  /// Filters groups based on type, tag, and server scope.
  List<VaultGroup> filter(CredentialType? type, String? tag, String? scope) {
    return _groups.where((g) {
      if (type != null && g.type != type) return false;
      if (tag != null && !g.tags.contains(tag)) return false;

      // Scope filter: at least one secret in the group must match the scope
      if (scope != null) {
        final groupSecrets = _secrets.where((s) => s.groupId == g.id);
        if (!groupSecrets.any((s) => s.scope == scope)) return false;
      }

      return true;
    }).toList();
  }

  /// Filters ungrouped secrets based on scope.
  List<VaultSecret> filterUngrouped(String? scope) {
    return _secrets.where((s) {
      if (s.groupId != null) return false;
      if (scope != null && s.scope != scope) return false;
      return true;
    }).toList();
  }
}
