import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/backup_crypto.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/runbooks/runbook.dart';
import 'package:hamma/core/runbooks/runbook_storage.dart';
import 'package:hamma/core/sync/runbook_sync_service.dart';
import 'package:hamma/core/sync/snippet_sync_storage.dart';

class _InMemoryAdapter extends CloudSyncAdapter {
  final Map<String, Uint8List> store = {};

  @override
  String get destinationLabel => 'in-memory';

  @override
  bool get isConfigured => true;

  @override
  Future<List<CloudObject>> list() async => const [];

  @override
  Future<void> put(String key, Uint8List bytes) async {
    store[key] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> get(String key) async {
    final bytes = store[key];
    if (bytes == null) {
      throw CloudNotFoundException('missing $key');
    }
    return bytes;
  }

  @override
  Future<void> delete(String key) async => store.remove(key);
}

void main() {
  Runbook makeRb(String id, String name) => Runbook(
        id: id,
        name: name,
        team: true,
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'echo',
            type: RunbookStepType.command,
            command: 'echo ok',
          ),
        ],
      );

  final t0 = DateTime.utc(2026, 1, 1);
  final t1 = DateTime.utc(2026, 1, 2);
  final t2 = DateTime.utc(2026, 1, 3);

  test('union when ids are disjoint', () {
    final merged = mergeRunbooks(
      localRunbooks: [makeRb('a', 'A')],
      localMeta: RunbookSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
      remoteRunbooks: [makeRb('b', 'B')],
      remoteMeta: RunbookSyncMeta(updatedAt: {'b': t0}, tombstones: const {}),
    );
    expect(merged.runbooks.map((r) => r.id).toSet(), {'a', 'b'});
    expect(merged.meta.tombstones, isEmpty);
  });

  test('newer updatedAt wins on conflict', () {
    final merged = mergeRunbooks(
      localRunbooks: [makeRb('a', 'old')],
      localMeta: RunbookSyncMeta(updatedAt: {'a': t1}, tombstones: const {}),
      remoteRunbooks: [makeRb('a', 'new')],
      remoteMeta: RunbookSyncMeta(updatedAt: {'a': t2}, tombstones: const {}),
    );
    expect(merged.runbooks.single.name, 'new');
    expect(merged.meta.updatedAt['a'], t2);
  });

  test('newer tombstone deletes a stale remote entry', () {
    final merged = mergeRunbooks(
      localRunbooks: const [],
      localMeta: RunbookSyncMeta(
        updatedAt: const {},
        tombstones: {'a': t2},
      ),
      remoteRunbooks: [makeRb('a', 'stale')],
      remoteMeta: RunbookSyncMeta(updatedAt: {'a': t1}, tombstones: const {}),
    );
    expect(merged.runbooks, isEmpty);
    expect(merged.meta.tombstones['a'], t2);
  });

  test(
    'deleting a team runbook still uploads its tombstone (so peers see the delete)',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});

      final syncStorage = const SnippetSyncStorage();
      await syncStorage.setEnabled(true);

      final storage = const RunbookStorage();
      const password = 'pin1234';

      // Phase 1 — share a team runbook, run sync, confirm upload.
      await storage.upsert(makeRb('rb1', 'Live'));
      final adapter = _InMemoryAdapter();
      final service = RunbookSyncService(
        syncStorage: syncStorage,
        storage: storage,
        adapterBuilder: (_) => adapter,
        passwordResolver: () async => password,
        debounce: const Duration(milliseconds: 1),
      );
      await service.pushNow();

      expect(
        adapter.store.containsKey(RunbookSyncService.runbooksObjectKey),
        isTrue,
        reason: 'first push should upload the team runbook blob',
      );
      var blob = RunbookSyncBlob.decode(BackupCrypto.decrypt(
        password,
        adapter.store[RunbookSyncService.runbooksObjectKey]!,
      ));
      expect(blob.runbooks.map((r) => r.id), ['rb1']);
      expect(blob.meta.tombstones, isEmpty);

      // Phase 2 — delete the runbook locally, push again. The blob
      // must now contain a tombstone for rb1 so peers don't
      // resurrect it.
      await storage.delete('rb1');
      await service.pushNow();

      blob = RunbookSyncBlob.decode(BackupCrypto.decrypt(
        password,
        adapter.store[RunbookSyncService.runbooksObjectKey]!,
      ));
      expect(blob.runbooks, isEmpty,
          reason: 'no live runbook should be uploaded after delete');
      expect(blob.meta.tombstones.containsKey('rb1'), isTrue,
          reason:
              'tombstone for the deleted team runbook MUST ride the wire');

      // Phase 3 — simulate a peer that still has the stale runbook,
      // merge the blob we just uploaded against its state, and
      // confirm the entry is gone (i.e. the tombstone wins).
      final peerLocal = [makeRb('rb1', 'Live')];
      final peerMerge = mergeRunbooks(
        localRunbooks: peerLocal,
        localMeta: RunbookSyncMeta(
          updatedAt: {'rb1': t0}, // stale local timestamp
          tombstones: const {},
        ),
        remoteRunbooks: blob.runbooks,
        remoteMeta: blob.meta,
      );
      expect(peerMerge.runbooks, isEmpty,
          reason: 'peer must drop the stale entry on next merge');
      expect(peerMerge.meta.tombstones.containsKey('rb1'), isTrue);
    },
  );

  test('untagging team:false uploads a tombstone so the team copy is removed',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});

    final syncStorage = const SnippetSyncStorage();
    await syncStorage.setEnabled(true);
    final storage = const RunbookStorage();
    const password = 'pin1234';

    await storage.upsert(makeRb('rb2', 'Shared'));
    final adapter = _InMemoryAdapter();
    final service = RunbookSyncService(
      syncStorage: syncStorage,
      storage: storage,
      adapterBuilder: (_) => adapter,
      passwordResolver: () async => password,
      debounce: const Duration(milliseconds: 1),
    );
    await service.pushNow();

    // Flip team:false locally — the runbook stays on this device
    // but should disappear from the team channel.
    final shared = (await storage.loadAll()).single;
    await storage.upsert(Runbook(
      id: shared.id,
      name: shared.name,
      team: false,
      steps: shared.steps,
    ));

    await service.pushNow();

    final blob = RunbookSyncBlob.decode(BackupCrypto.decrypt(
      password,
      adapter.store[RunbookSyncService.runbooksObjectKey]!,
    ));
    expect(blob.runbooks, isEmpty,
        reason: 'team:false runbook must NOT be uploaded as live');
    expect(blob.meta.tombstones.containsKey('rb2'), isTrue,
        reason:
            'untagging team must emit a tombstone so peers drop the team copy');
  });

  test('blob round-trips through encode/decode', () {
    final blob = RunbookSyncBlob(
      runbooks: [makeRb('a', 'A')],
      meta: RunbookSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
      deviceId: 'dev-1',
      generatedAt: t0,
    );
    final decoded = RunbookSyncBlob.decode(blob.encode());
    expect(decoded.runbooks.single.name, 'A');
    expect(decoded.deviceId, 'dev-1');
    expect(decoded.meta.updatedAt['a'], t0);
  });
}
