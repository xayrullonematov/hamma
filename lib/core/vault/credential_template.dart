import 'vault_group.dart';

/// Pre-defined field name templates for different [CredentialType]s.
///
/// When a user creates a new [VaultGroup] of a specific type, these
/// labels are used to pre-populate the [VaultSecret] names within that
/// group.
class CredentialTemplate {
  static const Map<CredentialType, List<String>> registry = {
    CredentialType.awsS3: [
      'ACCESS_KEY_ID',
      'SECRET_ACCESS_KEY',
      'BUCKET',
      'REGION',
    ],
    CredentialType.awsGeneric: [
      'ACCESS_KEY_ID',
      'SECRET_ACCESS_KEY',
    ],
    CredentialType.postgres: [
      'HOST',
      'PORT',
      'DB_NAME',
      'USER',
      'PASSWORD',
    ],
    CredentialType.mysql: [
      'HOST',
      'PORT',
      'DB_NAME',
      'USER',
      'PASSWORD',
    ],
    CredentialType.stripe: [
      'PUBLISHABLE_KEY',
      'SECRET_KEY',
      'WEBHOOK_SECRET',
    ],
    CredentialType.github: [
      'TOKEN',
      'WEBHOOK_SECRET',
    ],
    CredentialType.sshKey: [
      'PRIVATE_KEY',
      'PASSPHRASE',
      'HOST',
      'USER',
    ],
    CredentialType.apiKey: [
      'API_KEY',
      'API_SECRET',
      'BASE_URL',
    ],
    CredentialType.generic: [],
  };
}
