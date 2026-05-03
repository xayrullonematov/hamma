import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/sync/vault_sync_service.dart';
import 'package:hamma/core/vault/vault_secret.dart';
import 'package:hamma/core/vault/vault_storage.dart';

VaultSecret _s(String id, String name, String value, DateTime t) =>
    VaultSecret(
      id: id,
      name: name,
      value: value,
      updatedAt: t,
    );

void main() {
  group('mergeVaults — newest-wins with tombstones', () {
    final t0 = DateTime.utc(2026, 1, 1);
    final t1 = DateTime.utc(2026, 1, 2);
    final t2 = DateTime.utc(2026, 1, 3);

    test('takes the newer of two updates to the same id', () {
      final result = mergeVaults(
        localSecrets: [_s('a', 'A', 'old', t0)],
        localMeta: VaultSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
        remoteSecrets: [_s('a', 'A', 'new', t2)],
        remoteMeta: VaultSyncMeta(updatedAt: {'a': t2}, tombstones: const {}),
      );
      expect(result.secrets.single.value, 'new');
      expect(result.meta.updatedAt['a'], t2);
    });

    test('a tombstone newer than a value deletes the secret', () {
      final result = mergeVaults(
        localSecrets: [_s('a', 'A', 'val', t0)],
        localMeta: VaultSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
        remoteSecrets: const [],
        remoteMeta:
            VaultSyncMeta(updatedAt: const {}, tombstones: {'a': t1}),
      );
      expect(result.secrets, isEmpty);
      expect(result.meta.tombstones['a'], t1);
    });

    test('a value newer than a tombstone resurrects the secret', () {
      final result = mergeVaults(
        localSecrets: [_s('a', 'A', 'fresh', t2)],
        localMeta: VaultSyncMeta(updatedAt: {'a': t2}, tombstones: const {}),
        remoteSecrets: const [],
        remoteMeta:
            VaultSyncMeta(updatedAt: const {}, tombstones: {'a': t1}),
      );
      expect(result.secrets.single.value, 'fresh');
      expect(result.meta.updatedAt['a'], t2);
      expect(result.meta.tombstones, isEmpty);
    });

    test('disjoint local + remote ids both survive', () {
      final result = mergeVaults(
        localSecrets: [_s('a', 'A', 'va', t0)],
        localMeta: VaultSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
        remoteSecrets: [_s('b', 'B', 'vb', t1)],
        remoteMeta: VaultSyncMeta(updatedAt: {'b': t1}, tombstones: const {}),
      );
      expect(result.secrets.map((s) => s.id).toSet(), {'a', 'b'});
    });
  });
}
