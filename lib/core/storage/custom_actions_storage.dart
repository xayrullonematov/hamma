// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/quick_actions/quick_actions.dart';
import '../sync/snippet_change_bus.dart';
import '../sync/snippet_sync_storage.dart';

class CustomActionsStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const CustomActionsStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _customActionsStorageKey = 'custom_quick_actions';
  static const _customActionsMetaKey = 'custom_quick_actions_meta';

  final FlutterSecureStorage _secureStorage;

  Future<List<QuickAction>> loadActions() async {
    try {
      final rawValue = await _secureStorage.read(key: _customActionsStorageKey);
      if (rawValue == null || rawValue.trim().isEmpty) {
        return const [];
      }

      final decoded = jsonDecode(rawValue);
      if (decoded is! List) {
        throw const CustomActionsStorageException(
          'Saved custom action data is invalid.',
        );
      }

      final actions = <QuickAction>[];
      final seenIds = <String>{};
      var shouldNormalize = false;

      for (final item in decoded) {
        if (item is! Map) {
          throw const CustomActionsStorageException(
            'Saved custom action data is invalid.',
          );
        }

        var action = QuickAction.fromJson(Map<String, dynamic>.from(item));
        if (action.id.trim().isEmpty || !seenIds.add(action.id)) {
          action = QuickAction(
            id: _generateActionId(),
            label: action.label,
            command: action.command,
            isCustom: true,
          );
          seenIds.add(action.id);
          shouldNormalize = true;
        } else if (!action.isCustom) {
          action = QuickAction(
            id: action.id,
            label: action.label,
            command: action.command,
            isCustom: true,
          );
          shouldNormalize = true;
        }

        actions.add(action);
      }

      if (shouldNormalize) {
        await saveActions(actions);
      }

      return actions;
    } catch (error) {
      if (error is CustomActionsStorageException) {
        rethrow;
      }

      throw CustomActionsStorageException(
        'Could not load custom quick actions: $error',
      );
    }
  }

  Future<void> saveActions(List<QuickAction> actions) async {
    try {
      // Diff against the previous on-disk list so we can stamp
      // updatedAt only on snippets the user actually changed and
      // tombstone ids that disappeared. The diff is best-effort —
      // failures fall back to stamping the whole list, which is
      // safe (slightly less precise merging only).
      List<QuickAction> previous = const [];
      try {
        final raw =
            await _secureStorage.read(key: _customActionsStorageKey);
        if (raw != null && raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            previous = decoded
                .whereType<Map<String, dynamic>>()
                .map(QuickAction.fromJson)
                .toList();
          }
        }
      } catch (_) {
        previous = const [];
      }

      final encoded = jsonEncode(
        actions
            .map(
              (action) => QuickAction(
                id: action.id,
                label: action.label,
                command: action.command,
                isCustom: true,
              ).toJson(),
            )
            .toList(),
      );

      await _secureStorage.write(
        key: _customActionsStorageKey,
        value: encoded,
      );

      await _updateMetaForSave(previous: previous, current: actions);
    } catch (error) {
      throw CustomActionsStorageException(
        'Could not save custom quick actions: $error',
      );
    }

    SnippetChangeBus.instance.notify();
  }

  Future<void> clearActions() async {
    try {
      List<QuickAction> previous = const [];
      try {
        final raw =
            await _secureStorage.read(key: _customActionsStorageKey);
        if (raw != null && raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            previous = decoded
                .whereType<Map<String, dynamic>>()
                .map(QuickAction.fromJson)
                .toList();
          }
        }
      } catch (_) {
        previous = const [];
      }

      await _secureStorage.delete(key: _customActionsStorageKey);
      await _updateMetaForSave(previous: previous, current: const []);
    } catch (error) {
      throw CustomActionsStorageException(
        'Could not clear custom quick actions: $error',
      );
    }

    SnippetChangeBus.instance.notify();
  }

  /// Reads the per-id `updatedAt` + tombstones map. Used by the
  /// snippet-sync service for newest-wins merges.
  Future<SnippetSyncMeta> loadMeta() async {
    try {
      final raw = await _secureStorage.read(key: _customActionsMetaKey);
      if (raw == null || raw.trim().isEmpty) return SnippetSyncMeta.empty;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return SnippetSyncMeta.empty;
      return SnippetSyncMeta.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return SnippetSyncMeta.empty;
    }
  }

  /// Replaces both the snippets list and the metadata in one go. Used
  /// by the snippet-sync service after a pull-and-merge so the UI sees
  /// the merged result on next [loadActions]. Does NOT notify the
  /// change bus — pulls must not trigger a re-upload loop.
  Future<void> applyMergedState({
    required List<QuickAction> snippets,
    required SnippetSyncMeta meta,
  }) async {
    final encoded = jsonEncode(
      snippets
          .map(
            (action) => QuickAction(
              id: action.id,
              label: action.label,
              command: action.command,
              isCustom: true,
            ).toJson(),
          )
          .toList(),
    );
    await _secureStorage.write(
      key: _customActionsStorageKey,
      value: encoded,
    );
    await _writeMeta(meta);
  }

  Future<void> _updateMetaForSave({
    required List<QuickAction> previous,
    required List<QuickAction> current,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = await loadMeta();
    final updatedAt = Map<String, DateTime>.from(existing.updatedAt);
    final tombstones = Map<String, DateTime>.from(existing.tombstones);

    final prevById = {for (final a in previous) a.id: a};
    final currentIds = current.map((a) => a.id).toSet();

    // Stamp updatedAt for new or modified snippets.
    for (final a in current) {
      final prev = prevById[a.id];
      final changed = prev == null ||
          prev.label != a.label ||
          prev.command != a.command;
      if (changed || !updatedAt.containsKey(a.id)) {
        updatedAt[a.id] = now;
      }
      // A revived id should clear any lingering tombstone.
      tombstones.remove(a.id);
    }

    // Tombstone previously-present ids that disappeared.
    for (final prev in previous) {
      if (!currentIds.contains(prev.id)) {
        tombstones[prev.id] = now;
        updatedAt.remove(prev.id);
      }
    }

    await _writeMeta(SnippetSyncMeta(
      updatedAt: updatedAt,
      tombstones: tombstones,
    ));
  }

  Future<void> _writeMeta(SnippetSyncMeta meta) async {
    await _secureStorage.write(
      key: _customActionsMetaKey,
      value: jsonEncode(meta.toJson()),
    );
  }

  String _generateActionId() {
    final random = Random.secure().nextInt(1 << 32);
    return 'custom-${DateTime.now().microsecondsSinceEpoch}-$random';
  }
}

class CustomActionsStorageException implements Exception {
  const CustomActionsStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}
