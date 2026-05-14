import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

import 'vault_change_bus.dart';
import 'vault_group.dart';
import 'vault_secret.dart';

/// Newest-wins sync metadata for the vault, mirroring the snippet sync
/// model: per-id `updatedAt` and tombstones for deleted ids.
@immutable
class VaultSyncMeta {
  const VaultSyncMeta({
    required this.updatedAt,
    required this.tombstones,
    this.groupTombstones = const {},
  });

  final Map<String, DateTime> updatedAt;
  final Map<String, DateTime> tombstones;
  final Map<String, DateTime> groupTombstones;

  static const VaultSyncMeta empty =
      VaultSyncMeta(updatedAt: {}, tombstones: {}, groupTombstones: {});

  Map<String, dynamic> toJson() => {
        'updatedAt': {
          for (final e in updatedAt.entries) e.key: e.value.toIso8601String(),
        },
        'tombstones': {
          for (final e in tombstones.entries) e.key: e.value.toIso8601String(),
        },
        'groupTombstones': {
          for (final e in groupTombstones.entries) e.key: e.value.toIso8601String(),
        },
      };

  factory VaultSyncMeta.fromJson(Map<String, dynamic> json) {
    Map<String, DateTime> parse(Object? raw) {
      if (raw is! Map) return <String, DateTime>{};
      final out = <String, DateTime>{};
      for (final e in raw.entries) {
        final ts = DateTime.tryParse(e.value?.toString() ?? '');
        if (ts != null) out[e.key.toString()] = ts;
      }
      return out;
    }

    return VaultSyncMeta(
      updatedAt: parse(json['updatedAt']),
      tombstones: parse(json['tombstones']),
      groupTombstones: parse(json['groupTombstones']),
    );
  }
}

/// Persists vault entries inside the OS secure-storage backend
/// (Keychain / Keystore / libsecret / DPAPI via flutter_secure_storage).
///
/// Storage layout:
///   - `vault_index` → JSON list of `{id, name, scope}` records used to
///     enumerate without decrypting every value individually.
///   - `vault_value_<id>` → plaintext value (encrypted at rest by the
///     OS keystore — secure_storage only stores ciphertext on disk).
///   - `vault_meta_<id>` → `{description, updatedAt, groupId, lastUsedAt, rotateBy}` JSON.
///   - `vault_group_index` → JSON list of `{id, name, type, tags}` records.
///   - `vault_group_<id>` → full [VaultGroup] JSON.
///   - `vault_sync_meta` → [VaultSyncMeta] JSON for the sync layer.
///
/// Every successful mutation fires [VaultChangeBus.notify] so listeners
/// (sync uploader + redaction pipeline) react without polling.
class VaultStorage {
  VaultStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _indexKey = 'vault_index';
  static const _syncMetaKey = 'vault_sync_meta';
  static const _valuePrefix = 'vault_value_';
  static const _metaPrefix = 'vault_meta_';
  static const _deviceIdKey = 'vault_device_id';

  static const _groupIndexKey = 'vault_group_index';
  static const _groupPrefix = 'vault_group_';

  final FlutterSecureStorage _secureStorage;

