// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/quick_actions/quick_actions.dart';

class CustomActionsStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const CustomActionsStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _customActionsStorageKey = 'custom_quick_actions';

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
    } catch (error) {
      throw CustomActionsStorageException(
        'Could not save custom quick actions: $error',
      );
    }
  }

  Future<void> clearActions() async {
    try {
      await _secureStorage.delete(key: _customActionsStorageKey);
    } catch (error) {
      throw CustomActionsStorageException(
        'Could not clear custom quick actions: $error',
      );
    }
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
