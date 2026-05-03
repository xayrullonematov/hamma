import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistence for the AI log-triage feature: muted-anomaly fingerprints
/// and the user-configured analysis cadence.
///
/// Stored in [FlutterSecureStorage] alongside the rest of the app's
/// prefs because the cadence + mute set are tied to the user's local
/// AI workflow and we want consistent encryption-at-rest semantics.
class LogTriagePrefs {
  const LogTriagePrefs({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _mutedKey = 'log_triage_muted_fingerprints';
  static const _batchSizeKey = 'log_triage_batch_size';

  /// Default lines-per-batch — small enough to keep round-trips cheap
  /// on a CPU-bound local model, large enough to give the LLM useful
  /// context. Matches the spec.
  static const defaultBatchSize = 50;

  /// Hard upper bound on the configurable batch size. Guards against
  /// pathologically long prompts that would stall a small local model.
  static const maxBatchSize = 500;

  /// Lower bound on the batch size — anything smaller wouldn't give
  /// the LLM enough context to find a pattern.
  static const minBatchSize = 10;

  final FlutterSecureStorage _secureStorage;

  Future<Set<String>> loadMutedFingerprints() async {
    final raw = await _secureStorage.read(key: _mutedKey);
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> saveMutedFingerprints(Set<String> fingerprints) async {
    final cleaned = fingerprints
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      await _secureStorage.delete(key: _mutedKey);
      return;
    }
    await _secureStorage.write(
      key: _mutedKey,
      value: jsonEncode(cleaned),
    );
  }

  Future<void> mute(String fingerprint) async {
    final current = await loadMutedFingerprints();
    if (current.add(fingerprint)) {
      await saveMutedFingerprints(current);
    }
  }

  Future<void> unmute(String fingerprint) async {
    final current = await loadMutedFingerprints();
    if (current.remove(fingerprint)) {
      await saveMutedFingerprints(current);
    }
  }

  Future<int> loadBatchSize() async {
    final raw = await _secureStorage.read(key: _batchSizeKey);
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null) return defaultBatchSize;
    return clampBatchSize(parsed);
  }

  Future<void> saveBatchSize(int size) async {
    final clamped = clampBatchSize(size);
    await _secureStorage.write(
      key: _batchSizeKey,
      value: clamped.toString(),
    );
  }

  static int clampBatchSize(int size) {
    if (size < minBatchSize) return minBatchSize;
    if (size > maxBatchSize) return maxBatchSize;
    return size;
  }
}
