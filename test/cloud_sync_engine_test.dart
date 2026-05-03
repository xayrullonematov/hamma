import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/backup/cloud_sync_engine.dart';
import 'package:hamma/core/storage/backup_storage.dart' show CloudSyncCadence;

/// In-memory adapter for tests. Records every call so assertions can
/// pin down exactly what was uploaded.
class _MemAdapter implements CloudSyncAdapter {
  final Map<String, Uint8List> store = {};
  final List<String> putCalls = [];
  final List<String> deleteCalls = [];
  final List<({String from, String to})> renameCalls = [];

  @override
  String get destinationLabel => 'Memory';

  @override
  bool get isConfigured => true;

  @override
  Future<List<CloudObject>> list() async {
    return store.entries
        .map((e) => CloudObject(
              key: e.key,
              size: e.value.length,
              lastModified: DateTime.now(),
            ))
        .toList();
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    putCalls.add(key);
    store[key] = bytes;
  }

  @override
  Future<Uint8List> get(String key) async {
    final bytes = store[key];
    if (bytes == null) {
      throw CloudSyncException('not found: $key');
    }
    return bytes;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls.add(key);
    store.remove(key);
  }

  @override
  Future<void> rename(String fromKey, String toKey) async {
    renameCalls.add((from: fromKey, to: toKey));
    final v = store.remove(fromKey);
    if (v != null) store[toKey] = v;
  }
}

/// Returns a synthetic ciphertext blob with the real HMBK header so
/// the engine's defence-in-depth check is satisfied.
Uint8List _fakeCiphertext(List<int> body) {
  return Uint8List.fromList([0x48, 0x4D, 0x42, 0x4B, 0x02, ...body]);
}

void main() {
  group('CloudSyncEngine.sync', () {
    test('uploads ciphertext, writes manifest, returns result', () async {
      final adapter = _MemAdapter();
      final engine = CloudSyncEngine(
        adapter: adapter,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        encrypter: (p) => _fakeCiphertext(p),
        clock: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
      );

      final result = await engine.sync(Uint8List.fromList([1, 2, 3]));

      expect(result.uploadedKey, startsWith('hamma/snapshot-2026-05-02T12-00-00Z-dev-1-'));
      expect(result.uploadedKey, endsWith('.aes'));
      // The blob in the bucket starts with HMBK (it's ciphertext).
      final stored = adapter.store[result.uploadedKey]!;
      expect(stored.sublist(0, 4), [0x48, 0x4D, 0x42, 0x4B]);

      // Manifest exists.
      final manifestBytes = adapter.store['hamma/manifest.json']!;
      final manifest = CloudSyncManifest.decode(manifestBytes);
      expect(manifest.entries, hasLength(1));
      expect(manifest.entries.first.deviceId, 'dev-1');
      expect(manifest.entries.first.timestamp,
          DateTime.utc(2026, 5, 2, 12, 0, 0));
    });

    test('refuses to upload when encrypter returns plaintext', () async {
      final adapter = _MemAdapter();
      final engine = CloudSyncEngine(
        adapter: adapter,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        // Bug: encrypter is a no-op — returns plaintext.
        encrypter: (p) => p,
        clock: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
      );

      expect(
        () => engine.sync(Uint8List.fromList(utf8.encode('SECRETS'))),
        throwsA(isA<CloudSyncException>()),
      );
      // Critical: nothing must have been put.
      expect(adapter.putCalls, isEmpty);
      expect(adapter.store, isEmpty);
    });

    test('moves prior same-device snapshots into conflicts/', () async {
      final adapter = _MemAdapter();
      var t = DateTime.utc(2026, 5, 2, 12, 0, 0);
      final engine = CloudSyncEngine(
        adapter: adapter,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        encrypter: _fakeCiphertext,
        clock: () => t,
      );

      final first = await engine.sync(Uint8List.fromList([1]));
      t = DateTime.utc(2026, 5, 2, 13, 0, 0);
      final second = await engine.sync(Uint8List.fromList([2]));

      expect(second.movedToConflicts, contains(first.uploadedKey));
      // Conflict object exists under conflicts/.
      final conflictKeys = adapter.store.keys
          .where((k) => k.startsWith('hamma/conflicts/'))
          .toList();
      expect(conflictKeys, hasLength(1));
    });

    test('manifest entries from other devices are preserved', () async {
      final adapter = _MemAdapter();
      // Pre-populate manifest with a foreign-device entry.
      final existing = CloudSyncManifest(entries: [
        CloudSyncManifestEntry(
          key: 'hamma/snapshot-foreign.aes',
          deviceId: 'dev-other',
          timestamp: DateTime.utc(2026, 5, 1),
          blobHash: 'abc',
          sizeBytes: 100,
        ),
      ]);
      adapter.store['hamma/manifest.json'] = existing.encode();

      final engine = CloudSyncEngine(
        adapter: adapter,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        encrypter: _fakeCiphertext,
        clock: () => DateTime.utc(2026, 5, 2),
      );
      await engine.sync(Uint8List.fromList([1]));

      final manifest = CloudSyncManifest.decode(
        adapter.store['hamma/manifest.json']!,
      );
      expect(manifest.entries.map((e) => e.deviceId),
          containsAll(['dev-other', 'dev-1']));
    });
  });

  group('CloudSyncEngine.fetchLatestSnapshot', () {
    test('returns the newest entry across devices', () async {
      final adapter = _MemAdapter();
      final engine = CloudSyncEngine(
        adapter: adapter,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        encrypter: _fakeCiphertext,
        clock: () => DateTime.utc(2026, 5, 2),
      );
      // Seed two snapshots at different times.
      adapter.store['hamma/old.aes'] = _fakeCiphertext([1]);
      adapter.store['hamma/new.aes'] = _fakeCiphertext([2]);
      adapter.store['hamma/manifest.json'] = CloudSyncManifest(entries: [
        CloudSyncManifestEntry(
          key: 'hamma/old.aes',
          deviceId: 'a',
          timestamp: DateTime.utc(2026, 4, 1),
          blobHash: 'h1',
          sizeBytes: 6,
        ),
        CloudSyncManifestEntry(
          key: 'hamma/new.aes',
          deviceId: 'b',
          timestamp: DateTime.utc(2026, 5, 1),
          blobHash: 'h2',
          sizeBytes: 6,
        ),
      ]).encode();

      final result = await engine.fetchLatestSnapshot();
      expect(result.entry.key, 'hamma/new.aes');
      expect(result.ciphertext.sublist(0, 4), [0x48, 0x4D, 0x42, 0x4B]);
    });

    test('throws when manifest is empty', () async {
      final adapter = _MemAdapter();
      final engine = CloudSyncEngine(
        adapter: adapter,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        encrypter: _fakeCiphertext,
      );
      expect(
        () => engine.fetchLatestSnapshot(),
        throwsA(isA<CloudSyncException>()),
      );
    });
  });

  group('cadenceInterval', () {
    test('manual returns null', () {
      expect(cadenceInterval(CloudSyncCadence.manual), isNull);
    });
    test('hourly / daily map to durations', () {
      expect(cadenceInterval(CloudSyncCadence.hourly), const Duration(hours: 1));
      expect(cadenceInterval(CloudSyncCadence.daily), const Duration(hours: 24));
    });
  });
}
