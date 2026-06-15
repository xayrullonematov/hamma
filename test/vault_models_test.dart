import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_secret.dart';
import 'package:hamma/core/vault/vault_group.dart';

void main() {
  group('VaultSecret', () {
    test('fromJson handles missing new fields (backward compatibility)', () {
      final json = {
        'id': '123',
        'name': 'DB_PASSWORD',
        'value': 'secret123',
        'updatedAt': '2026-05-12T10:00:00.000Z',
      };

      final secret = VaultSecret.fromJson(json);

      expect(secret.id, '123');
      expect(secret.name, 'DB_PASSWORD');
      expect(secret.value, 'secret123');
      expect(secret.groupId, isNull);
      expect(secret.lastUsedAt, isNull);
      expect(secret.rotateBy, isNull);
    });

    test('toJson and fromJson roundtrip with all fields', () {
      final now = DateTime.now().toUtc();
      final lastUsed = now.subtract(const Duration(days: 1));
      final rotate = now.add(const Duration(days: 30));

      final secret = VaultSecret(
        id: '456',
        name: 'API_KEY',
        value: 'key123',
        updatedAt: now,
        groupId: 'group789',
        lastUsedAt: lastUsed,
        rotateBy: rotate,
      );

      final json = secret.toJson();
      final decoded = VaultSecret.fromJson(json);

      expect(decoded.id, '456');
      expect(decoded.name, 'API_KEY');
      expect(decoded.value, 'key123');
      expect(decoded.groupId, 'group789');
      // DateTime parsing might lose some precision, but ISO8601 should be fine for ms/us
      expect(decoded.lastUsedAt?.toIso8601String(), lastUsed.toIso8601String());
      expect(decoded.rotateBy?.toIso8601String(), rotate.toIso8601String());
    });

    test('copyWith works with new fields', () {
      final secret = VaultSecret(
        id: '1',
        name: 'A',
        value: 'B',
        updatedAt: DateTime.now(),
      );

      final updated = secret.copyWith(
        groupId: 'G1',
        lastUsedAt: DateTime(2026, 1, 1),
      );

      expect(updated.groupId, 'G1');
      expect(updated.lastUsedAt, DateTime(2026, 1, 1));
      expect(updated.rotateBy, isNull);

      final cleared = updated.copyWith(groupId: null);
      expect(cleared.groupId, isNull);
    });
  });

  group('VaultGroup', () {
    test('icon is auto-derived from type', () {
      final groupS3 = VaultGroup(
        id: '1',
        name: 'S3',
        type: CredentialType.awsS3,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(groupS3.icon, 'cloud');

      final groupPg = VaultGroup(
        id: '2',
        name: 'DB',
        type: CredentialType.postgres,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(groupPg.icon, 'storage');
    });

    test('toJson and fromJson roundtrip', () {
      final group = VaultGroup(
        id: 'g1',
        name: 'My Group',
        type: CredentialType.stripe,
        tags: ['prod', 'billing'],
        notes: 'Important notes',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      final json = group.toJson();
      final decoded = VaultGroup.fromJson(json);

      expect(decoded.id, 'g1');
      expect(decoded.name, 'My Group');
      expect(decoded.type, CredentialType.stripe);
      expect(decoded.tags, ['prod', 'billing']);
      expect(decoded.notes, 'Important notes');
    });
  });

}
