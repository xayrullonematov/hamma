import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

/// One scored entry: a `(category, itemId)` pair the user has touched,
/// remembered with how often (`count`) and how recently
/// (`lastAccessedMs`).
///
/// The plan's score formula is `log(count + 1) / sqrt(ageDays + 1)`:
///   * `log(count + 1)` so the *first* hit gives a non-zero score —
///     `log(1)` would be zero and tie all once-touched items together.
///   * `sqrt(ageDays + 1)` so recency decay starts gracefully (no
///     cliff edge at one day) and never divides by zero.
@immutable
class FrecencyEntry {
  const FrecencyEntry({
    required this.category,
    required this.itemId,
    required this.count,
    required this.lastAccessedMs,
  });

  final String category;
  final String itemId;
  final int count;
  final int lastAccessedMs;

  double scoreAt(int nowMs) {
    final ageMs = math.max(0, nowMs - lastAccessedMs);
    final ageDays = ageMs / Duration.millisecondsPerDay;
    return math.log(count + 1) / math.sqrt(ageDays + 1.0);
  }

  FrecencyEntry copyWith({int? count, int? lastAccessedMs}) {
    return FrecencyEntry(
      category: category,
      itemId: itemId,
      count: count ?? this.count,
      lastAccessedMs: lastAccessedMs ?? this.lastAccessedMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'category': category,
    'itemId': itemId,
    'count': count,
    'lastAccessedMs': lastAccessedMs,
  };

  factory FrecencyEntry.fromJson(Map<String, dynamic> json) {
    return FrecencyEntry(
      category: (json['category'] ?? '').toString(),
      itemId: (json['itemId'] ?? '').toString(),
      count: (json['count'] as num?)?.toInt() ?? 0,
      lastAccessedMs: (json['lastAccessedMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persistent frecency index — "how often + how recently did the user
/// touch this thing?" — used by the palette to rank server / file /
/// command / runbook lists in muscle-memory order.
///
/// Storage layout: one secure-storage key (`frecency_v1`) holding a
/// JSON map keyed by `"category:itemId"`. Categories are namespaces:
/// `servers`, `runbooks`, `sftp_files`, `commands`, `screens`, etc.
/// The composite key avoids collisions across categories without
/// forcing callers to coordinate ids.
///
/// Bounded growth: at most [_maxEntries] rows are kept; when a write
/// would push past that, the oldest entries by `lastAccessedMs` are
/// evicted first. That's slightly different from a pure-score LRU but
/// matches user intent — a thing they haven't touched in months is
/// the right thing to forget, even if it was hot at the time.
class FrecencyStorage {
  FrecencyStorage({FlutterSecureStorage? secureStorage, Clock? clock})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _clock = clock ?? const Clock();

  static const _storageKey = 'frecency_v1';
  static const _maxEntries = 5000;

  final FlutterSecureStorage _secureStorage;
  final Clock _clock;

  /// Bump the count and timestamp for `(category, itemId)`. Idempotent
  /// per millisecond; safe to call from connect / open / run paths.
  Future<void> record(String category, String itemId) async {
    if (category.isEmpty || itemId.isEmpty) return;
    final all = await _loadAll();
    final key = _key(category, itemId);
    final now = _clock.nowMs();
    final existing = all[key];
    all[key] = (existing ??
            FrecencyEntry(
              category: category,
              itemId: itemId,
              count: 0,
              lastAccessedMs: now,
            ))
        .copyWith(count: (existing?.count ?? 0) + 1, lastAccessedMs: now);

    if (all.length > _maxEntries) {
      _evictOldest(all);
    }
    await _saveAll(all);
  }

  /// Score for one item. Returns 0 when no record exists, which means
  /// "no boost" — never accessed sorts below anything that has been.
  Future<double> scoreFor(String category, String itemId) async {
    final all = await _loadAll();
    final entry = all[_key(category, itemId)];
    if (entry == null) return 0;
    return entry.scoreAt(_clock.nowMs());
  }

  /// All scores in a category. Callers use this to weight ranking in
  /// the palette or any list that wants frecency order.
  Future<Map<String, double>> scoresForCategory(String category) async {
    final now = _clock.nowMs();
    final all = await _loadAll();
    final out = <String, double>{};
    for (final e in all.values) {
      if (e.category == category) {
        out[e.itemId] = e.scoreAt(now);
      }
    }
    return out;
  }

  /// Top `limit` items by score, highest first. Used directly by the
  /// SFTP recents list, the server list re-sort, and the palette's
  /// "recent" sources.
  Future<List<String>> topItems(String category, {int limit = 20}) async {
    final scores = await scoresForCategory(category);
    final sorted =
        scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList(growable: false);
  }

  /// Raw access count, mostly for tests and debug surfaces.
  Future<int> countFor(String category, String itemId) async {
    final all = await _loadAll();
    return all[_key(category, itemId)]?.count ?? 0;
  }

  /// Wipe one category (e.g. when the user clears recent files) or
  /// everything (factory reset).
  Future<void> clear({String? category}) async {
    if (category == null) {
      await _secureStorage.delete(key: _storageKey);
      return;
    }
    final all = await _loadAll();
    all.removeWhere((_, entry) => entry.category == category);
    await _saveAll(all);
  }

  static String _key(String category, String itemId) => '$category:$itemId';

  void _evictOldest(Map<String, FrecencyEntry> all) {
    final ordered =
        all.entries.toList()..sort(
          (a, b) => a.value.lastAccessedMs.compareTo(b.value.lastAccessedMs),
        );
    final excess = all.length - _maxEntries;
    for (var i = 0; i < excess; i++) {
      all.remove(ordered[i].key);
    }
  }

  Future<Map<String, FrecencyEntry>> _loadAll() async {
    final raw = await _secureStorage.read(key: _storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, FrecencyEntry>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final parsed = FrecencyEntry.fromJson(Map<String, dynamic>.from(value));
        if (parsed.category.isEmpty || parsed.itemId.isEmpty) continue;
        out[entry.key.toString()] = parsed;
      }
      return out;
    } catch (_) {
      // Corrupt blob: treat as empty rather than blocking the app.
      // Frecency is a UX nicety, never load-bearing for correctness.
      return {};
    }
  }

  Future<void> _saveAll(Map<String, FrecencyEntry> all) async {
    final payload = <String, Map<String, dynamic>>{
      for (final entry in all.entries) entry.key: entry.value.toJson(),
    };
    await _secureStorage.write(key: _storageKey, value: jsonEncode(payload));
  }
}

/// Injectable wall-clock so tests can assert score decay deterministically.
@visibleForTesting
class Clock {
  const Clock();
  int nowMs() => DateTime.now().millisecondsSinceEpoch;
}
