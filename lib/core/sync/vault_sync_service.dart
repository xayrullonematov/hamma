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
import '../vault/vault_secret.dart';
import '../vault/vault_storage.dart';

/// Wire-format for the vault blob uploaded under `vault/secrets.aes`.
/// Encrypted by [BackupCrypto] (HMBK v2 — Argon2id + AES-GCM) before
/// transmission, so the cloud provider only ever sees ciphertext.
@immutable
class VaultSyncBlob {
  const VaultSyncBlob({
    required this.secrets,
    required this.meta,
    required this.deviceId,
    required this.generatedAt,
  });

  static const int wireVersion = 1;

  final List<VaultSecret> secrets;
  final VaultSyncMeta meta;
  final String deviceId;
  final DateTime generatedAt;

  Uint8List encode() {
    final json = jsonEncode({
      'version': wireVersion,
      'deviceId': deviceId,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'secrets': secrets.map((s) => s.toJson()).toList(),
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
    final meta = raw['meta'] is Map
        ? VaultSyncMeta.fromJson(
            Map<String, dynamic>.from(raw['meta'] as Map),
          )
        : VaultSyncMeta.empty;
    return VaultSyncBlob(
      secrets: secrets,
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
  const VaultMergeResult({required this.secrets, required this.meta});
  final List<VaultSecret> secrets;
  final VaultSyncMeta meta;
}

VaultMergeResult mergeVaults({
  required List<VaultSecret> localSecrets,
  required VaultSyncMeta localMeta,
  required List<VaultSecret> remoteSecrets,
  required VaultSyncMeta remoteMeta,
}) {
  final localById = {for (final s in localSecrets) s.id: s};
  final remoteById = {for (final s in remoteSecrets) s.id: s};
  final epoch = DateTime.fromMillisecondsSinceEpoch(0).toUtc();

  final allIds = <String>{
    ...localById.keys,
    ...remoteById.keys,
    ...localMeta.tombstones.keys,
    ...remoteMeta.tombstones.keys,
  };

  final mergedSecrets = <VaultSecret>[];
  final mergedUpdatedAt = <String, DateTime>{};
  final mergedTombstones = <String, DateTime>{};

  for (final id in allIds) {
    final localSecret = localById[id];
    final remoteSecret = remoteById[id];
    final localUpdated = localMeta.updatedAt[id] ?? epoch;
    final remoteUpdated = remoteMeta.updatedAt[id] ?? epoch;
    final localTomb = localMeta.tombstones[id];
    final remoteTomb = remoteMeta.tombstones[id];

    final candidates = <_Candidate>[];
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

    if (winner.secret != null) {
      mergedSecrets.add(winner.secret!);
      mergedUpdatedAt[id] = winner.timestamp;
    } else {
      mergedTombstones[id] = winner.timestamp;
    }
  }

  return VaultMergeResult(
    secrets: mergedSecrets,
    meta: VaultSyncMeta(
      updatedAt: mergedUpdatedAt,
      tombstones: mergedTombstones,
    ),
  );
}

class _Candidate {
  _Candidate.value(this.secret, this.timestamp);
  _Candidate.tomb(this.timestamp) : secret = null;
  final VaultSecret? secret;
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
    String deviceId = 'device-default',
    Duration debounce = const Duration(seconds: 3),
  })  : _vaultStorage = vaultStorage ?? VaultStorage(),
        _backupStorage = backupStorage ?? const BackupStorage(),
        _appLockStorage = appLockStorage ?? AppLockStorage(),
        _adapterBuilder = adapterBuilder ?? _defaultAdapterBuilder,
        _passwordResolver = passwordResolver,
        _deviceId = deviceId,
        _debounce = debounce;

  final VaultStorage _vaultStorage;
  final BackupStorage _backupStorage;
  final AppLockStorage _appLockStorage;
  final VaultAdapterBuilder _adapterBuilder;
  final VaultPasswordResolver? _passwordResolver;
  final String _deviceId;
  final Duration _debounce;

  Timer? _debounceTimer;
  StreamSubscription<void>? _busSubscription;
  Future<void>? _inFlight;

  /// Cloud key the encrypted vault blob is written under. Sits next to
  /// (not inside) `snippets/snippets.aes` and the full backup keyspace
  /// so a vault sync can never collide with a snippet sync or a full
  /// backup snapshot.
  static const String vaultObjectKey = 'vault/secrets.aes';

  void start() {
    _busSubscription ??=
        VaultChangeBus.instance.changes.listen((_) => _scheduleDebouncedPush());
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

    final localSecrets = await _vaultStorage.loadAll();
    final localMeta = await _vaultStorage.loadSyncMeta();

    var secretsToUpload = localSecrets;
    var metaToUpload = localMeta;

    try {
      final ciphertext = await _safeDownload(adapter);
      if (ciphertext != null) {
        final plaintext = BackupCrypto.decrypt(password, ciphertext);
        final remote = VaultSyncBlob.decode(plaintext);
        if (remote.deviceId != _deviceId) {
          final merged = mergeVaults(
            localSecrets: localSecrets,
            localMeta: localMeta,
            remoteSecrets: remote.secrets,
            remoteMeta: remote.meta,
          );
          await _vaultStorage.applyMergedState(
            secrets: merged.secrets,
            meta: merged.meta,
          );
          secretsToUpload = merged.secrets;
          metaToUpload = merged.meta;
        }
      }

      final blob = VaultSyncBlob(
        secrets: secretsToUpload,
        meta: metaToUpload,
        deviceId: _deviceId,
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
