// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

import 'runbook.dart';
import 'runbook_change_bus.dart';

/// Per-id metadata used by [RunbookSyncService]'s newest-wins merge.
/// Same shape as `SnippetSyncMeta` — kept in a separate type so the
/// snippet and runbook sync paths can evolve independently.
@immutable
class RunbookSyncMeta {
  const RunbookSyncMeta({required this.updatedAt, required this.tombstones});

  final Map<String, DateTime> updatedAt;
  final Map<String, DateTime> tombstones;

  static const RunbookSyncMeta empty =
      RunbookSyncMeta(updatedAt: {}, tombstones: {});

  Map<String, dynamic> toJson() => {
        'updatedAt': {
          for (final e in updatedAt.entries) e.key: e.value.toIso8601String(),
        },
        'tombstones': {
          for (final e in tombstones.entries) e.key: e.value.toIso8601String(),
        },
      };

  factory RunbookSyncMeta.fromJson(Map<String, dynamic> json) {
    Map<String, DateTime> parseMap(Object? raw) {
      if (raw is! Map) return <String, DateTime>{};
      final out = <String, DateTime>{};
      for (final entry in raw.entries) {
        final ts = DateTime.tryParse(entry.value?.toString() ?? '');
        if (ts != null) out[entry.key.toString()] = ts;
      }
      return out;
    }

    return RunbookSyncMeta(
      updatedAt: parseMap(json['updatedAt']),
      tombstones: parseMap(json['tombstones']),
    );
  }
}

