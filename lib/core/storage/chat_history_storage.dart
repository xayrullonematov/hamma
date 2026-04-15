// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ChatHistoryStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const ChatHistoryStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _chatHistoryPrefix = 'chat_history_';

  final FlutterSecureStorage _secureStorage;

  Future<List<Map<String, String>>> loadHistory({
    required String serverId,
  }) async {
    final rawValue = await _secureStorage.read(key: _storageKey(serverId));
    if (rawValue == null || rawValue.trim().isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(rawValue);
    if (decoded is! List) {
      return const [];
    }

    final messages = <Map<String, String>>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }

      final role = (item['role'] ?? '').toString().trim();
      final content = (item['content'] ?? '').toString().trim();
      if (role.isEmpty || content.isEmpty) {
        continue;
      }

      messages.add({
        'role': role,
        'content': content,
      });
    }

    return messages;
  }

  Future<void> saveHistory({
    required String serverId,
    required List<Map<String, String>> messages,
  }) async {
    await _secureStorage.write(
      key: _storageKey(serverId),
      value: jsonEncode(messages),
    );
  }

  Future<void> clearHistory({
    required String serverId,
  }) async {
    await _secureStorage.delete(key: _storageKey(serverId));
  }

  String _storageKey(String serverId) {
    return '$_chatHistoryPrefix${Uri.encodeComponent(serverId)}';
  }
}
