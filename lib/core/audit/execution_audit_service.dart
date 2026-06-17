import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'execution_audit_entry.dart';

class ExecutionAuditService {
  static const _storageKey = 'execution_audit_log';
  static const _maxEntries = 1000;

  final FlutterSecureStorage _storage;

  ExecutionAuditService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<void> logExecution(ExecutionAuditEntry entry) async {
    final entries = await _loadAll();
    entries.insert(0, entry);
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    await _saveAll(entries);
  }

  Future<List<ExecutionAuditEntry>> loadAll() async {
    return _loadAll();
  }

  Future<List<ExecutionAuditEntry>> loadByServer(String serverId) async {
    final entries = await _loadAll();
    return entries.where((e) => e.serverId == serverId).toList();
  }

  Future<List<ExecutionAuditEntry>> search(String query) async {
    final entries = await _loadAll();
    final lowerQuery = query.toLowerCase();
    return entries
        .where((e) =>
            e.proposedCommand.toLowerCase().contains(lowerQuery) ||
            e.naturalLanguageIntent.toLowerCase().contains(lowerQuery))
        .toList();
  }

  Future<void> deleteEntry(String id) async {
    final entries = await _loadAll();
    entries.removeWhere((e) => e.id == id);
    await _saveAll(entries);
  }

  Future<void> clearAll() async {
    await _storage.delete(key: _storageKey);
  }

  Future<List<ExecutionAuditEntry>> recentEntries({int limit = 50}) async {
    final entries = await _loadAll();
    return entries.take(limit).toList();
  }

  Future<List<ExecutionAuditEntry>> _loadAll() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => ExecutionAuditEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<ExecutionAuditEntry> entries) async {
    await _storage.write(
      key: _storageKey,
      value: jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
