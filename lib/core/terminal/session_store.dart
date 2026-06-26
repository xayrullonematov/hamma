import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'terminal_session.dart';

class TerminalSessionStore {
  const TerminalSessionStore({
    FlutterSecureStorage? secureStorage,
    int maxScrollbackChars = TerminalSession.maxScrollbackChars,
    int maxSessionsPerServer = 3,
    int Function()? nowMs,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _maxScrollbackChars = maxScrollbackChars,
       _maxSessionsPerServer = maxSessionsPerServer,
       _nowMs = nowMs;

  static const _indexPrefix = 'terminal_sessions_v1_index_';
  static const _sessionPrefix = 'terminal_session_v1_';

  final FlutterSecureStorage _secureStorage;
  final int _maxScrollbackChars;
  final int _maxSessionsPerServer;
  final int Function()? _nowMs;

  int _now() => _nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  Future<TerminalSession> loadOrCreate({
    required String serverId,
    required String serverName,
  }) async {
    final latest = await loadLatest(serverId: serverId);
    if (latest != null) return latest;
    return create(serverId: serverId, serverName: serverName);
  }

  TerminalSession create({
    required String serverId,
    required String serverName,
  }) {
    final now = _now();
    return TerminalSession(
      serverId: serverId,
      sessionId: 'term-$now',
      serverName: serverName,
      scrollback: '',
      createdAtMs: now,
      updatedAtMs: now,
    );
  }

  Future<TerminalSession?> loadLatest({required String serverId}) async {
    final sessions = await listSessions(serverId: serverId);
    for (final metadata in sessions) {
      final session = await loadSession(
        serverId: serverId,
        sessionId: metadata.sessionId,
      );
      if (session != null) return session;
    }
    return null;
  }

  Future<TerminalSession?> loadSession({
    required String serverId,
    required String sessionId,
  }) async {
    final raw = await _secureStorage.read(
      key: _sessionKey(serverId, sessionId),
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final session = TerminalSession.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (session.serverId != serverId || session.sessionId != sessionId) {
        return null;
      }
      if (session.serverId.isEmpty || session.sessionId.isEmpty) return null;
      return session.copyWith(
        scrollback: trimTerminalScrollback(
          session.scrollback,
          _maxScrollbackChars,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<TerminalSessionMetadata>> listSessions({
    required String serverId,
  }) async {
    final raw = await _secureStorage.read(key: _indexKey(serverId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <TerminalSessionMetadata>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final metadata = TerminalSessionMetadata.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (metadata.serverId != serverId || metadata.sessionId.isEmpty) {
          continue;
        }
        out.add(metadata);
      }
      out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(TerminalSession session) async {
    if (session.serverId.isEmpty || session.sessionId.isEmpty) return;
    final trimmed = session.copyWith(
      scrollback: trimTerminalScrollback(
        session.scrollback,
        _maxScrollbackChars,
      ),
    );
    await _secureStorage.write(
      key: _sessionKey(trimmed.serverId, trimmed.sessionId),
      value: jsonEncode(trimmed.toJson()),
    );
    await _upsertMetadata(trimmed);
  }

  Future<void> deleteSession({
    required String serverId,
    required String sessionId,
  }) async {
    await _secureStorage.delete(key: _sessionKey(serverId, sessionId));
    final next = (await listSessions(serverId: serverId))
        .where((metadata) => metadata.sessionId != sessionId)
        .toList(growable: false);
    await _writeIndex(serverId, next);
  }

  Future<void> clearServer({required String serverId}) async {
    final sessions = await listSessions(serverId: serverId);
    for (final metadata in sessions) {
      await _secureStorage.delete(
        key: _sessionKey(serverId, metadata.sessionId),
      );
    }
    await _secureStorage.delete(key: _indexKey(serverId));
  }

  Future<void> _upsertMetadata(TerminalSession session) async {
    final metadata = TerminalSessionMetadata(
      serverId: session.serverId,
      sessionId: session.sessionId,
      serverName: session.serverName,
      createdAtMs: session.createdAtMs,
      updatedAtMs: session.updatedAtMs,
      scrollbackChars: session.scrollback.length,
    );
    final existing = await listSessions(serverId: session.serverId);
    final next = <TerminalSessionMetadata>[
      metadata,
      ...existing.where((item) => item.sessionId != session.sessionId),
    ]..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));

    final keepCount = _maxSessionsPerServer < 1 ? 1 : _maxSessionsPerServer;
    final keep = next.take(keepCount).toList(growable: false);
    final evict = next.skip(keepCount);
    for (final metadata in evict) {
      await _secureStorage.delete(
        key: _sessionKey(metadata.serverId, metadata.sessionId),
      );
    }
    await _writeIndex(session.serverId, keep);
  }

  Future<void> _writeIndex(
    String serverId,
    List<TerminalSessionMetadata> sessions,
  ) async {
    await _secureStorage.write(
      key: _indexKey(serverId),
      value: jsonEncode(sessions.map((s) => s.toJson()).toList()),
    );
  }

  static String _indexKey(String serverId) {
    return '$_indexPrefix${_encodeKeyPart(serverId)}';
  }

  static String _sessionKey(String serverId, String sessionId) {
    return '$_sessionPrefix${_encodeKeyPart(serverId)}_${_encodeKeyPart(sessionId)}';
  }

  static String _encodeKeyPart(String value) {
    return base64Url.encode(utf8.encode(value));
  }
}
