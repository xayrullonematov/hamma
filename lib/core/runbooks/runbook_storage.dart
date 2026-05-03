// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

import 'runbook.dart';
import 'runbook_change_bus.dart';

/// Per-id metadata for newest-wins merging.
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
/// Keys: `runbooks_v1` (JSON array) and `runbooks_v1_meta`.
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

  /// Throws [RunbookStorageException] on malformed JSON.
  Future<List<Runbook>> loadAll() async {
    final snapshot = await _readSnapshot();
    return List<Runbook>.from(snapshot.parsed);
  }

  /// Returns parsed runbooks plus undecodable raw entries so
  /// [saveAll] can preserve them on round-trip.
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

  /// Returns runbooks pinned to this server plus all global ones.
  Future<List<Runbook>> loadForServer(String serverId) async {
    final all = await loadAll();
    return all
        .where((r) => r.serverId == null || r.serverId == serverId)
        .toList();
  }

  /// Replaces the runbook list, updates meta, and notifies
  /// [RunbookChangeBus]. Preserves opaque on-disk entries.
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

  /// Insert or replace a single runbook by id.
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

  /// Drop a single runbook by id.
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

  /// Used by [RunbookSyncService] after a merge. Does NOT notify the
  /// change bus (avoids re-upload loops). Preserves opaque entries.
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

  /// Random runbook id. Static so callers needn't instantiate storage.
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
