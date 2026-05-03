// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-snippet metadata that lives alongside the snippets themselves.
///
/// `updatedAt` is keyed by snippet id and set whenever the user mutates
/// the matching snippet's `label` or `command`. `tombstones` records the
/// time at which a previously-existing snippet id was deleted, so a
/// stale remote copy can't resurrect it after the next pull.
class SnippetSyncMeta {
  const SnippetSyncMeta({
    required this.updatedAt,
    required this.tombstones,
  });

  final Map<String, DateTime> updatedAt;
  final Map<String, DateTime> tombstones;

  static const SnippetSyncMeta empty =
      SnippetSyncMeta(updatedAt: {}, tombstones: {});

  SnippetSyncMeta copyWith({
    Map<String, DateTime>? updatedAt,
    Map<String, DateTime>? tombstones,
  }) {
    return SnippetSyncMeta(
      updatedAt: updatedAt ?? this.updatedAt,
      tombstones: tombstones ?? this.tombstones,
    );
  }

  Map<String, dynamic> toJson() => {
        'updatedAt': {
          for (final e in updatedAt.entries) e.key: e.value.toIso8601String(),
        },
        'tombstones': {
          for (final e in tombstones.entries) e.key: e.value.toIso8601String(),
        },
      };

  factory SnippetSyncMeta.fromJson(Map<String, dynamic> json) {
    Map<String, DateTime> parseMap(Object? raw) {
      if (raw is! Map) return <String, DateTime>{};
      final out = <String, DateTime>{};
      for (final entry in raw.entries) {
        final ts = DateTime.tryParse(entry.value?.toString() ?? '');
        if (ts != null) out[entry.key.toString()] = ts;
      }
      return out;
    }

    return SnippetSyncMeta(
      updatedAt: parseMap(json['updatedAt']),
      tombstones: parseMap(json['tombstones']),
    );
  }
}

/// One row in the sync-history feed shown on the settings screen.
class SnippetSyncHistoryEntry {
  const SnippetSyncHistoryEntry({
    required this.timestamp,
    required this.operation,
    required this.success,
    this.message,
  });

  final DateTime timestamp;

  /// `push` or `pull`.
  final String operation;
  final bool success;
  final String? message;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'operation': operation,
        'success': success,
        'message': message,
      };

  factory SnippetSyncHistoryEntry.fromJson(Map<String, dynamic> json) {
    return SnippetSyncHistoryEntry(
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      operation: (json['operation'] ?? 'push').toString(),
      success: json['success'] == true,
      message: json['message']?.toString(),
    );
  }
}

/// Persists the snippet-sync feature flag, this device's stable id,
/// last successful sync time, and a rolling sync-history list.
///
/// Snippet *content* and per-id `updatedAt` / tombstone metadata live in
/// `CustomActionsStorage` so the storage layer stays the single source
/// of truth for what the user has typed. This class only owns the sync
/// *state machine*.
class SnippetSyncStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const SnippetSyncStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage =
            secureStorage ?? const FlutterSecureStorage(aOptions: _androidOptions);

  static const _enabledKey = 'snippet_sync_enabled';
  static const _deviceIdKey = 'snippet_sync_device_id';
  static const _lastSyncKey = 'snippet_sync_last_at';
  static const _historyKey = 'snippet_sync_history';
  static const _sharedTeamRunbookIdsKey = 'runbook_sync_shared_team_ids';
  static const _maxHistoryEntries = 10;

  final FlutterSecureStorage _secureStorage;

  Future<bool> isEnabled() async {
    final raw = await _secureStorage.read(key: _enabledKey);
    return raw == 'true';
  }

  Future<void> setEnabled(bool enabled) async {
    await _secureStorage.write(
      key: _enabledKey,
      value: enabled ? 'true' : 'false',
    );
  }

  /// Stable random device id used to tag uploaded blobs so peers can
  /// recognise their own snapshots and skip re-merging them.
  Future<String> getOrCreateDeviceId() async {
    final existing = await _secureStorage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _generateDeviceId();
    await _secureStorage.write(key: _deviceIdKey, value: fresh);
    return fresh;
  }

  Future<DateTime?> getLastSyncAt() async {
    final raw = await _secureStorage.read(key: _lastSyncKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastSyncAt(DateTime when) async {
    await _secureStorage.write(
      key: _lastSyncKey,
      value: when.toIso8601String(),
    );
  }

  Future<List<SnippetSyncHistoryEntry>> loadHistory() async {
    final raw = await _secureStorage.read(key: _historyKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(SnippetSyncHistoryEntry.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> appendHistory(SnippetSyncHistoryEntry entry) async {
    final current = await loadHistory();
    final next = <SnippetSyncHistoryEntry>[entry, ...current];
    if (next.length > _maxHistoryEntries) {
      next.removeRange(_maxHistoryEntries, next.length);
    }
    await _secureStorage.write(
      key: _historyKey,
      value: jsonEncode(next.map((e) => e.toJson()).toList()),
    );
  }

  /// Stable record of every runbook id this device has ever uploaded
  /// as `team:true`. Needed by `RunbookSyncService` so a deletion or
  /// "untag team" of a previously-shared runbook still emits a
  /// tombstone on the team channel — without this set, the id would
  /// vanish from the live team-id list and other devices would
  /// silently resurrect the deleted entry on the next merge.
  Future<Set<String>> loadSharedTeamRunbookIds() async {
    final raw = await _secureStorage.read(key: _sharedTeamRunbookIdsKey);
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((e) => e.toString()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> saveSharedTeamRunbookIds(Set<String> ids) async {
    await _secureStorage.write(
      key: _sharedTeamRunbookIdsKey,
      value: jsonEncode(ids.toList()),
    );
  }

  Future<void> clearAll() async {
    await _secureStorage.delete(key: _enabledKey);
    await _secureStorage.delete(key: _deviceIdKey);
    await _secureStorage.delete(key: _lastSyncKey);
    await _secureStorage.delete(key: _historyKey);
    await _secureStorage.delete(key: _sharedTeamRunbookIdsKey);
  }

  String _generateDeviceId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(8, (_) => rand.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
