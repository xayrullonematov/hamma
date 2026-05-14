import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_search.dart';
import 'package:hamma/core/vault/vault_group.dart';
import 'package:hamma/core/vault/vault_secret.dart';

void main() {
  group('VaultSearchIndex', () {
    final groups = [
      VaultGroup(
        id: 'g1',
        name: 'AWS Production',
        type: CredentialType.awsS3,
        tags: ['prod', 'cloud'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      VaultGroup(
        id: 'g2',
        name: 'Stripe Billing',
        type: CredentialType.stripe,
        tags: ['billing'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ];

    final secrets = [
      VaultSecret(
        id: 's1',
        name: 'ACCESS_KEY_ID',
        value: 'AKIA...',
        updatedAt: DateTime.now(),
        groupId: 'g1',
      ),
      VaultSecret(
        id: 's2',
        name: 'PERSONAL_TOKEN',
        value: 'ghp_...',
        updatedAt: DateTime.now(),
        groupId: null,
      ),
    ];

    final index = VaultSearchIndex();
    index.buildIndex(groups, secrets);

    test('search matches group name', () {
      final results = index.search('production');
      expect(results.length, 1);
      expect(results.first.groupId, 'g1');
      expect(results.first.matchedOn, VaultMatchSource.groupName);
    });

    test('search matches tag', () {
      final results = index.search('billing');
      // Matches both group name "Stripe Billing" and tag "billing"
      expect(results.any((r) => r.matchedOn == VaultMatchSource.tag), isTrue);
      expect(results.any((r) => r.matchedOn == VaultMatchSource.groupName), isTrue);
      expect(results.map((r) => r.groupId).toSet(), contains('g2'));
    });

    test('search matches field name in group', () {
      final results = index.search('ACCESS_KEY');
      expect(results.length, 1);
      expect(results.first.groupId, 'g1');
      expect(results.first.secretId, 's1');
      expect(results.first.matchedOn, VaultMatchSource.fieldName);
    });

    test('search matches ungrouped secret name', () {
      final results = index.search('PERSONAL');
      expect(results.length, 1);
      expect(results.first.secretId, 's2');
      expect(results.first.groupId, isNull);
      expect(results.first.matchedOn, VaultMatchSource.secretName);
    });

    test('filter by type', () {
      final filtered = index.filter(CredentialType.stripe, null, null);
      expect(filtered.length, 1);
      expect(filtered.first.id, 'g2');
    });

    test('filter by tag', () {
      final filtered = index.filter(null, 'prod', null);
      expect(filtered.length, 1);
      expect(filtered.first.id, 'g1');
    });
  });
}
