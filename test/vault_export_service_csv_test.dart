import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_export_service.dart';
import 'package:hamma/core/vault/vault_group.dart';
import 'package:hamma/core/vault/vault_secret.dart';
import 'package:hamma/core/vault/vault_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VaultExportService - exportToCsv', () {
    late VaultStorage storage;
    late VaultExportService service;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      storage = VaultStorage();
      service = VaultExportService(storage: storage);
    });

    test('exports secrets to CSV with correct headers and data', () async {
      final now = DateTime.utc(2023, 1, 1);
      final group = await storage.upsertGroup(VaultGroup(
        id: 'g1',
        name: 'Test Group',
        type: CredentialType.generic,
        createdAt: now,
        updatedAt: now,
      ));

      // Need to capture the saved secret because upsert changes updatedAt sometimes depending on storage logic
      final savedSecret = await storage.upsert(VaultSecret(
        id: 's1',
        name: 'TEST_SECRET',
        value: 'secret-value',
        groupId: group.id,
        updatedAt: now,
      ));

      final csvData = await service.exportToCsv();

      expect(csvData, isNotEmpty);
      final lines = csvData.trim().split('\n');
      expect(lines.length, 2); // 1 header + 1 row

      expect(lines[0], 'ID,Name,Value,Group ID,Updated At');

      final expectedRow = 's1,TEST_SECRET,secret-value,Test Group,${savedSecret.updatedAt.toUtc().toIso8601String()}';
      expect(lines[1], expectedRow);
    });

    test('handles secrets with missing groups correctly', () async {
      final now = DateTime.utc(2023, 1, 1);
      final savedSecret = await storage.upsert(VaultSecret(
        id: 's1',
        name: 'ORPHAN_SECRET',
        value: 'orphan-value',
        groupId: 'non-existent-group',
        updatedAt: now,
      ));

      final csvData = await service.exportToCsv();

      final lines = csvData.trim().split('\n');
      expect(lines.length, 2);

      final expectedRow = 's1,ORPHAN_SECRET,orphan-value,non-existent-group,${savedSecret.updatedAt.toUtc().toIso8601String()}';
      expect(lines[1], expectedRow);
    });

    test('escapes CSV values correctly', () async {
      final now = DateTime.utc(2023, 1, 1);
      await storage.upsert(VaultSecret(
        id: 's1',
        name: 'SECRET_WITH_NEWLINES',
        value: 'value\nwith\nnewlines, and "quotes"',
        updatedAt: now,
      ));

      final csvData = await service.exportToCsv();

      // The output will have newlines inside the CSV value, so splitting by \n is not sufficient
      // But we can check if it escapes correctly
      expect(csvData, contains('SECRET_WITH_NEWLINES'));
      expect(csvData, contains('"value\nwith\nnewlines, and ""quotes"""'));
    });
  });
}
