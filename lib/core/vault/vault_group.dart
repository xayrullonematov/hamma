import 'package:meta/meta.dart';

enum CredentialType {
  awsS3,
  awsGeneric,
  postgres,
  mysql,
  stripe,
  github,
  sshKey,
  apiKey,
  generic,
}

/// A collection of related secrets (e.g. all the fields for a single
/// database or cloud provider credential).
@immutable
class VaultGroup {
  const VaultGroup({
    required this.id,
    required this.name,
    required this.type,
    this.tags = const [],
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final CredentialType type;
  final List<String> tags;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Returns a Material Icon name based on the credential type.
  String get icon {
    switch (type) {
      case CredentialType.awsS3:
        return 'cloud';
      case CredentialType.awsGeneric:
        return 'cloud_queue';
      case CredentialType.postgres:
        return 'storage';
      case CredentialType.mysql:
        return 'dns';
      case CredentialType.stripe:
        return 'payments';
      case CredentialType.github:
        return 'code';
      case CredentialType.sshKey:
        return 'vpn_key';
      case CredentialType.apiKey:
        return 'api';
      case CredentialType.generic:
        return 'enhanced_encryption';
    }
  }

  VaultGroup copyWith({
    String? id,
    String? name,
    CredentialType? type,
    List<String>? tags,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return VaultGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      tags: tags ?? this.tags,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'tags': tags,
        if (notes != null) 'notes': notes,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory VaultGroup.fromJson(Map<String, dynamic> json) {
    return VaultGroup(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      type: CredentialType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => CredentialType.generic,
      ),
      tags: (json['tags'] as List?)?.cast<String>() ?? const [],
      notes: json['notes']?.toString(),
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}
