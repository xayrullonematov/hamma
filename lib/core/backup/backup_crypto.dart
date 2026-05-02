import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as aes;
import 'package:meta/meta.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/argon2.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

/// Encrypts and decrypts Hamma backup blobs.
///
/// File format **v2** (current — written by [encrypt]):
/// ```
/// [magic(4) | version(1) | salt(16) | iv(12) | ciphertext+gcm-tag]
/// ```
/// - **magic**: ASCII `"HMBK"` (Hamma Backup) — `0x48 0x4D 0x42 0x4B`
/// - **version**: `0x02`
/// - **KDF**: Argon2id, m=19456 KiB, t=2, p=1 (OWASP 2024 recommendation)
/// - **Cipher**: AES-256-GCM
/// - **Key length**: 32 bytes (256-bit)
///
/// File format **v1** (legacy — read-only, for backups created before the
/// Argon2id migration):
/// ```
/// [salt(16) | iv(16) | ciphertext+gcm-tag]
/// ```
/// - **KDF**: PBKDF2-HMAC-SHA256, 10,000 iterations
/// - **Cipher**: AES-256-GCM
/// - No magic header — detected by the absence of the v2 magic bytes.
/// - Decryption is supported so users can restore old backups; new backups
///   are always written as v2.
class BackupCrypto {
  BackupCrypto._();

  // ── Format constants ──────────────────────────────────────────────────
  static const List<int> _magic = [0x48, 0x4D, 0x42, 0x4B]; // 'HMBK'
  static const int _versionArgon2id = 0x02;

  static const int _saltLength = 16;
  static const int _gcmIvLength = 12;
  static const int _legacyIvLength = 16;
  static const int _keyLength = 32;
  static const int _gcmTagLength = 16;

  // ── Argon2id parameters (OWASP 2024 recommendation) ───────────────────
  // m=19456 KiB (~19 MiB), t=2, p=1 — balanced for mobile + desktop.
  // Any change here requires a new format version (v3+) to keep existing
  // v2 backups decryptable.
  @visibleForTesting
  static const int argon2Memory = 19456;
  @visibleForTesting
  static const int argon2Iterations = 2;
  @visibleForTesting
  static const int argon2Lanes = 1;

  // ── Legacy PBKDF2 parameters (decrypt-only) ───────────────────────────
  static const int _pbkdf2Iterations = 10000;

  /// Encrypts [plaintext] using [password] and returns a v2 backup blob.
  ///
  /// Throws [BackupCryptoException] if [password] is empty.
  static Uint8List encrypt(String password, Uint8List plaintext) {
    if (password.isEmpty) {
      throw const BackupCryptoException('Password cannot be empty.');
    }

    final salt = _randomBytes(_saltLength);
    final iv = _randomBytes(_gcmIvLength);
    final key = deriveKeyArgon2id(password, salt);

    final encrypter = _aesGcmEncrypter(key);
    final encrypted = encrypter.encryptBytes(plaintext, iv: aes.IV(iv));

    return Uint8List.fromList([
      ..._magic,
      _versionArgon2id,
      ...salt,
      ...iv,
      ...encrypted.bytes,
    ]);
  }

  /// Decrypts a backup [blob] using [password]. Auto-detects v1 (legacy)
  /// and v2 file formats.
  ///
  /// Format detection: blobs that begin with the `HMBK` magic header are
  /// parsed as a versioned backup. If versioned parsing fails, decryption
  /// falls back to the legacy path — this handles the (~1 in 2^32) case
  /// of a legacy backup whose random 16-byte salt happens to begin with
  /// the magic bytes by chance. If both paths fail, the more informative
  /// versioned error is surfaced.
  ///
  /// Throws [BackupCryptoException] on:
  ///  - empty password
  ///  - truncated/corrupted blob
  ///  - wrong password (GCM authentication tag mismatch)
  ///  - tampered ciphertext (also GCM tag mismatch)
  ///  - unknown / future format version
  ///
  /// Wrong-password and tampered-ciphertext errors return the **same**
  /// message to avoid leaking which one occurred.
  static Uint8List decrypt(String password, Uint8List blob) {
    if (password.isEmpty) {
      throw const BackupCryptoException('Password cannot be empty.');
    }
    if (_hasMagicHeader(blob)) {
      try {
        return _decryptVersioned(password, blob);
      } on BackupCryptoException catch (versionedError) {
        // Magic-header collision recovery: try legacy decrypt; if that
        // also fails, the original versioned error is more informative
        // (e.g., "Unsupported version" beats "Incorrect password").
        try {
          return _decryptLegacy(password, blob);
        } catch (_) {
          throw versionedError;
        }
      }
    }
    return _decryptLegacy(password, blob);
  }

  static bool _hasMagicHeader(Uint8List blob) {
    if (blob.length < _magic.length) return false;
    for (int i = 0; i < _magic.length; i++) {
      if (blob[i] != _magic[i]) return false;
    }
    return true;
  }

