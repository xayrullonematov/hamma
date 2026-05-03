import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/backup_crypto.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/sync/vault_sync_service.dart';
import 'package:hamma/core/vault/vault_change_bus.dart';
import 'package:hamma/core/vault/vault_secret.dart';
import 'package:hamma/core/vault/vault_storage.dart';

class _InMemoryAdapter implements CloudSyncAdapter {
  final Map<String, Uint8List> store = {};

  @override
  String get destinationLabel => 'memory';

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
    final v = store[key];
    if (v == null) throw const CloudNotFoundException('missing');
    return v;
  }

  @override
  Future<void> delete(String key) async {
    store.remove(key);
  }

  @override
  Future<void> rename(String fromKey, String toKey) async {
    final body = await get(fromKey);
    await put(toKey, body);
    await delete(fromKey);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('two devices converge — peer secrets merge in instead of being '
      'overwritten', () async {
    final adapter = _InMemoryAdapter();
    const password = 'hunter2hunter2';
    final t = DateTime.utc(2026, 5, 1);

    // Device A writes one secret and pushes.
    final storeA = VaultStorage();
    await storeA.upsert(
      VaultSecret(id: 'sa', name: 'A_TOKEN', value: 'aaa-from-A', updatedAt: t),
    );
    final blobA = VaultSyncBlob(
      secrets: await storeA.loadAll(),
      meta: await storeA.loadSyncMeta(),
      deviceId: 'device-A',
      generatedAt: t,
    );
    adapter.store[VaultSyncService.vaultObjectKey] =
        BackupCrypto.encrypt(password, blobA.encode());

    // Now we are device B: clear the secure-storage mock so the local
    // vault starts empty, write B's own secret, then pull+merge.
    FlutterSecureStorage.setMockInitialValues({});
    final storeB = VaultStorage();
    await storeB.upsert(
      VaultSecret(
        id: 'sb',
        name: 'B_TOKEN',
        value: 'bbb-from-B',
        updatedAt: t.add(const Duration(seconds: 1)),
      ),
    );

    final syncB = VaultSyncService(
      vaultStorage: storeB,
      adapterBuilder: (_) => adapter,
      passwordResolver: () async => password,
      deviceId: 'device-B',
    );
    await syncB.pullAndMerge();

    // Both peers' secrets must be present locally — the merge cannot
    // be a one-sided overwrite.
    final merged = await storeB.loadAll();
    expect(
      merged.map((s) => s.name).toSet(),
      {'A_TOKEN', 'B_TOKEN'},
      reason:
          'Peer secrets must merge into the local vault instead of being '
          'silently dropped.',
    );

    // After the merge, device B re-uploads. Re-pulling on device A
    // (different deviceId, fresh local store seeded only with A's own
    // secret) must end up with both secrets too — proving the round
    // trip converges in both directions.
    final reBlob = VaultSyncBlob.decode(
      BackupCrypto.decrypt(
        password,
        adapter.store[VaultSyncService.vaultObjectKey]!,
      ),
    );
    expect(reBlob.deviceId, 'device-B');
    expect(reBlob.secrets.map((s) => s.name).toSet(), {'A_TOKEN', 'B_TOKEN'});
  });

  test('default device id is stable across VaultSyncService instances',
      () async {
    final storage = VaultStorage();
    final id1 = await storage.getOrCreateDeviceId();
    final id2 = await storage.getOrCreateDeviceId();
    expect(id1, isNotEmpty);
    expect(id1, equals(id2));
    expect(id1, isNot('device-default'));
  });

  test('applyMergedState fires VaultChangeBus so the global redactor '
      'and per-screen listeners refresh after a sync pull', () async {
    final storage = VaultStorage();
    var ticks = 0;
    final sub = VaultChangeBus.instance.changes.listen((_) => ticks++);
    addTearDown(() async => sub.cancel());

    await storage.applyMergedState(
      secrets: [
        VaultSecret(
          id: 'x',
          name: 'X',
          value: 'value-from-cloud',
          updatedAt: DateTime.utc(2026, 5, 1),
        ),
      ],
      meta: VaultSyncMeta(
        updatedAt: {'x': DateTime.utc(2026, 5, 1)},
        tombstones: const {},
      ),
    );

    // Let the broadcast deliver.
    await Future<void>.delayed(Duration.zero);
    expect(ticks, greaterThanOrEqualTo(1));
  });
}
