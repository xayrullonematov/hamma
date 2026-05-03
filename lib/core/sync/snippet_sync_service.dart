import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_service.dart';
import '../backup/cloud_sync_adapter.dart';
import '../storage/app_lock_storage.dart';
import '../storage/backup_storage.dart';
import '../storage/custom_actions_storage.dart';
import '../../features/quick_actions/quick_actions.dart';
import 'snippet_change_bus.dart';
import 'snippet_sync_storage.dart';

/// Result of merging local + remote snippet state.
@immutable
class SnippetMergeResult {
  const SnippetMergeResult({
    required this.snippets,
    required this.meta,
  });

  final List<QuickAction> snippets;
  final SnippetSyncMeta meta;
}

/// Wire-format for the snippets-only blob uploaded to the cloud
/// destination. Encrypted by [BackupCrypto] before transmission so the
/// provider only ever sees ciphertext.
@immutable
class SnippetSyncBlob {
  const SnippetSyncBlob({
    required this.snippets,
    required this.meta,
    required this.deviceId,
    required this.generatedAt,
  });

  static const int wireVersion = 1;

  final List<QuickAction> snippets;
  final SnippetSyncMeta meta;
  final String deviceId;
  final DateTime generatedAt;

  Uint8List encode() {
    final json = jsonEncode({
      'version': wireVersion,
      'deviceId': deviceId,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'snippets': snippets.map((a) => a.toJson()).toList(),
      'meta': meta.toJson(),
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  static SnippetSyncBlob decode(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Snippet sync blob is not a JSON object.');
    }
    final raw = Map<String, dynamic>.from(decoded);
    final snippetsRaw = raw['snippets'];
    final snippets = <QuickAction>[];
    if (snippetsRaw is List) {
      for (final item in snippetsRaw.whereType<Map<String, dynamic>>()) {
        snippets.add(QuickAction.fromJson(item));
      }
    }
    final meta = raw['meta'] is Map
        ? SnippetSyncMeta.fromJson(
            Map<String, dynamic>.from(raw['meta'] as Map),
          )
        : SnippetSyncMeta.empty;
    return SnippetSyncBlob(
      snippets: snippets,
      meta: meta,
      deviceId: (raw['deviceId'] ?? '').toString(),
      generatedAt:
          DateTime.tryParse((raw['generatedAt'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Pure newest-wins merge over snippet ids + tombstones. Public for
/// direct unit testing — the rest of the service only orchestrates I/O.
SnippetMergeResult mergeSnippets({
  required List<QuickAction> localSnippets,
  required SnippetSyncMeta localMeta,
  required List<QuickAction> remoteSnippets,
  required SnippetSyncMeta remoteMeta,
}) {
  final localById = {for (final a in localSnippets) a.id: a};
  final remoteById = {for (final a in remoteSnippets) a.id: a};
  final epoch = DateTime.fromMillisecondsSinceEpoch(0).toUtc();

  final allIds = <String>{
    ...localById.keys,
    ...remoteById.keys,
    ...localMeta.tombstones.keys,
    ...remoteMeta.tombstones.keys,
  };

  final mergedSnippets = <QuickAction>[];
  final mergedUpdatedAt = <String, DateTime>{};
  final mergedTombstones = <String, DateTime>{};

  for (final id in allIds) {
    final localSnippet = localById[id];
    final remoteSnippet = remoteById[id];
    final localUpdated = localMeta.updatedAt[id] ?? epoch;
    final remoteUpdated = remoteMeta.updatedAt[id] ?? epoch;
    final localTomb = localMeta.tombstones[id];
    final remoteTomb = remoteMeta.tombstones[id];

    // Pick the latest event across all four candidates.
    final candidates = <_Candidate>[];
    if (localSnippet != null) {
      candidates.add(_Candidate.snippet(localSnippet, localUpdated));
    }
    if (remoteSnippet != null) {
      candidates.add(_Candidate.snippet(remoteSnippet, remoteUpdated));
    }
    if (localTomb != null) candidates.add(_Candidate.tomb(localTomb));
    if (remoteTomb != null) candidates.add(_Candidate.tomb(remoteTomb));

    if (candidates.isEmpty) continue;
    candidates.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final winner = candidates.first;

    if (winner.snippet != null) {
      mergedSnippets.add(winner.snippet!);
      mergedUpdatedAt[id] = winner.timestamp;
    } else {
      mergedTombstones[id] = winner.timestamp;
    }
  }

  return SnippetMergeResult(
    snippets: mergedSnippets,
    meta: SnippetSyncMeta(
      updatedAt: mergedUpdatedAt,
      tombstones: mergedTombstones,
    ),
  );
}

class _Candidate {
  _Candidate.snippet(this.snippet, this.timestamp);
  _Candidate.tomb(this.timestamp) : snippet = null;
  final QuickAction? snippet;
  final DateTime timestamp;
}

/// Builds the cloud adapter for the configured backup destination, or
/// returns `null` if the user hasn't configured a cloud destination.
typedef AdapterBuilder = CloudSyncAdapter? Function(BackupConfig config);

/// Resolves the master password used to encrypt the snippets blob.
typedef PasswordResolver = Future<String?> Function();

/// Orchestrates encrypted, debounced cross-device snippet sync.
///
/// Push (local → cloud):
///   * Subscribes to [SnippetChangeBus]; on each event resets a 3s
///     debounce timer that uploads the current snippets+meta blob.
///   * The blob is encrypted with [BackupCrypto] using the master PIN
///     (same key the cloud-sync feature already requires) so the
///     provider only ever sees ciphertext.
///
/// Pull (cloud → local):
///   * [pullAndMerge] downloads the latest snippets blob, runs the
///     newest-wins merge against local state, and writes the result
///     back via [CustomActionsStorage.applyMergedState] (which does
///     not refire the change bus, so we can't loop).
///
/// The service is a no-op when:
///   * snippet sync is disabled in [SnippetSyncStorage], or
///   * no cloud destination is configured.
class SnippetSyncService {
  SnippetSyncService({
    SnippetSyncStorage? syncStorage,
    CustomActionsStorage? actionsStorage,
    BackupStorage? backupStorage,
    AppLockStorage? appLockStorage,
    AdapterBuilder? adapterBuilder,
    PasswordResolver? passwordResolver,
    Duration debounce = const Duration(seconds: 3),
  })  : _syncStorage = syncStorage ?? const SnippetSyncStorage(),
        _actionsStorage = actionsStorage ?? const CustomActionsStorage(),
        _backupStorage = backupStorage ?? const BackupStorage(),
        _appLockStorage = appLockStorage ?? const AppLockStorage(),
        _adapterBuilder = adapterBuilder ?? _defaultAdapterBuilder,
        _passwordResolver = passwordResolver,
        _debounce = debounce;

  final SnippetSyncStorage _syncStorage;
  final CustomActionsStorage _actionsStorage;
  final BackupStorage _backupStorage;
  final AppLockStorage _appLockStorage;
  final AdapterBuilder _adapterBuilder;
  final PasswordResolver? _passwordResolver;
  final Duration _debounce;

  Timer? _debounceTimer;
  StreamSubscription<void>? _busSubscription;
  Future<void>? _inFlight;

  /// Cloud key the snippets-only blob is uploaded under. Lives next
  /// to (not inside) the backup-snapshot keyspace so a snippet sync
  /// can never collide with or shadow a full encrypted backup.
  static const String snippetsObjectKey = 'snippets/snippets.aes';

  /// Begin listening for local snippet edits; pushes are debounced by
  /// [_debounce]. Idempotent — calling twice has no extra effect.
  void start() {
    _busSubscription ??=
        SnippetChangeBus.instance.changes.listen((_) => _scheduleDebouncedPush());
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

  /// Force an immediate push (cancels any pending debounce). Returns
  /// without throwing if sync is disabled / unconfigured / blocked.
  Future<void> pushNow() async {
    _debounceTimer?.cancel();
    if (!await _syncStorage.isEnabled()) return;

    final config = await _backupStorage.loadConfig();
    final adapter = _adapterBuilder(config);
    if (adapter == null || !adapter.isConfigured) return;

    final password = await _resolvePassword();
    if (password == null || password.isEmpty) {
      await _appendHistory('push', false, 'Master password unavailable.');
      return;
    }

    try {
      final snippets = await _actionsStorage.loadActions();
      final meta = await _actionsStorage.loadMeta();
      final deviceId = await _syncStorage.getOrCreateDeviceId();
      final blob = SnippetSyncBlob(
        snippets: snippets,
        meta: meta,
        deviceId: deviceId,
        generatedAt: DateTime.now().toUtc(),
      );
      final ciphertext = BackupCrypto.encrypt(password, blob.encode());
      await adapter.put(snippetsObjectKey, ciphertext);
      await _syncStorage.setLastSyncAt(DateTime.now().toUtc());
      await _appendHistory(
        'push',
        true,
        '${snippets.length} snippet(s) uploaded.',
      );
    } catch (e) {
      await _appendHistory('push', false, e.toString());
    }
  }

  /// Pull the latest snippets blob (if any), merge it against local
  /// state, and persist the merged result. A no-op when sync is
  /// disabled or the cloud destination is unconfigured.
  Future<void> pullAndMerge() async {
    if (!await _syncStorage.isEnabled()) return;

    final config = await _backupStorage.loadConfig();
    final adapter = _adapterBuilder(config);
    if (adapter == null || !adapter.isConfigured) return;

    final password = await _resolvePassword();
    if (password == null || password.isEmpty) {
      await _appendHistory('pull', false, 'Master password unavailable.');
      return;
    }

    try {
      final ciphertext = await _safeDownload(adapter);
      if (ciphertext == null) {
        // No remote blob yet — push our state so peers can pull it.
        await _appendHistory('pull', true, 'No remote snippets yet.');
        await pushNow();
        return;
      }
      final plaintext = BackupCrypto.decrypt(password, ciphertext);
      final remote = SnippetSyncBlob.decode(plaintext);
      final localSnippets = await _actionsStorage.loadActions();
      final localMeta = await _actionsStorage.loadMeta();

      final deviceId = await _syncStorage.getOrCreateDeviceId();
      if (remote.deviceId == deviceId) {
        // Our own last upload — nothing to merge.
        await _syncStorage.setLastSyncAt(DateTime.now().toUtc());
        await _appendHistory('pull', true, 'Already up to date.');
        return;
      }

      final merged = mergeSnippets(
        localSnippets: localSnippets,
        localMeta: localMeta,
        remoteSnippets: remote.snippets,
        remoteMeta: remote.meta,
      );

      await _actionsStorage.applyMergedState(
        snippets: merged.snippets,
        meta: merged.meta,
      );
      await _syncStorage.setLastSyncAt(DateTime.now().toUtc());
      await _appendHistory(
        'pull',
        true,
        '${merged.snippets.length} snippet(s) after merge.',
      );

      // Re-upload the merged state so peers converge without an extra
      // round-trip. Triggered immediately (the bus would also fire,
      // but applyMergedState deliberately does not refire it).
      await pushNow();
    } catch (e) {
      await _appendHistory('pull', false, e.toString());
    }
  }

  Future<Uint8List?> _safeDownload(CloudSyncAdapter adapter) async {
    try {
      return await adapter.get(snippetsObjectKey);
    } on CloudNotFoundException {
      // Benign first-run state — no remote blob exists yet. Caller
      // will treat this as "okay to push local state."
      return null;
    }
    // All other exceptions (auth failures, network errors, 5xx,
    // crypto errors) propagate up so pullAndMerge aborts WITHOUT
    // pushing — preventing a transient outage from clobbering a
    // newer remote snapshot.
  }

  Future<String?> _resolvePassword() async {
    if (_passwordResolver != null) return _passwordResolver();
    return _appLockStorage.readPin();
  }

  Future<void> _appendHistory(
    String op,
    bool success,
    String? message,
  ) async {
    await _syncStorage.appendHistory(
      SnippetSyncHistoryEntry(
        timestamp: DateTime.now().toUtc(),
        operation: op,
        success: success,
        message: message,
      ),
    );
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
