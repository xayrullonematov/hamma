import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

class TrustedHostKeyStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const TrustedHostKeyStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _trustedHostKeyPrefix = 'trusted_host_key_';

  final FlutterSecureStorage _secureStorage;

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
