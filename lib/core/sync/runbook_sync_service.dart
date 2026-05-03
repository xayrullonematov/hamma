import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_service.dart';
import '../backup/cloud_sync_adapter.dart';
import '../runbooks/runbook.dart';
import '../runbooks/runbook_change_bus.dart';
import '../runbooks/runbook_storage.dart';
import '../storage/app_lock_storage.dart';
import '../storage/backup_storage.dart';
import 'snippet_sync_storage.dart';

/// Result of merging local + remote runbook state.
@immutable
class RunbookMergeResult {
  const RunbookMergeResult({required this.runbooks, required this.meta});
  final List<Runbook> runbooks;
  final RunbookSyncMeta meta;
}

@immutable
class RunbookSyncBlob {
  const RunbookSyncBlob({
    required this.runbooks,
    required this.meta,
    required this.deviceId,
    required this.generatedAt,
  });

  static const int wireVersion = 1;

  final List<Runbook> runbooks;
  final RunbookSyncMeta meta;
  final String deviceId;
  final DateTime generatedAt;

  Uint8List encode() {
    final json = jsonEncode({
      'version': wireVersion,
      'deviceId': deviceId,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'runbooks': runbooks.map((r) => r.toJson()).toList(),
      'meta': meta.toJson(),
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  static RunbookSyncBlob decode(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Runbook sync blob is not a JSON object.');
    }
    final raw = Map<String, dynamic>.from(decoded);
    final rbsRaw = raw['runbooks'];
    final runbooks = <Runbook>[];
    if (rbsRaw is List) {
      for (final item in rbsRaw.whereType<Map<String, dynamic>>()) {
        try {
          runbooks.add(Runbook.fromJson(item));
        } on RunbookSchemaException {
          // Skip a single bad entry rather than rejecting the whole
          // blob — partial sync beats no sync.
          continue;
        }
      }
    }
    final meta = raw['meta'] is Map
        ? RunbookSyncMeta.fromJson(Map<String, dynamic>.from(raw['meta'] as Map))
        : RunbookSyncMeta.empty;
    return RunbookSyncBlob(
      runbooks: runbooks,
      meta: meta,
      deviceId: (raw['deviceId'] ?? '').toString(),
      generatedAt:
          DateTime.tryParse((raw['generatedAt'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Pure newest-wins merge for runbooks. Mirrors `mergeSnippets` in
/// the snippet sync service — same algorithm, different payload type.
/// Only runbooks with `team:true` from the local side are uploaded;
/// inbound runbooks are accepted regardless so a teammate sharing a
/// "team" runbook lands in the local store.
RunbookMergeResult mergeRunbooks({
  required List<Runbook> localRunbooks,
  required RunbookSyncMeta localMeta,
  required List<Runbook> remoteRunbooks,
  required RunbookSyncMeta remoteMeta,
}) {
  final localById = {for (final r in localRunbooks) r.id: r};
  final remoteById = {for (final r in remoteRunbooks) r.id: r};
  final epoch = DateTime.fromMillisecondsSinceEpoch(0).toUtc();

  final allIds = <String>{
    ...localById.keys,
    ...remoteById.keys,
    ...localMeta.tombstones.keys,
    ...remoteMeta.tombstones.keys,
  };

  final merged = <Runbook>[];
  final mergedUpdatedAt = <String, DateTime>{};
  final mergedTombstones = <String, DateTime>{};

  for (final id in allIds) {
    final localRb = localById[id];
    final remoteRb = remoteById[id];
    final localUpdated = localMeta.updatedAt[id] ?? epoch;
    final remoteUpdated = remoteMeta.updatedAt[id] ?? epoch;
    final localTomb = localMeta.tombstones[id];
    final remoteTomb = remoteMeta.tombstones[id];

    final candidates = <_Candidate>[];
    if (localRb != null) candidates.add(_Candidate.runbook(localRb, localUpdated));
    if (remoteRb != null) candidates.add(_Candidate.runbook(remoteRb, remoteUpdated));
    if (localTomb != null) candidates.add(_Candidate.tomb(localTomb));
    if (remoteTomb != null) candidates.add(_Candidate.tomb(remoteTomb));
    if (candidates.isEmpty) continue;
    candidates.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final winner = candidates.first;

    if (winner.runbook != null) {
      merged.add(winner.runbook!);
      mergedUpdatedAt[id] = winner.timestamp;
    } else {
      mergedTombstones[id] = winner.timestamp;
    }
  }

  return RunbookMergeResult(
    runbooks: merged,
    meta: RunbookSyncMeta(
      updatedAt: mergedUpdatedAt,
      tombstones: mergedTombstones,
    ),
  );
}

class _Candidate {
  _Candidate.runbook(this.runbook, this.timestamp);
  _Candidate.tomb(this.timestamp) : runbook = null;
  final Runbook? runbook;
  final DateTime timestamp;
}

typedef AdapterBuilder = CloudSyncAdapter? Function(BackupConfig config);
typedef PasswordResolver = Future<String?> Function();

/// Sibling of `SnippetSyncService`: encrypts a runbook blob and
/// pushes/pulls it through the user's existing cloud destination.
/// Only `team:true` runbooks ride the wire; everything else stays on
/// the originating device.
class RunbookSyncService {
  RunbookSyncService({
    SnippetSyncStorage? syncStorage,
    RunbookStorage? storage,
    BackupStorage? backupStorage,
    AppLockStorage? appLockStorage,
    AdapterBuilder? adapterBuilder,
    PasswordResolver? passwordResolver,
    Duration debounce = const Duration(seconds: 3),
  })  : _syncStorage = syncStorage ?? const SnippetSyncStorage(),
        _storage = storage ?? const RunbookStorage(),
        _backupStorage = backupStorage ?? const BackupStorage(),
        _appLockStorage = appLockStorage ?? const AppLockStorage(),
        _adapterBuilder = adapterBuilder ?? _defaultAdapterBuilder,
        _passwordResolver = passwordResolver,
        _debounce = debounce;

  final SnippetSyncStorage _syncStorage;
  final RunbookStorage _storage;
  final BackupStorage _backupStorage;
  final AppLockStorage _appLockStorage;
  final AdapterBuilder _adapterBuilder;
  final PasswordResolver? _passwordResolver;
  final Duration _debounce;

  Timer? _debounceTimer;
  StreamSubscription<void>? _busSubscription;
  Future<void>? _inFlight;

  static const String runbooksObjectKey = 'snippets/runbooks.aes';

  void start() {
    _busSubscription ??=
        RunbookChangeBus.instance.changes.listen((_) => _scheduleDebouncedPush());
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
    if (!await _syncStorage.isEnabled()) return;

    final config = await _backupStorage.loadConfig();
    final adapter = _adapterBuilder(config);
    if (adapter == null || !adapter.isConfigured) return;

    final password = await _resolvePassword();
    if (password == null || password.isEmpty) return;

    try {
      final Uint8List? ciphertext = await _safeDownload(adapter);
      final localAll = await _storage.loadAll();
      final localMeta = await _storage.loadMeta();
      final deviceId = await _syncStorage.getOrCreateDeviceId();

      // Only team-tagged runbooks leave this device. The sync meta
      // we ship MUST be filtered to the same id-set so a non-team
      // tombstone can never delete a teammate's team runbook.
      final localTeam = localAll.where((r) => r.team).toList();
      final localTeamIds = localTeam.map((r) => r.id).toSet();
      final teamMeta = RunbookSyncMeta(
        updatedAt: {
          for (final e in localMeta.updatedAt.entries)
            if (localTeamIds.contains(e.key)) e.key: e.value,
        },
        tombstones: {
          for (final e in localMeta.tombstones.entries)
            if (localTeamIds.contains(e.key)) e.key: e.value,
        },
      );

      var toUpload = localTeam;
      var metaToUpload = teamMeta;

      if (ciphertext != null) {
        final plaintext = BackupCrypto.decrypt(password, ciphertext);
        final remote = RunbookSyncBlob.decode(plaintext);
        if (remote.deviceId != deviceId) {
          final merged = mergeRunbooks(
            localRunbooks: localTeam,
            localMeta: teamMeta,
            remoteRunbooks: remote.runbooks,
            remoteMeta: remote.meta,
          );
          // Re-attach any non-team local runbooks. If an id collides
          // (e.g. a teammate accidentally reused an id), the merged
          // team copy wins — we drop the local non-team duplicate
          // rather than letting two entries with the same id land on
          // disk.
          final mergedIds = merged.runbooks.map((r) => r.id).toSet();
          final nonTeam = localAll
              .where((r) => !r.team && !mergedIds.contains(r.id))
              .toList();
          await _storage.applyMergedState(
            runbooks: [...nonTeam, ...merged.runbooks],
            meta: merged.meta,
          );
          toUpload = merged.runbooks;
          metaToUpload = merged.meta;
        }
      }

      final blob = RunbookSyncBlob(
        runbooks: toUpload,
        meta: metaToUpload,
        deviceId: deviceId,
        generatedAt: DateTime.now().toUtc(),
      );
      final outCipher = BackupCrypto.encrypt(password, blob.encode());
      await adapter.put(runbooksObjectKey, outCipher);
    } catch (_) {
      // Swallow — failures are reported via `SnippetSyncService`'s
      // history feed; runbook sync runs as a sidecar.
    }
  }

  Future<Uint8List?> _safeDownload(CloudSyncAdapter adapter) async {
    try {
      return await adapter.get(runbooksObjectKey);
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