  static Uint8List _decryptVersioned(String password, Uint8List blob) {
    // [magic(4) | version(1) | salt(16) | iv(12) | ciphertext+tag(16+)]
    const headerLength = 4 + 1 + _saltLength + _gcmIvLength;
    if (blob.length < headerLength + _gcmTagLength) {
      throw const BackupCryptoException('Corrupted backup file.');
    }

    final version = blob[4];
    if (version != _versionArgon2id) {
      throw BackupCryptoException(
        'Unsupported backup format version: $version. '
        'This file may have been created by a newer version of Hamma.',
      );
    }

    final salt = Uint8List.fromList(blob.sublist(5, 5 + _saltLength));
    final iv = Uint8List.fromList(
      blob.sublist(5 + _saltLength, 5 + _saltLength + _gcmIvLength),
    );
    final ciphertext = Uint8List.fromList(blob.sublist(headerLength));

    final key = deriveKeyArgon2id(password, salt);
    return _aesGcmDecrypt(key, iv, ciphertext);
  }

  static Uint8List _decryptLegacy(String password, Uint8List blob) {
    // [salt(16) | iv(16) | ciphertext+tag(16+)]
    const headerLength = _saltLength + _legacyIvLength;
    if (blob.length < headerLength + _gcmTagLength) {
      throw const BackupCryptoException('Corrupted backup file.');
    }

    final salt = Uint8List.fromList(blob.sublist(0, _saltLength));
    final iv = Uint8List.fromList(blob.sublist(_saltLength, headerLength));
    final ciphertext = Uint8List.fromList(blob.sublist(headerLength));

    final key = deriveKeyPbkdf2Legacy(password, salt);
    return _aesGcmDecrypt(key, iv, ciphertext);
  }

  static Uint8List _aesGcmDecrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
  ) {
    final encrypter = _aesGcmEncrypter(key);
    try {
      final plaintext = encrypter.decryptBytes(
        aes.Encrypted(ciphertext),
        iv: aes.IV(iv),
      );
      return Uint8List.fromList(plaintext);
    } catch (_) {
      // Indistinguishable error to avoid leaking whether the password was
      // wrong vs. the ciphertext was tampered with.
      throw const BackupCryptoException(
        'Incorrect password or corrupted file.',
      );
    }
  }

  static aes.Encrypter _aesGcmEncrypter(Uint8List key) {
    return aes.Encrypter(
      aes.AES(aes.Key(key), mode: aes.AESMode.gcm),
    );
  }

  /// Derives a 32-byte AES-256 key from [password] and [salt] using
  /// Argon2id with OWASP-recommended parameters (m=19456 KiB, t=2, p=1).
  @visibleForTesting
  static Uint8List deriveKeyArgon2id(String password, Uint8List salt) {
    final params = Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: _keyLength,
      iterations: argon2Iterations,
      memory: argon2Memory,
      lanes: argon2Lanes,
      version: Argon2Parameters.ARGON2_VERSION_13,
    );
    final argon2 = Argon2BytesGenerator()..init(params);
    return argon2.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// Derives a 32-byte AES-256 key from [password] and [salt] using legacy
  /// PBKDF2-HMAC-SHA256 (10,000 iterations).
  ///
  /// Used only to decrypt backups created before the Argon2id migration.
  /// New backups must use [deriveKeyArgon2id].
  @visibleForTesting
  static Uint8List deriveKeyPbkdf2Legacy(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Hand-builds a v1 (legacy PBKDF2) backup blob. Used **only** by tests
  /// to construct fixtures verifying the legacy decryption path.
  ///
  /// [salt] and [iv] may be supplied to construct deterministic fixtures
  /// (e.g., to simulate the magic-header collision case); when omitted,
  /// random values are used. Production code must not call this — new
  /// backups must be written via [encrypt].
  @visibleForTesting
  static Uint8List encryptLegacy(
    String password,
    Uint8List plaintext, {
    Uint8List? salt,
    Uint8List? iv,
  }) {
    final actualSalt = salt ?? _randomBytes(_saltLength);
    final actualIv = iv ?? _randomBytes(_legacyIvLength);
    assert(actualSalt.length == _saltLength, 'salt must be 16 bytes');
    assert(actualIv.length == _legacyIvLength, 'legacy iv must be 16 bytes');
    final key = deriveKeyPbkdf2Legacy(password, actualSalt);

    final encrypter = _aesGcmEncrypter(key);
    final encrypted = encrypter.encryptBytes(plaintext, iv: aes.IV(actualIv));

    return Uint8List.fromList([
      ...actualSalt,
      ...actualIv,
      ...encrypted.bytes,
    ]);
  }
}

class BackupCryptoException implements Exception {
  const BackupCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}
