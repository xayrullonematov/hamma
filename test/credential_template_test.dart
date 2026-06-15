import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/credential_template.dart';
import 'package:hamma/core/vault/vault_group.dart';

void main() {
  group('CredentialTemplate', () {
    test('registry contains all CredentialType values', () {
      // Ensure that every value in the CredentialType enum has an entry in the registry
      for (final type in CredentialType.values) {
        expect(CredentialTemplate.registry.containsKey(type), isTrue,
            reason: 'Missing template for $type');
      }
    });

    test('registry has exactly the expected keys', () {
      // Ensure there are no extra keys in the registry that aren't in the enum
      expect(
        CredentialTemplate.registry.keys.length,
        equals(CredentialType.values.length),
      );
    });

    group('individual credential types have expected fields', () {
      test('awsS3 has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.awsS3],
          equals(['ACCESS_KEY_ID', 'SECRET_ACCESS_KEY', 'BUCKET', 'REGION']),
        );
      });

      test('awsGeneric has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.awsGeneric],
          equals(['ACCESS_KEY_ID', 'SECRET_ACCESS_KEY']),
        );
      });

      test('postgres has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.postgres],
          equals(['HOST', 'PORT', 'DB_NAME', 'USER', 'PASSWORD']),
        );
      });

      test('mysql has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.mysql],
          equals(['HOST', 'PORT', 'DB_NAME', 'USER', 'PASSWORD']),
        );
      });

      test('stripe has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.stripe],
          equals(['PUBLISHABLE_KEY', 'SECRET_KEY', 'WEBHOOK_SECRET']),
        );
      });

      test('github has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.github],
          equals(['TOKEN', 'WEBHOOK_SECRET']),
        );
      });

      test('sshKey has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.sshKey],
          equals(['PRIVATE_KEY', 'PASSPHRASE', 'HOST', 'USER']),
        );
      });

      test('apiKey has required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.apiKey],
          equals(['API_KEY', 'API_SECRET', 'BASE_URL']),
        );
      });

      test('generic has no required fields', () {
        expect(
          CredentialTemplate.registry[CredentialType.generic],
          isEmpty,
        );
      });
    });

    test('fields are not null or empty strings', () {
      for (final fields in CredentialTemplate.registry.values) {
        for (final field in fields) {
          expect(field, isNotEmpty);
          expect(field.trim(), equals(field), reason: 'Field names should not have leading/trailing whitespace');
        }
      }
    });
  });
}
