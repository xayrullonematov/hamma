import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum VaultAccessAction { copied, revealed }

class VaultAccessEvent {
  final String secretId;
  final String? groupId;
  final VaultAccessAction action;
  final DateTime timestamp;

  VaultAccessEvent({
    required this.secretId,
    this.groupId,
    required this.action,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'secretId': secretId,
        'groupId': groupId,
        'action': action.name,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  factory VaultAccessEvent.fromJson(Map<String, dynamic> json) {
    return VaultAccessEvent(
      secretId: (json['secretId'] ?? '').toString(),
      groupId: json['groupId']?.toString(),
      action: VaultAccessAction.values.firstWhere(
        (e) => e.name == json['action'],
        orElse: () => VaultAccessAction.revealed,
      ),
      timestamp: DateTime.tryParse((json['timestamp'] ?? '').toString())?.toLocal() ?? DateTime.now(),
    );
  }
}

class VaultAccessLog {
  static const _storageKey = 'vault_access_log';
  static const _maxEvents = 500;

  final FlutterSecureStorage _storage;

  VaultAccessLog({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<void> log(VaultAccessEvent event) async {
    final events = await _loadAll();
    events.insert(0, event);
    if (events.length > _maxEvents) {
      events.removeRange(_maxEvents, events.length);
    }
    await _saveAll(events);
  }

  Future<DateTime?> lastAccessed(String secretId) async {
    final events = await _loadAll();
    try {
      final last = events.firstWhere((e) => e.secretId == secretId);
      return last.timestamp;
    } catch (_) {
      return null;
    }
  }

  Future<List<VaultAccessEvent>> recentEvents({int limit = 50}) async {
    final events = await _loadAll();
    return events.take(limit).toList();
  }

  Future<List<VaultAccessEvent>> _loadAll() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => VaultAccessEvent.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<VaultAccessEvent> events) async {
    await _storage.write(
      key: _storageKey,
      value: jsonEncode(events.map((e) => e.toJson()).toList()),
    );
  }
}