  /// Returns every secret in the store. The plaintext values are
  /// included; callers MUST treat the return value as sensitive.
  Future<List<VaultSecret>> loadAll() async {
    final index = await _readIndex();
    final out = <VaultSecret>[];
    for (final entry in index) {
      final id = entry['id']!;
      final value = await _secureStorage.read(key: '$_valuePrefix$id');
      if (value == null) continue; // index/value drift — skip
      final metaRaw = await _secureStorage.read(key: '$_metaPrefix$id');
      final meta = metaRaw == null
          ? const <String, dynamic>{}
          : (jsonDecode(metaRaw) as Map).cast<String, dynamic>();
      out.add(VaultSecret(
        id: id,
        name: entry['name'] ?? '',
        value: value,
        scope: entry['scope'] == '' ? null : entry['scope'],
        description: (meta['description'] ?? '').toString(),
        updatedAt: DateTime.tryParse((meta['updatedAt'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        groupId: meta['groupId']?.toString(),
        lastUsedAt: DateTime.tryParse((meta['lastUsedAt'] ?? '').toString()),
        rotateBy: DateTime.tryParse((meta['rotateBy'] ?? '').toString()),
      ));
    }
    return out;
  }

  /// Loads only the secrets visible to [serverId] — i.e. all global
  /// secrets PLUS any secrets scoped to that server. Used by the
  /// injector + the per-server linking UI.
  Future<List<VaultSecret>> loadVisibleTo(String? serverId) async {
    final all = await loadAll();
    return all
        .where((s) => s.isGlobal || (serverId != null && s.scope == serverId))
        .toList();
  }

  /// Loads all secrets belonging to a specific group.
  Future<List<VaultSecret>> loadByGroup(String groupId) async {
    final all = await loadAll();
    return all.where((s) => s.groupId == groupId).toList();
  }

  /// Insert or update [secret]. Names are normalised to the canonical
  /// `${vault:NAME}` form (uppercase letters / digits / underscore)
  /// before persistence so the injector and the redactor share one
  /// lookup key.
  ///
  /// Returns the persisted secret (with normalised name + refreshed
  /// `updatedAt`). Throws [ArgumentError] if [secret] is invalid or if
  /// another secret already uses the same `(scope, name)` pair.
  Future<VaultSecret> upsert(VaultSecret secret) async {
    final normalised = secret.copyWith(
      name: _canonicaliseName(secret.name),
      updatedAt: DateTime.now().toUtc(),
    );
    if (!normalised.isValid) {
      throw ArgumentError.value(
        secret.name,
        'name',
        'Vault names must match [A-Za-z_][A-Za-z0-9_]* and value must not '
            'be empty.',
      );
    }

    final index = await _readIndex();
    // Reject duplicate (scope, name) — unless we're updating in place.
    for (final entry in index) {
      if (entry['id'] == normalised.id) continue;
      if ((entry['scope'] ?? '') == (normalised.scope ?? '') &&
          entry['name'] == normalised.name) {
        throw ArgumentError(
          'A secret named ${normalised.name} already exists in this scope.',
        );
      }
    }

    final id = normalised.id.isEmpty ? _generateId() : normalised.id;
    final updated = normalised.copyWith(id: id);

    await _secureStorage.write(
      key: '$_valuePrefix$id',
      value: updated.value,
    );
    await _secureStorage.write(
      key: '$_metaPrefix$id',
      value: jsonEncode({
        'description': updated.description,
        'updatedAt': updated.updatedAt.toIso8601String(),
        'groupId': updated.groupId,
        'lastUsedAt': updated.lastUsedAt?.toIso8601String(),
        'rotateBy': updated.rotateBy?.toIso8601String(),
      }),
    );

    final newIndex = index.where((e) => e['id'] != id).toList()
      ..add({
        'id': id,
        'name': updated.name,
        'scope': updated.scope ?? '',
      });
    await _writeIndex(newIndex);

    // Sync meta: bump updatedAt, clear any stale tombstone.
    final meta = await loadSyncMeta();
    final newMeta = VaultSyncMeta(
      updatedAt: {...meta.updatedAt, id: updated.updatedAt},
      tombstones: {...meta.tombstones}..remove(id),
      groupTombstones: {...meta.groupTombstones},
    );
    await saveSyncMeta(newMeta);

    VaultChangeBus.instance.notify();
    return updated;
  }

  /// Delete the secret identified by [id]. Idempotent. Records a
  /// tombstone in the sync meta so a stale remote copy can't resurrect
  /// it on the next pull.
  Future<void> delete(String id) async {
    await _secureStorage.delete(key: '$_valuePrefix$id');
    await _secureStorage.delete(key: '$_metaPrefix$id');

    final index = await _readIndex();
    final newIndex = index.where((e) => e['id'] != id).toList();
    await _writeIndex(newIndex);

    final meta = await loadSyncMeta();
    final now = DateTime.now().toUtc();
    final newMeta = VaultSyncMeta(
      updatedAt: {...meta.updatedAt}..remove(id),
      tombstones: {...meta.tombstones, id: now},
      groupTombstones: {...meta.groupTombstones},
    );
    await saveSyncMeta(newMeta);

    VaultChangeBus.instance.notify();
  }

  /// Returns every group in the store.
  Future<List<VaultGroup>> loadAllGroups() async {
    final index = await _readGroupIndex();
    final out = <VaultGroup>[];
    for (final entry in index) {
      final id = entry['id']!;
      final raw = await _secureStorage.read(key: '$_groupPrefix$id');
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          out.add(VaultGroup.fromJson(decoded));
        } else if (decoded is Map) {
          out.add(VaultGroup.fromJson(decoded.cast<String, dynamic>()));
        }
      } catch (_) {
        // Corrupt group data — skip
      }
    }
    return out;
  }

  /// Insert or update [group].
  Future<VaultGroup> upsertGroup(VaultGroup group) async {
    final id = group.id.isEmpty ? _generateId() : group.id;
    final updated = group.copyWith(
      id: id,
      updatedAt: DateTime.now().toUtc(),
    );

    await _secureStorage.write(
      key: '$_groupPrefix$id',
      value: jsonEncode(updated.toJson()),
    );

    final index = await _readGroupIndex();
    final newIndex = index.where((e) => e['id'] != id).toList()
      ..add({
        'id': id,
        'name': updated.name,
        'type': updated.type.name,
        'tags': updated.tags.join(','),
      });
    await _writeGroupIndex(newIndex);

    // Sync meta: bump updatedAt, clear any stale group tombstone.
    final meta = await loadSyncMeta();
    final newMeta = VaultSyncMeta(
      updatedAt: {...meta.updatedAt, id: updated.updatedAt},
      tombstones: {...meta.tombstones},
      groupTombstones: {...meta.groupTombstones}..remove(id),
    );
    await saveSyncMeta(newMeta);

    VaultChangeBus.instance.notify();
    return updated;
  }

  /// Delete the group identified by [id]. Idempotent. Any secrets
  /// belonging to this group are NOT deleted, but they are "ungrouped"
  /// (their groupId field is cleared).
  Future<void> deleteGroup(String id) async {
    await _secureStorage.delete(key: '$_groupPrefix$id');

    final index = await _readGroupIndex();
    final newIndex = index.where((e) => e['id'] != id).toList();
    await _writeGroupIndex(newIndex);

    // Ungroup member secrets.
    final members = await loadByGroup(id);
    for (final s in members) {
      await upsert(s.copyWith(groupId: null));
    }

    final meta = await loadSyncMeta();
    final now = DateTime.now().toUtc();
    final newMeta = VaultSyncMeta(
      updatedAt: {...meta.updatedAt}..remove(id),
      tombstones: {...meta.tombstones},
      groupTombstones: {...meta.groupTombstones, id: now},
    );
    await saveSyncMeta(newMeta);

    VaultChangeBus.instance.notify();
  }

  /// Replace the entire vault contents (used by the sync merge path).
  /// Fires [VaultChangeBus] on completion.
  Future<void> applyMergedState({
    required List<VaultSecret> secrets,
    required List<VaultGroup> groups,
    required VaultSyncMeta meta,
  }) async {
    // Clear existing secrets
    final existingSecrets = await _readIndex();
    for (final entry in existingSecrets) {
      await _secureStorage.delete(key: '$_valuePrefix${entry['id']}');
      await _secureStorage.delete(key: '$_metaPrefix${entry['id']}');
    }

    // Clear existing groups
    final existingGroups = await _readGroupIndex();
    for (final entry in existingGroups) {
      await _secureStorage.delete(key: '$_groupPrefix${entry['id']}');
    }

    // Write new groups
    final newGroupIndex = <Map<String, String>>[];
    for (final g in groups) {
      await _secureStorage.write(
        key: '$_groupPrefix${g.id}',
        value: jsonEncode(g.toJson()),
      );
      newGroupIndex.add({
        'id': g.id,
        'name': g.name,
        'type': g.type.name,
        'tags': g.tags.join(','),
      });
    }
    await _writeGroupIndex(newGroupIndex);

    // Write new secrets
    final newIndex = <Map<String, String>>[];
    for (final s in secrets) {
      await _secureStorage.write(key: '$_valuePrefix${s.id}', value: s.value);
      await _secureStorage.write(
        key: '$_metaPrefix${s.id}',
        value: jsonEncode({
          'description': s.description,
          'updatedAt': s.updatedAt.toIso8601String(),
          'groupId': s.groupId,
          'lastUsedAt': s.lastUsedAt?.toIso8601String(),
          'rotateBy': s.rotateBy?.toIso8601String(),
        }),
      );
      newIndex.add({
        'id': s.id,
        'name': s.name,
        'scope': s.scope ?? '',
      });
    }
    await _writeIndex(newIndex);

    await saveSyncMeta(meta);
    VaultChangeBus.instance.notify();
  }

  /// Returns a stable per-install device id, creating one on first
  /// call. Used by [VaultSyncService] so merge logic can tell its own
  /// uploads apart from peer uploads. Stored in the same secure
  /// keystore as the secrets themselves.
  Future<String> getOrCreateDeviceId() async {
    final existing = await _secureStorage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _generateId();
    await _secureStorage.write(key: _deviceIdKey, value: fresh);
    return fresh;
  }

  Future<VaultSyncMeta> loadSyncMeta() async {
    final raw = await _secureStorage.read(key: _syncMetaKey);
    if (raw == null) return VaultSyncMeta.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return VaultSyncMeta.empty;
      return VaultSyncMeta.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return VaultSyncMeta.empty;
    }
  }

  Future<void> saveSyncMeta(VaultSyncMeta meta) async {
    await _secureStorage.write(
      key: _syncMetaKey,
      value: jsonEncode(meta.toJson()),
    );
  }

  Future<List<Map<String, String>>> _readIndex() async {
    final raw = await _secureStorage.read(key: _indexKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((e) =>
              e.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<Map<String, String>> index) async {
    await _secureStorage.write(
      key: _indexKey,
      value: jsonEncode(index),
    );
  }

  Future<List<Map<String, String>>> _readGroupIndex() async {
    final raw = await _secureStorage.read(key: _groupIndexKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((e) =>
              e.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeGroupIndex(List<Map<String, String>> index) async {
    await _secureStorage.write(
      key: _groupIndexKey,
      value: jsonEncode(index),
    );
  }

  static String _canonicaliseName(String input) {
    return input.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '_');
  }

  static String _generateId() {
    final r = Random.secure().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}-$r';
  }
}
