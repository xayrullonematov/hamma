import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A trusted host-key record persisted by [TrustedHostKeyStorage]
/// during a TOFU (trust-on-first-use) host-key acceptance.
///
/// The fingerprint is the OpenSSH-style `SHA256:<base64>` string, and
/// the algorithm is the SSH key algorithm name (`ssh-ed25519`,
/// `ssh-rsa`, `ecdsa-sha2-nistp256`, …).
class TrustedHostKeyRecord {
  const TrustedHostKeyRecord({
    required this.algorithm,
    required this.fingerprint,
  });

  final String algorithm;
  final String fingerprint;

  Map<String, dynamic> toJson() {
    return {
      'algorithm': algorithm,
      'fingerprint': fingerprint,
    };
  }

  factory TrustedHostKeyRecord.fromJson(Map<String, dynamic> json) {
    return TrustedHostKeyRecord(
      algorithm: (json['algorithm'] ?? '').toString(),
      fingerprint: (json['fingerprint'] ?? '').toString(),
    );
  }
}

/// Abstract storage interface for trusted SSH host keys.
///
/// The production implementation is [SecureTrustedHostKeyStorage],
/// which persists records via `flutter_secure_storage`. Tests inject
/// in-memory implementations so they do not require platform
/// channels.
///
/// Implementations must:
///
/// - Return `null` from [loadTrustedHostKey] when no record exists for
///   the given host+port.
/// - Treat host+port pairs as independent (port `22` and port `2222`
///   on the same host are distinct entries).
/// - Throw a [TrustedHostKeyStorageException] (or a subclass) on
///   storage I/O failures so the SSH state machine can surface a
///   user-actionable error instead of an opaque platform exception.
abstract class TrustedHostKeyStorage {
  const TrustedHostKeyStorage();

  /// Returns the trusted record for `host:port`, or `null` when no
  /// record has ever been saved for that endpoint.
  Future<TrustedHostKeyRecord?> loadTrustedHostKey({
    required String host,
    required int port,
  });

  /// Persists [record] as the trusted host key for `host:port`,
  /// overwriting any existing entry.
  Future<void> saveTrustedHostKey({
    required String host,
    required int port,
    required TrustedHostKeyRecord record,
  });
}

/// Production [TrustedHostKeyStorage] implementation backed by
/// `flutter_secure_storage`. Each host+port pair gets its own key in
/// the platform secure store (Keychain on iOS/macOS, Keystore on
/// Android, libsecret on Linux, DPAPI on Windows).
class SecureTrustedHostKeyStorage extends TrustedHostKeyStorage {
  const SecureTrustedHostKeyStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _trustedHostKeyPrefix = 'trusted_host_key_';

  final FlutterSecureStorage _secureStorage;

  @override
  Future<TrustedHostKeyRecord?> loadTrustedHostKey({
    required String host,
    required int port,
  }) async {
    try {
      final rawValue = await _secureStorage.read(
        key: _storageKey(host: host, port: port),
      );
      if (rawValue == null || rawValue.trim().isEmpty) {
        return null;
      }

      final decoded = jsonDecode(rawValue);
      if (decoded is! Map<String, dynamic>) {
        throw const TrustedHostKeyStorageException(
          'Trusted host key data is invalid.',
        );
      }

      return TrustedHostKeyRecord.fromJson(decoded);
    } catch (error) {
      if (error is TrustedHostKeyStorageException) {
        rethrow;
      }

      throw TrustedHostKeyStorageException(
        'Could not load trusted host key: $error',
      );
    }
  }

  @override
  Future<void> saveTrustedHostKey({
    required String host,
    required int port,
    required TrustedHostKeyRecord record,
  }) async {
    try {
      await _secureStorage.write(
        key: _storageKey(host: host, port: port),
        value: jsonEncode(record.toJson()),
      );
    } catch (error) {
      throw TrustedHostKeyStorageException(
        'Could not save trusted host key: $error',
      );
    }
  }

  String _storageKey({
    required String host,
    required int port,
  }) {
    return '$_trustedHostKeyPrefix${Uri.encodeComponent('$host:$port')}';
  }
}

class TrustedHostKeyStorageException implements Exception {
  const TrustedHostKeyStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}
