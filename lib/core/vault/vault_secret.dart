import 'package:meta/meta.dart';

/// A single named secret in Hamma's per-server / global vault.
///
/// `value` is the plaintext secret. It only ever lives in memory between
/// the moment [VaultStorage] decrypts it from secure storage and the
/// moment it is either substituted into an SSH command or compared
/// against a string by the [VaultRedactor]. Callers must never persist
/// or log it.
///
/// `scope` is `null` for a global secret (visible to every server) or
/// the server profile id for a per-server secret.
@immutable
class VaultSecret {
  const VaultSecret({
    required this.id,
    required this.name,
    required this.value,
    this.scope,
    this.description = '',
    required this.updatedAt,
  });

  /// Stable id assigned at create-time. Used as the merge key for sync
  /// and as the storage key inside `flutter_secure_storage`.
  final String id;

  /// User-facing name. Becomes the `${vault:NAME}` placeholder and is
  /// shown in the redaction marker (`••••••• (vault: NAME)`). Names
  /// are unique within a scope and are normalised to upper-snake-case
  /// (`DB_PASSWORD`) by [VaultStorage] on save.
  final String name;

  /// Plaintext value. Treat as sensitive — never log or persist outside
  /// of [VaultStorage].
  final String value;

  /// `null` for a global secret; otherwise the server profile id this
  /// secret is bound to. The injector and redactor scope by this field.
  final String? scope;

  /// Optional free-text reminder ("rotate Q1 2026"). Not redacted, not
  /// substituted — purely cosmetic.
  final String description;

  final DateTime updatedAt;

  bool get isGlobal => scope == null;

  /// Validity of name + value pair before persistence.
  ///
  /// A secret is invalid when:
  ///  - the name is blank, or contains characters that would break the
  ///    `${vault:NAME}` placeholder grammar (we restrict to
  ///    `[A-Za-z0-9_]+` and require a leading letter or underscore so
  ///    the placeholder can't collide with a digit-prefixed identifier
  ///    that some shells reject), or
  ///  - the value is empty (an empty secret is always a bug — it would
  ///    silently expand to a literal empty string at the SSH boundary).
  bool get isValid {
    if (value.isEmpty) return false;
    final n = name.trim();
    if (n.isEmpty) return false;
    return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n);
  }

  VaultSecret copyWith({
    String? id,
    String? name,
    String? value,
    Object? scope = _scopeSentinel,
    String? description,
    DateTime? updatedAt,
  }) {
    return VaultSecret(
      id: id ?? this.id,
      name: name ?? this.name,
      value: value ?? this.value,
      scope: identical(scope, _scopeSentinel) ? this.scope : scope as String?,
      description: description ?? this.description,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'value': value,
        'scope': scope,
        'description': description,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory VaultSecret.fromJson(Map<String, dynamic> json) {
    return VaultSecret(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      value: (json['value'] ?? '').toString(),
      scope: json['scope']?.toString(),
      description: (json['description'] ?? '').toString(),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static const Object _scopeSentinel = Object();
}
