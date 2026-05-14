import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_export_service.dart';
import 'package:hamma/core/vault/vault_group.dart';
import 'package:hamma/core/vault/vault_secret.dart';
import 'package:hamma/core/vault/vault_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VaultExportService', () {
    late VaultStorage storage;
    late VaultExportService service;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      storage = VaultStorage();
      service = VaultExportService(storage: storage);
    });

    test('export and import round-trip', () async {
      final now = DateTime.now();
      final group = await storage.upsertGroup(VaultGroup(
        id: '',
        name: 'Test Group',
        type: CredentialType.generic,
        createdAt: now,
        updatedAt: now,
      ));

      await storage.upsert(VaultSecret(
        id: '',
        name: 'TEST_SECRET',
        value: 'secret-value',
        groupId: group.id,
        updatedAt: now,
      ));

      const passphrase = 'test-passphrase-123456';
      final exportData = await service.export(passphrase);

      expect(exportData, isNotEmpty);
      expect(exportData.sublist(0, 4), [0x48, 0x4D, 0x56, 0x54]); // 'HMVT'

      // Clear storage
      FlutterSecureStorage.setMockInitialValues({});
      storage = VaultStorage();
      service = VaultExportService(storage: storage);

      final result = await service.import(exportData, passphrase);

      expect(result.imported, 2); // 1 group + 1 secret
      
      final secrets = await storage.loadAll();
      expect(secrets.length, 1);
      expect(secrets.first.name, 'TEST_SECRET');
      expect(secrets.first.value, 'secret-value');
      
      final groups = await storage.loadAllGroups();
      expect(groups.length, 1);
      expect(groups.first.name, 'Test Group');
    });

    test('import newest-wins merge', () async {
      await storage.upsert(VaultSecret(
        id: 's1',
        name: 'SECRET',
        value: 'old-value',
        updatedAt: DateTime.now().subtract(const Duration(days: 1)),
      ));

      const passphrase = 'test';
      final exportData = await service.export(passphrase);

      // Update local to be newer
      await storage.upsert(VaultSecret(
        id: 's1',
        name: 'SECRET',
        value: 'new-local-value',
        updatedAt: DateTime.now(),
      ));

      final result = await service.import(exportData, passphrase);
      
      expect(result.skipped, 1);
      expect(result.imported, 0);

      final current = await storage.loadAll();
      expect(current.first.value, 'new-local-value');
    });

    test('throws on incorrect passphrase', () async {
      await storage.upsert(VaultSecret(
        id: 's1',
        name: 'SECRET',
        value: 'value',
        updatedAt: DateTime.now(),
      ));

      final data = await service.export('correct-pass');
      
      expect(
        () => service.import(data, 'wrong-pass'),
        throwsA(isA<VaultExportException>()),
      );
    });
  });
}
