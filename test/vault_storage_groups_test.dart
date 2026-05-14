import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hamma/core/vault/vault_storage.dart';
import 'package:hamma/core/vault/vault_secret.dart';
import 'package:hamma/core/vault/vault_group.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  
  // Use a fresh mock for each test
  late VaultStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = VaultStorage();
  });

  group('VaultStorage Groups', () {
    test('upsertGroup and loadAllGroups works', () async {
      final group = VaultGroup(
        id: '',
        name: 'Test Group',
        type: CredentialType.postgres,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final saved = await storage.upsertGroup(group);
      expect(saved.id, isNotEmpty);
      expect(saved.name, 'Test Group');

      final all = await storage.loadAllGroups();
      expect(all.length, 1);
      expect(all.first.id, saved.id);
      expect(all.first.name, 'Test Group');
    });

    test('deleteGroup unlinks member secrets', () async {
      final group = await storage.upsertGroup(VaultGroup(
        id: 'g1',
        name: 'G1',
        type: CredentialType.generic,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final secret = await storage.upsert(VaultSecret(
        id: 's1',
        name: 'S1',
        value: 'val',
        updatedAt: DateTime.now(),
        groupId: group.id,
      ));

      expect(secret.groupId, group.id);

      await storage.deleteGroup(group.id);

      final allGroups = await storage.loadAllGroups();
      expect(allGroups, isEmpty);

      final allSecrets = await storage.loadAll();
      expect(allSecrets.length, 1);
      expect(allSecrets.first.groupId, isNull);
    });

    test('loadByGroup filters correctly', () async {
      await storage.upsertGroup(VaultGroup(
        id: 'g1',
        name: 'G1',
        type: CredentialType.generic,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      await storage.upsert(VaultSecret(
        id: 's1',
        name: 'S1',
        value: 'val',
        updatedAt: DateTime.now(),
        groupId: 'g1',
      ));

      await storage.upsert(VaultSecret(
        id: 's2',
        name: 'S2',
        value: 'val',
        updatedAt: DateTime.now(),
        groupId: 'other',
      ));

      final g1Secrets = await storage.loadByGroup('g1');
      expect(g1Secrets.length, 1);
      expect(g1Secrets.first.id, 's1');
    });

    test('applyMergedState handles groups and secrets', () async {
      final secrets = [
        VaultSecret(
          id: 's1',
          name: 'S1',
          value: 'v1',
          updatedAt: DateTime.now(),
        ),
      ];
      final groups = [
        VaultGroup(
          id: 'g1',
          name: 'G1',
          type: CredentialType.awsS3,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      final meta = VaultSyncMeta(
        updatedAt: {'s1': DateTime.now(), 'g1': DateTime.now()},
        tombstones: {},
        groupTombstones: {'old_g': DateTime.now()},
      );

      await storage.applyMergedState(
        secrets: secrets,
        groups: groups,
        meta: meta,
      );

      expect((await storage.loadAll()).length, 1);
      expect((await storage.loadAllGroups()).length, 1);
      
      final savedMeta = await storage.loadSyncMeta();
      expect(savedMeta.groupTombstones, contains('old_g'));
    });
  });
}
