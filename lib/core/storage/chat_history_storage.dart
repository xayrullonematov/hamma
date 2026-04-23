import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ChatHistoryStorage {
  const ChatHistoryStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _sessionsPrefix = 'ai_sessions_';
  static const _messagesPrefix = 'ai_messages_';

  final FlutterSecureStorage _secureStorage;

  Future<List<Map<String, String>>> listSessions({required String serverId}) async {
    final raw = await _secureStorage.read(key: '$_sessionsPrefix$serverId');
    if (raw == null) return [];
    try {
      final List decoded = jsonDecode(raw);
      return decoded.map((e) => Map<String, String>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSessions({required String serverId, required List<Map<String, String>> sessions}) async {
    await _secureStorage.write(key: '$_sessionsPrefix$serverId', value: jsonEncode(sessions));
  }

  Future<List<Map<String, dynamic>>> loadMessages({required String serverId, required String sessionId}) async {
    final raw = await _secureStorage.read(key: '$_messagesPrefix${serverId}_$sessionId');
    if (raw == null) return [];
    try {
      final List decoded = jsonDecode(raw);
      return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages({
    required String serverId,
    required String sessionId,
    required List<Map<String, dynamic>> messages,
  }) async {
    await _secureStorage.write(
      key: '$_messagesPrefix${serverId}_$sessionId',
      value: jsonEncode(messages),
    );
  }

  Future<void> deleteSession({required String serverId, required String sessionId}) async {
    await _secureStorage.delete(key: '$_messagesPrefix${serverId}_$sessionId');
    final sessions = await listSessions(serverId: serverId);
    sessions.removeWhere((s) => s['id'] == sessionId);
    await saveSessions(serverId: serverId, sessions: sessions);
  }

  // Legacy support or fallback
  Future<List<Map<String, String>>> loadHistory({required String serverId}) async => [];
  Future<void> saveHistory({required String serverId, required List<Map<String, String>> messages}) async {}
  Future<void> clearHistory({required String serverId}) async {}
}