/// Encrypted secure-storage backed runbook persistence.
///
/// Layout:
/// * `runbooks_v1` — JSON array of every runbook (global + per-server).
/// * `runbooks_v1_meta` — per-id `updatedAt` + tombstones map for
///   newest-wins sync merges.
///
/// Per-server scoping is achieved by a runbook's `serverId` field
/// rather than a separate keyspace; the storage exposes filtered
/// loaders (`loadForServer`) for the UI.
class RunbookStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const RunbookStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _runbooksKey = 'runbooks_v1';
  static const _metaKey = 'runbooks_v1_meta';

  final FlutterSecureStorage _secureStorage;

  /// Returns every persisted runbook, in insertion order. Throws
  /// [RunbookStorageException] when the on-disk JSON is malformed
  /// — caller is expected to surface this rather than silently
  /// drop user data.
  Future<List<Runbook>> loadAll() async {
    final snapshot = await _readSnapshot();
    return List<Runbook>.from(snapshot.parsed);
  }

  /// Internal: returns BOTH the parsed runbooks AND any raw JSON
  /// entries we could not decode. Pass-through preservation lets
  /// [saveAll] re-emit opaque entries instead of permanently
  /// dropping them (data-loss bug).
  Future<_StorageSnapshot> _readSnapshot() async {
    final raw = await _secureStorage.read(key: _runbooksKey);
    if (raw == null || raw.trim().isEmpty) {
      return const _StorageSnapshot(parsed: [], opaque: []);
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const RunbookStorageException(
        'Saved runbook data is not a JSON array.',
      );
    }
    final parsed = <Runbook>[];
    final opaque = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map) {
        opaque.add({'__opaque__': item.toString()});
        continue;
      }
      final asMap = Map<String, dynamic>.from(item);
      try {
        parsed.add(Runbook.fromJson(asMap));
      } on RunbookSchemaException {
        // Pass-through: keep the original blob so we don't destroy
        // data the user could recover later.
        opaque.add(asMap);
      }
    }
    return _StorageSnapshot(parsed: parsed, opaque: opaque);
  }

  /// Returns runbooks visible to the given server id — that is, every
  /// runbook with `serverId == serverId` plus all global runbooks
  /// (`serverId == null`).
  Future<List<Runbook>> loadForServer(String serverId) async {
    final all = await loadAll();
    return all
        .where((r) => r.serverId == null || r.serverId == serverId)
        .toList();
  }

  /// Replaces the entire runbook list. Updates per-id metadata
  /// (updatedAt for new/changed entries, tombstones for missing
  /// ones) and notifies [RunbookChangeBus] so subscribers (UI +
  /// sync service) react. Any opaque (un-decodable) entries that
  /// were already on disk are preserved so we never permanently
  /// drop user data we couldn't parse.
  Future<void> saveAll(List<Runbook> runbooks) async {
    final snapshot = await _readSnapshot();
    final encoded = jsonEncode([
      ...runbooks.map((r) => r.toJson()),
      ...snapshot.opaque,
    ]);
    await _secureStorage.write(key: _runbooksKey, value: encoded);
    await _updateMeta(previous: snapshot.parsed, current: runbooks);
    RunbookChangeBus.instance.notify();
  }

  /// Convenience: insert or replace a single runbook by id.
  Future<void> upsert(Runbook runbook) async {
    final all = await loadAll();
    final idx = all.indexWhere((r) => r.id == runbook.id);
    if (idx >= 0) {
      all[idx] = runbook;
    } else {
      all.add(runbook);
    }
    await saveAll(all);
  }

  /// Convenience: drop a single runbook by id.
  Future<void> delete(String runbookId) async {
    final all = await loadAll();
    all.removeWhere((r) => r.id == runbookId);
    await saveAll(all);
  }

  Future<RunbookSyncMeta> loadMeta() async {
    final raw = await _secureStorage.read(key: _metaKey);
    if (raw == null || raw.trim().isEmpty) return RunbookSyncMeta.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return RunbookSyncMeta.empty;
      return RunbookSyncMeta.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return RunbookSyncMeta.empty;
    }
  }

  /// Replaces the entire runbook list and metadata in a single call.
  /// Used by [RunbookSyncService] after a pull-and-merge so the next
  /// [loadAll] sees the merged result. Does NOT notify the change
  /// bus — pulls must not trigger a re-upload loop. Opaque on-disk
  /// entries are preserved.
  Future<void> applyMergedState({
    required List<Runbook> runbooks,
    required RunbookSyncMeta meta,
  }) async {
    final snapshot = await _readSnapshot();
    final encoded = jsonEncode([
      ...runbooks.map((r) => r.toJson()),
      ...snapshot.opaque,
    ]);
    await _secureStorage.write(key: _runbooksKey, value: encoded);
    await _writeMeta(meta);
  }

  Future<void> _updateMeta({
    required List<Runbook> previous,
    required List<Runbook> current,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = await loadMeta();
    final updatedAt = Map<String, DateTime>.from(existing.updatedAt);
    final tombstones = Map<String, DateTime>.from(existing.tombstones);

    final prevById = {for (final r in previous) r.id: r};
    final currentIds = current.map((r) => r.id).toSet();

    for (final r in current) {
      final prev = prevById[r.id];
      final changed = prev == null ||
          jsonEncode(prev.toJson()) != jsonEncode(r.toJson());
      if (changed || !updatedAt.containsKey(r.id)) {
        updatedAt[r.id] = now;
      }
      tombstones.remove(r.id);
    }

    for (final prev in previous) {
      if (!currentIds.contains(prev.id)) {
        tombstones[prev.id] = now;
        updatedAt.remove(prev.id);
      }
    }

    await _writeMeta(RunbookSyncMeta(
      updatedAt: updatedAt,
      tombstones: tombstones,
    ));
  }

  Future<void> _writeMeta(RunbookSyncMeta meta) async {
    await _secureStorage.write(
      key: _metaKey,
      value: jsonEncode(meta.toJson()),
    );
  }

  /// Generate a stable random runbook id. Exposed as a static helper
  /// so the editor / starter pack can mint ids without instantiating
  /// the storage.
  static String generateId() {
    final rand = Random.secure().nextInt(1 << 32);
    return 'rb-${DateTime.now().microsecondsSinceEpoch}-$rand';
  }
}

class _StorageSnapshot {
  const _StorageSnapshot({required this.parsed, required this.opaque});
  final List<Runbook> parsed;
  final List<Map<String, dynamic>> opaque;
}

class RunbookStorageException implements Exception {
  const RunbookStorageException(this.message);
  final String message;
  @override
  String toString() => message;
}
