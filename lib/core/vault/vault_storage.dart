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

  static const VaultSyncMeta empty = VaultSyncMeta(
    updatedAt: {},
    tombstones: {},
    groupTombstones: {},
  );

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

  static const _secretsV2Key = 'vault_secrets_v2';
  static const _groupsV2Key = 'vault_groups_v2';
  static const _migratedV2Key = 'vault_schema_v2_migrated';

  final FlutterSecureStorage _secureStorage;

  Future<void> _ensureMigrated() async {
    final migrated = await _secureStorage.read(key: _migratedV2Key);
    if (migrated == 'true') return;

    // Migrate secrets
    final existingSecretsRaw = await _secureStorage.read(key: _secretsV2Key);
    if (existingSecretsRaw == null) {
      final oldIndex = await _readOldIndex();
      final secrets = <VaultSecret>[];
      if (oldIndex.isNotEmpty) {
        for (final entry in oldIndex) {
          final id = entry['id']!;
          final value = await _secureStorage.read(key: '$_valuePrefix$id');
          if (value == null) continue;
          final metaRaw = await _secureStorage.read(key: '$_metaPrefix$id');
          final meta =
              metaRaw == null
                  ? const <String, dynamic>{}
                  : (jsonDecode(metaRaw) as Map).cast<String, dynamic>();
          secrets.add(
            VaultSecret(
              id: id,
              name: entry['name'] ?? '',
              value: value,
              scope: entry['scope'] == '' ? null : entry['scope'],
              description: (meta['description'] ?? '').toString(),
              updatedAt:
                  DateTime.tryParse((meta['updatedAt'] ?? '').toString()) ??
                  DateTime.fromMillisecondsSinceEpoch(0),
              groupId: meta['groupId']?.toString(),
              lastUsedAt: DateTime.tryParse(
                (meta['lastUsedAt'] ?? '').toString(),
              ),
              rotateBy: DateTime.tryParse((meta['rotateBy'] ?? '').toString()),
            ),
          );
        }
      }
      await _writeSecretsV2(secrets);
    }

    // Clean up old secret keys (idempotent)
    final oldIndexForCleanup = await _readOldIndex();
    if (oldIndexForCleanup.isNotEmpty) {
      await Future.wait(
        oldIndexForCleanup.expand(
          (e) => [
            _secureStorage.delete(key: '$_valuePrefix${e['id']}'),
            _secureStorage.delete(key: '$_metaPrefix${e['id']}'),
          ],
        ),
      );
      await _secureStorage.delete(key: _indexKey);
    }

    // Migrate groups
    final existingGroupsRaw = await _secureStorage.read(key: _groupsV2Key);
    if (existingGroupsRaw == null) {
      final oldGroupIndex = await _readOldGroupIndex();
      final groups = <VaultGroup>[];
      if (oldGroupIndex.isNotEmpty) {
        for (final entry in oldGroupIndex) {
          final id = entry['id']!;
          final raw = await _secureStorage.read(key: '$_groupPrefix$id');
          if (raw == null) continue;
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              groups.add(VaultGroup.fromJson(decoded));
            } else if (decoded is Map) {
              groups.add(VaultGroup.fromJson(decoded.cast<String, dynamic>()));
            }
          } catch (_) {}
        }
      }
      await _writeGroupsV2(groups);
    }

    // Clean up old group keys (idempotent)
    final oldGroupIndexForCleanup = await _readOldGroupIndex();
    if (oldGroupIndexForCleanup.isNotEmpty) {
      await Future.wait(
        oldGroupIndexForCleanup.map(
          (e) => _secureStorage.delete(key: '$_groupPrefix${e['id']}'),
        ),
      );
      await _secureStorage.delete(key: _groupIndexKey);
    }

    await _secureStorage.write(key: _migratedV2Key, value: 'true');
  }

  Future<List<VaultSecret>> _readSecretsV2() async {
    final raw = await _secureStorage.read(key: _secretsV2Key);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => VaultSecret.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeSecretsV2(List<VaultSecret> secrets) async {
    await _secureStorage.write(
      key: _secretsV2Key,
      value: jsonEncode(secrets.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<VaultGroup>> _readGroupsV2() async {
    final raw = await _secureStorage.read(key: _groupsV2Key);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => VaultGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeGroupsV2(List<VaultGroup> groups) async {
    await _secureStorage.write(
      key: _groupsV2Key,
      value: jsonEncode(groups.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<Map<String, String>>> _readOldIndex() async {
    final raw = await _secureStorage.read(key: _indexKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (e) => e.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, String>>> _readOldGroupIndex() async {
    final raw = await _secureStorage.read(key: _groupIndexKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (e) => e.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Returns every secret in the store. The plaintext values are
  /// included; callers MUST treat the return value as sensitive.
  Future<List<VaultSecret>> loadAll() async {
    await _ensureMigrated();
    return _readSecretsV2();
  }

  /// Returns secrets belonging to [groupId].
  /// Returns secrets visible to [serverId] (global secrets + secrets scoped to it).
  Future<List<VaultSecret>> loadVisibleTo(String? serverId) async {
    final all = await loadAll();
    return all
        .where((s) => s.isGlobal || (serverId != null && s.scope == serverId))
        .toList();
  }

  /// Returns secrets belonging to [groupId].
  Future<List<VaultSecret>> loadByGroup(String groupId) async {
    final all = await loadAll();
    return all.where((s) => s.groupId == groupId).toList();
  }

  /// Returns the secret identified by [id].
  Future<VaultSecret?> load(String id) async {
    final all = await loadAll();
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Insert or update [secret]. If `id` is empty, a new id is generated.
  /// Generates an uppercase snake-case `name`. Throws [ArgumentError]
  /// if the secret is structurally invalid or if a secret with the same
  /// name already exists in the same scope.
  Future<VaultSecret> upsert(VaultSecret secret) async {
    await _ensureMigrated();

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

    final secrets = await _readSecretsV2();

    // Reject duplicate (scope, name) — unless we're updating in place.
    for (final existing in secrets) {
      if (existing.id == normalised.id) continue;
      if ((existing.scope ?? '') == (normalised.scope ?? '') &&
          existing.name == normalised.name) {
        throw ArgumentError(
          'A secret named ${normalised.name} already exists in this scope.',
        );
      }
    }

    final id = normalised.id.isEmpty ? _generateId() : normalised.id;
    final updated = normalised.copyWith(id: id);

    final newSecrets = secrets.where((e) => e.id != id).toList()..add(updated);
    await _writeSecretsV2(newSecrets);

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
    await _ensureMigrated();

    final secrets = await _readSecretsV2();
    final newSecrets = secrets.where((e) => e.id != id).toList();
    await _writeSecretsV2(newSecrets);

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
    await _ensureMigrated();
    return _readGroupsV2();
  }

  /// Insert or update [group].
  Future<VaultGroup> upsertGroup(VaultGroup group) async {
    await _ensureMigrated();

    final id = group.id.isEmpty ? _generateId() : group.id;
    final updated = group.copyWith(id: id, updatedAt: DateTime.now().toUtc());

    final groups = await _readGroupsV2();
    final newGroups = groups.where((e) => e.id != id).toList()..add(updated);
    await _writeGroupsV2(newGroups);

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
    await _ensureMigrated();

    final groups = await _readGroupsV2();
    final newGroups = groups.where((e) => e.id != id).toList();
    await _writeGroupsV2(newGroups);

    // Ungroup member secrets.
    final secrets = await _readSecretsV2();
    bool changedSecrets = false;
    final newSecrets =
        secrets.map((s) {
          if (s.groupId == id) {
            changedSecrets = true;
            return s.copyWith(groupId: null);
          }
          return s;
        }).toList();

    if (changedSecrets) {
      await _writeSecretsV2(newSecrets);
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
    await _ensureMigrated();

    // With the V2 schema, replacing the entire vault contents simply
    // means overwriting the single blob for secrets and the single blob
    // for groups. We completely avoid the N+1 secure storage deletion
    // operations.
    await _writeSecretsV2(secrets);
    await _writeGroupsV2(groups);
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

  static String _canonicaliseName(String input) {
    return input.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '_');
  }

  static String _generateId() {
    final r = Random.secure().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}-$r';
  }
}
