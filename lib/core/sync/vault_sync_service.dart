import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_service.dart';
import '../backup/cloud_sync_adapter.dart';
import '../storage/app_lock_storage.dart';
import '../storage/backup_storage.dart';
import '../vault/vault_change_bus.dart';
import '../vault/vault_group.dart';
import '../vault/vault_secret.dart';
import '../vault/vault_storage.dart';

/// Wire-format for the vault blob uploaded under `vault/secrets.aes`.
/// Encrypted by [BackupCrypto] (HMBK v2 — Argon2id + AES-GCM) before
/// transmission, so the cloud provider only ever sees ciphertext.
@immutable
class VaultSyncBlob {
  const VaultSyncBlob({
    required this.secrets,
    required this.groups,
    required this.meta,
    required this.deviceId,
    required this.generatedAt,
  });

  static const int wireVersion = 1;

  final List<VaultSecret> secrets;
  final List<VaultGroup> groups;
  final VaultSyncMeta meta;
  final String deviceId;
  final DateTime generatedAt;

  Uint8List encode() {
    final json = jsonEncode({
      'version': wireVersion,
      'deviceId': deviceId,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'secrets': secrets.map((s) => s.toJson()).toList(),
      'groups': groups.map((g) => g.toJson()).toList(),
      'meta': meta.toJson(),
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  static VaultSyncBlob decode(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Vault sync blob is not a JSON object.');
    }
    final raw = Map<String, dynamic>.from(decoded);
    final secretsRaw = raw['secrets'];
    final secrets = <VaultSecret>[];
    if (secretsRaw is List) {
      for (final item in secretsRaw.whereType<Map<String, dynamic>>()) {
        secrets.add(VaultSecret.fromJson(item));
      }
    }
    final groupsRaw = raw['groups'];
    final groups = <VaultGroup>[];
    if (groupsRaw is List) {
      for (final item in groupsRaw.whereType<Map<String, dynamic>>()) {
        groups.add(VaultGroup.fromJson(item));
      }
    }
    final meta = raw['meta'] is Map
        ? VaultSyncMeta.fromJson(
            Map<String, dynamic>.from(raw['meta'] as Map),
          )
        : VaultSyncMeta.empty;
    return VaultSyncBlob(
      secrets: secrets,
      groups: groups,
      meta: meta,
      deviceId: (raw['deviceId'] ?? '').toString(),
      generatedAt:
          DateTime.tryParse((raw['generatedAt'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Newest-wins merge across local + remote vault state, with tombstone
/// awareness so a freshly-synced peer can't resurrect a deleted secret.
@immutable
class VaultMergeResult {
  const VaultMergeResult({
    required this.secrets,
    required this.groups,
    required this.meta,
  });
  final List<VaultSecret> secrets;
  final List<VaultGroup> groups;
  final VaultSyncMeta meta;
}

VaultMergeResult mergeVaults({
  required List<VaultSecret> localSecrets,
  required List<VaultGroup> localGroups,
  required VaultSyncMeta localMeta,
  required List<VaultSecret> remoteSecrets,
  required List<VaultGroup> remoteGroups,
  required VaultSyncMeta remoteMeta,
}) {
  final localSecretsById = {for (final s in localSecrets) s.id: s};
  final remoteSecretsById = {for (final s in remoteSecrets) s.id: s};
  final localGroupsById = {for (final g in localGroups) g.id: g};
  final remoteGroupsById = {for (final g in remoteGroups) g.id: g};
  final epoch = DateTime.fromMillisecondsSinceEpoch(0).toUtc();

  final allSecretIds = <String>{
    ...localSecretsById.keys,
    ...remoteSecretsById.keys,
    ...localMeta.tombstones.keys,
    ...remoteMeta.tombstones.keys,
  };

  final allGroupIds = <String>{
    ...localGroupsById.keys,
    ...remoteGroupsById.keys,
    ...localMeta.groupTombstones.keys,
    ...remoteMeta.groupTombstones.keys,
  };

  final mergedSecrets = <VaultSecret>[];
  final mergedGroups = <VaultGroup>[];
  final mergedUpdatedAt = <String, DateTime>{};
  final mergedTombstones = <String, DateTime>{};
  final mergedGroupTombstones = <String, DateTime>{};

  for (final id in allSecretIds) {
    final localSecret = localSecretsById[id];
    final remoteSecret = remoteSecretsById[id];
    final localUpdated = localMeta.updatedAt[id] ?? epoch;
    final remoteUpdated = remoteMeta.updatedAt[id] ?? epoch;
    final localTomb = localMeta.tombstones[id];
    final remoteTomb = remoteMeta.tombstones[id];

    final candidates = <_Candidate<VaultSecret>>[];
    if (localSecret != null) {
      candidates.add(_Candidate.value(localSecret, localUpdated));
    }
    if (remoteSecret != null) {
      candidates.add(_Candidate.value(remoteSecret, remoteUpdated));
    }
    if (localTomb != null) candidates.add(_Candidate.tomb(localTomb));
    if (remoteTomb != null) candidates.add(_Candidate.tomb(remoteTomb));

    if (candidates.isEmpty) continue;
    candidates.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final winner = candidates.first;

    if (winner.value != null) {
      mergedSecrets.add(winner.value!);
      mergedUpdatedAt[id] = winner.timestamp;
    } else {
      mergedTombstones[id] = winner.timestamp;
    }
  }

  for (final id in allGroupIds) {
    final localGroup = localGroupsById[id];
    final remoteGroup = remoteGroupsById[id];
    final localUpdated = localMeta.updatedAt[id] ?? epoch;
    final remoteUpdated = remoteMeta.updatedAt[id] ?? epoch;
    final localTomb = localMeta.groupTombstones[id];
    final remoteTomb = remoteMeta.groupTombstones[id];

    final candidates = <_Candidate<VaultGroup>>[];
    if (localGroup != null) {
      candidates.add(_Candidate.value(localGroup, localUpdated));
    }
    if (remoteGroup != null) {
      candidates.add(_Candidate.value(remoteGroup, remoteUpdated));
    }
    if (localTomb != null) candidates.add(_Candidate.tomb(localTomb));
    if (remoteTomb != null) candidates.add(_Candidate.tomb(remoteTomb));

    if (candidates.isEmpty) continue;
    candidates.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final winner = candidates.first;

    if (winner.value != null) {
      mergedGroups.add(winner.value!);
      mergedUpdatedAt[id] = winner.timestamp;
    } else {
      mergedGroupTombstones[id] = winner.timestamp;
    }
  }

  return VaultMergeResult(
    secrets: mergedSecrets,
    groups: mergedGroups,
    meta: VaultSyncMeta(
      updatedAt: mergedUpdatedAt,
      tombstones: mergedTombstones,
      groupTombstones: mergedGroupTombstones,
    ),
  );
}

class _Candidate<T> {
  _Candidate.value(this.value, this.timestamp);
  _Candidate.tomb(this.timestamp) : value = null;
  final T? value;
  final DateTime timestamp;
}

typedef VaultAdapterBuilder = CloudSyncAdapter? Function(BackupConfig config);
typedef VaultPasswordResolver = Future<String?> Function();

/// Cross-device vault sync, mirroring [SnippetSyncService]:
///   - Subscribes to [VaultChangeBus]; each event resets a 3-second
///     debounce timer that pushes the encrypted blob.
///   - [pullAndMerge] downloads the latest blob, merges, persists, and
///     re-uploads so peers converge.
///
/// The blob is encrypted with [BackupCrypto] (HMBK v2) using the
/// master PIN — same key the cloud-sync feature already requires —
/// so the provider only ever sees ciphertext.
class VaultSyncService {
  VaultSyncService({
    VaultStorage? vaultStorage,
    BackupStorage? backupStorage,
    AppLockStorage? appLockStorage,
    VaultAdapterBuilder? adapterBuilder,
    VaultPasswordResolver? passwordResolver,
    String? deviceId,
    Duration debounce = const Duration(seconds: 3),
  })  : _vaultStorage = vaultStorage ?? VaultStorage(),
        _backupStorage = backupStorage ?? const BackupStorage(),
        _appLockStorage = appLockStorage ?? AppLockStorage(),
        _adapterBuilder = adapterBuilder ?? _defaultAdapterBuilder,
        _passwordResolver = passwordResolver,
        _explicitDeviceId = deviceId,
        _debounce = debounce;

  final VaultStorage _vaultStorage;
  final BackupStorage _backupStorage;
  final AppLockStorage _appLockStorage;
  final VaultAdapterBuilder _adapterBuilder;
  final VaultPasswordResolver? _passwordResolver;
  final String? _explicitDeviceId;
  final Duration _debounce;

  Timer? _debounceTimer;
  StreamSubscription<void>? _busSubscription;
  Future<void>? _inFlight;
  String? _resolvedDeviceId;

  /// Set during a sync-driven `applyMergedState` so the change-bus
  /// listener (which normally schedules a debounced push on every
  /// vault mutation) ignores the notification we just fired ourselves
  /// — otherwise every successful pull would loop into a redundant
  /// push.
  bool _suppressNextBusEvent = false;

  Future<String> _deviceId() async {
    final explicit = _explicitDeviceId;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return _resolvedDeviceId ??=
        await _vaultStorage.getOrCreateDeviceId();
  }

  /// Cloud key the encrypted vault blob is written under. Sits next to
  /// (not inside) `snippets/snippets.aes` and the full backup keyspace
  /// so a vault sync can never collide with a snippet sync or a full
  /// backup snapshot.
  static const String vaultObjectKey = 'vault/secrets.aes';

  void start() {
    _busSubscription ??= VaultChangeBus.instance.changes.listen((_) {
      if (_suppressNextBusEvent) {
        _suppressNextBusEvent = false;
        return;
      }
      _scheduleDebouncedPush();
    });
  }

  Future<void> dispose() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _busSubscription?.cancel();
    _busSubscription = null;
    if (_inFlight != null) {
      try {
        await _inFlight;
      } catch (_) {}
    }
  }

  void _scheduleDebouncedPush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      _inFlight = pushNow().catchError((_) {});
    });
  }

  Future<void> pushNow() => _syncRoundTrip();
  Future<void> pullAndMerge() => _syncRoundTrip();

  Future<void> _syncRoundTrip() async {
    _debounceTimer?.cancel();
    final config = await _backupStorage.loadConfig();
    final adapter = _adapterBuilder(config);
    if (adapter == null || !adapter.isConfigured) return;

    final password = await _resolvePassword();
    if (password == null || password.isEmpty) return;

    final deviceId = await _deviceId();
    final localSecrets = await _vaultStorage.loadAll();
    final localGroups = await _vaultStorage.loadAllGroups();
    final localMeta = await _vaultStorage.loadSyncMeta();

    var secretsToUpload = localSecrets;
    var groupsToUpload = localGroups;
    var metaToUpload = localMeta;

    try {
      final ciphertext = await _safeDownload(adapter);
      if (ciphertext != null) {
        final plaintext = BackupCrypto.decrypt(password, ciphertext);
        final remote = VaultSyncBlob.decode(plaintext);
        if (remote.deviceId != deviceId) {
          final merged = mergeVaults(
            localSecrets: localSecrets,
            localGroups: localGroups,
            localMeta: localMeta,
            remoteSecrets: remote.secrets,
            remoteGroups: remote.groups,
            remoteMeta: remote.meta,
          );
          // Suppress the bus event we're about to trigger so the
          // change listener doesn't schedule a redundant push that
          // would just upload what we already have.
          _suppressNextBusEvent = true;
          await _vaultStorage.applyMergedState(
            secrets: merged.secrets,
            groups: merged.groups,
            meta: merged.meta,
          );
          secretsToUpload = merged.secrets;
          groupsToUpload = merged.groups;
          metaToUpload = merged.meta;
        }
      }

      final blob = VaultSyncBlob(
        secrets: secretsToUpload,
        groups: groupsToUpload,
        meta: metaToUpload,
        deviceId: deviceId,
        generatedAt: DateTime.now().toUtc(),
      );
      final outCipher = BackupCrypto.encrypt(password, blob.encode());
      await adapter.put(vaultObjectKey, outCipher);
    } catch (_) {
      // Swallow — sync failures must never crash the app. The next
      // bus tick will retry.
    }
  }

  Future<Uint8List?> _safeDownload(CloudSyncAdapter adapter) async {
    try {
      return await adapter.get(vaultObjectKey);
    } on CloudNotFoundException {
      return null;
    }
  }

  Future<String?> _resolvePassword() async {
    if (_passwordResolver != null) return _passwordResolver();
    return _appLockStorage.readPin();
  }
}

CloudSyncAdapter? _defaultAdapterBuilder(BackupConfig config) {
  if (!config.isCloudDestination) return null;
  try {
    return BackupService.buildCloudAdapter(config);
  } catch (_) {
    return null;
  }
}
