import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/backup_crypto.dart';

void main() {
  // Argon2id with m=19456 KiB / t=2 / p=1 takes roughly 0.2–1 s per
  // operation depending on the host. Round-trip and KDF tests run real
  // crypto so the suite ends up in the 5–15 s range.

  group('BackupCrypto.encrypt / decrypt — round-trip (v2 / Argon2id)', () {
    test('round-trips a small text payload', () {
      final plaintext = Uint8List.fromList(utf8.encode('hello world'));
      final blob = BackupCrypto.encrypt('correct horse battery staple', plaintext);
      final restored = BackupCrypto.decrypt('correct horse battery staple', blob);
      expect(restored, equals(plaintext));
    });

    test('round-trips a JSON payload typical of a real backup', () {
      final json = jsonEncode({
        'server_prod': '{"host":"10.0.0.1","port":22,"username":"admin"}',
        'server_staging': '{"host":"10.0.0.2","port":2222,"username":"deploy"}',
        'pin': '1234',
        'aiKey': 'sk-test-deadbeef',
        'trustedHostKey_10.0.0.1': 'ssh-rsa AAAAB3NzaC1...',
      });
      final plaintext = Uint8List.fromList(utf8.encode(json));
      final blob = BackupCrypto.encrypt('p@ssw0rd!', plaintext);
      final restored = BackupCrypto.decrypt('p@ssw0rd!', blob);
      expect(utf8.decode(restored), json);
    });

    test('round-trips arbitrary binary data (not just UTF-8 text)', () {
      final plaintext = Uint8List.fromList(
        List<int>.generate(512, (i) => i % 256),
      );
      final blob = BackupCrypto.encrypt('pw', plaintext);
      final restored = BackupCrypto.decrypt('pw', blob);
      expect(restored, equals(plaintext));
    });

    test('produces blob with HMBK magic header and version=0x02 byte', () {
      final blob = BackupCrypto.encrypt(
        'pw',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(blob[0], 0x48, reason: 'magic byte 0 must be H');
      expect(blob[1], 0x4D, reason: 'magic byte 1 must be M');
      expect(blob[2], 0x42, reason: 'magic byte 2 must be B');
      expect(blob[3], 0x4B, reason: 'magic byte 3 must be K');
      expect(blob[4], 0x02, reason: 'current format version is v2');
    });

    test('produces different ciphertext for the same plaintext (random salt+iv)', () {
      // Random salt and IV per encryption — repeated calls must never
      // produce identical blobs, even with identical password+plaintext.
      final plaintext = Uint8List.fromList(utf8.encode('same text'));
      final blob1 = BackupCrypto.encrypt('pw', plaintext);
      final blob2 = BackupCrypto.encrypt('pw', plaintext);
      expect(blob1, isNot(equals(blob2)));
    });

    test('produces blob of expected minimum size', () {
      // 4 magic + 1 version + 16 salt + 12 iv + 16 GCM tag = 49 bytes
      // for an empty payload.
      final blob = BackupCrypto.encrypt('pw', Uint8List(0));
      expect(blob.length, greaterThanOrEqualTo(49));
    });
  });

  group('BackupCrypto.decrypt — failure modes (no info leak)', () {
    test('rejects wrong password with indistinguishable error message', () {
      final blob = BackupCrypto.encrypt(
        'right-password',
        Uint8List.fromList(utf8.encode('secret')),
      );
      expect(
        () => BackupCrypto.decrypt('wrong-password', blob),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Incorrect password or corrupted file.',
          ),
        ),
      );
    });

    test('rejects tampered ciphertext with the same error as wrong password', () {
      // GCM auth tag verification must fail closed and produce the same
      // user-visible error as wrong-password (no information leak).
      final blob = BackupCrypto.encrypt(
        'pw',
        Uint8List.fromList(utf8.encode('payload')),
      );
      final tampered = Uint8List.fromList(blob);
      tampered[tampered.length - 1] ^= 0xFF;

      expect(
        () => BackupCrypto.decrypt('pw', tampered),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Incorrect password or corrupted file.',
          ),
        ),
      );
    });

    test('rejects truncated v2 blob below minimum length', () {
      final blob = BackupCrypto.encrypt(
        'pw',
        Uint8List.fromList(utf8.encode('payload')),
      );
      final truncated = Uint8List.fromList(blob.sublist(0, 40));

      expect(
        () => BackupCrypto.decrypt('pw', truncated),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Corrupted backup file.',
          ),
        ),
      );
    });

    test('rejects empty password on encrypt', () {
      expect(
        () => BackupCrypto.encrypt('', Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Password cannot be empty.',
          ),
        ),
      );
    });

    test('rejects empty password on decrypt', () {
      expect(
        () => BackupCrypto.decrypt('', Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Password cannot be empty.',
          ),
        ),
      );
    });

    test('rejects unknown / future format version with clear message', () {
      // Forward compat: a v3 file shouldn't be silently mis-decrypted with
      // v2 logic. Bump the version byte and confirm we get a clear error.
      final blob = BackupCrypto.encrypt(
        'pw',
        Uint8List.fromList(utf8.encode('payload')),
      );
      final futureBlob = Uint8List.fromList(blob);
      futureBlob[4] = 0x99;

      expect(
        () => BackupCrypto.decrypt('pw', futureBlob),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Unsupported backup format version'),
              contains('153'), // 0x99
            ),
          ),
        ),
      );
    });
  });

  group('BackupCrypto — legacy v1 (PBKDF2) decryption path', () {
    test('decrypts a hand-crafted v1 backup blob (migration path)', () {
      // Simulates a backup created by the pre-Argon2id version of Hamma.
      // Critical: the new code must still be able to restore these.
      final plaintext = utf8.encode('legacy SSH credentials payload');
      final legacyBlob = BackupCrypto.encryptLegacy(
        'old-pin',
        Uint8List.fromList(plaintext),
      );

      final restored = BackupCrypto.decrypt('old-pin', legacyBlob);
      expect(restored, equals(plaintext));
    });

    test('decrypts a legacy blob whose salt collides with HMBK magic + v2', () {
      // Worst-case format-detection collision: a v1 backup's random
      // 16-byte salt happens to begin with `HMBK` followed by 0x02 (the
      // current v2 version byte). Probability ~1/2^40 in real usage,
      // but the decrypt path must still recover such files via the
      // legacy fallback. Construct it deterministically.
      final plaintext = utf8.encode('legacy payload despite magic collision');
      final collisionSalt = Uint8List.fromList([
        0x48, 0x4D, 0x42, 0x4B, 0x02, // HMBK + version-2 byte
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0,
      ]);
      final iv = Uint8List.fromList(List<int>.generate(16, (i) => i ^ 0xAA));

      final legacyBlob = BackupCrypto.encryptLegacy(
        'collision-pin',
        Uint8List.fromList(plaintext),
        salt: collisionSalt,
        iv: iv,
      );

      // Confirm the fixture really does collide with the v2 header.
      expect(legacyBlob[0], 0x48);
      expect(legacyBlob[4], 0x02);

      final restored = BackupCrypto.decrypt('collision-pin', legacyBlob);
      expect(restored, equals(plaintext),
          reason: 'magic-header collision must fall back to legacy decrypt');
    });

    test('decrypts a legacy blob whose salt collides with HMBK + unknown version', () {
      // Same collision, but the salt's 5th byte is an unrecognized
      // version. The versioned path will throw "Unsupported version",
      // and the fallback to legacy must still succeed.
      final plaintext = utf8.encode('legacy payload, unknown version byte');
      final collisionSalt = Uint8List.fromList([
        0x48, 0x4D, 0x42, 0x4B, 0x99, // HMBK + future/unknown version
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
      ]);
      final iv = Uint8List.fromList(List<int>.generate(16, (i) => i));

      final legacyBlob = BackupCrypto.encryptLegacy(
        'collision-pin',
        Uint8List.fromList(plaintext),
        salt: collisionSalt,
        iv: iv,
      );

      final restored = BackupCrypto.decrypt('collision-pin', legacyBlob);
      expect(restored, equals(plaintext));
    });

    test('legacy blob with wrong password fails with the same error', () {
      final legacyBlob = BackupCrypto.encryptLegacy(
        'right',
        Uint8List.fromList(utf8.encode('secret')),
      );

      expect(
        () => BackupCrypto.decrypt('wrong', legacyBlob),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Incorrect password or corrupted file.',
          ),
        ),
      );
    });

    test('round-trips a JSON payload through the legacy path', () {
      // End-to-end migration test: encrypt the way the old app did, then
      // decrypt the way the new app does.
      final json = jsonEncode({
        'server_1': '{"host":"old.example.com","port":22}',
        'pin': '0000',
      });
      final plaintext = Uint8List.fromList(utf8.encode(json));

      final legacyBlob = BackupCrypto.encryptLegacy('migration-pin', plaintext);
      final restored = BackupCrypto.decrypt('migration-pin', legacyBlob);

      expect(utf8.decode(restored), json);
    });

    test('rejects truncated legacy blob', () {
      final legacyBlob = BackupCrypto.encryptLegacy(
        'pw',
        Uint8List.fromList(utf8.encode('payload')),
      );
      final truncated = Uint8List.fromList(legacyBlob.sublist(0, 40));

      expect(
        () => BackupCrypto.decrypt('pw', truncated),
        throwsA(
          isA<BackupCryptoException>().having(
            (e) => e.message,
            'message',
            'Corrupted backup file.',
          ),
        ),
      );
    });
  });

  group('BackupCrypto.deriveKeyArgon2id — KDF properties', () {
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));

    test('produces deterministic output for the same input', () {
      final k1 = BackupCrypto.deriveKeyArgon2id('password', salt);
      final k2 = BackupCrypto.deriveKeyArgon2id('password', salt);
      expect(k1, equals(k2));
    });

    test('produces a 32-byte (256-bit) key', () {
      final key = BackupCrypto.deriveKeyArgon2id('pw', salt);
      expect(key.length, 32);
    });

    test('different salts produce different keys', () {
      final salt1 = Uint8List.fromList(List<int>.generate(16, (_) => 0x01));
      final salt2 = Uint8List.fromList(List<int>.generate(16, (_) => 0x02));
      final k1 = BackupCrypto.deriveKeyArgon2id('pw', salt1);
      final k2 = BackupCrypto.deriveKeyArgon2id('pw', salt2);
      expect(k1, isNot(equals(k2)));
    });

    test('different passwords produce different keys', () {
      final k1 = BackupCrypto.deriveKeyArgon2id('alpha', salt);
      final k2 = BackupCrypto.deriveKeyArgon2id('beta', salt);
      expect(k1, isNot(equals(k2)));
    });

    test('uses OWASP-recommended Argon2id parameters', () {
      // Lock in the exact parameters. Any future tightening of the KDF
      // must be deliberate and accompanied by a format version bump.
      expect(BackupCrypto.argon2Memory, 19456,
          reason: 'Argon2id memory cost must match OWASP recommendation');
      expect(BackupCrypto.argon2Iterations, 2,
          reason: 'Argon2id iteration count must match OWASP recommendation');
      expect(BackupCrypto.argon2Lanes, 1,
          reason: 'Argon2id parallelism must match OWASP recommendation');
    });
  });

  group('BackupCrypto.deriveKeyPbkdf2Legacy — for migration only', () {
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));

    test('produces deterministic output for the same input', () {
      final k1 = BackupCrypto.deriveKeyPbkdf2Legacy('password', salt);
      final k2 = BackupCrypto.deriveKeyPbkdf2Legacy('password', salt);
      expect(k1, equals(k2));
    });

    test('produces a 32-byte (256-bit) key', () {
      final key = BackupCrypto.deriveKeyPbkdf2Legacy('pw', salt);
      expect(key.length, 32);
    });

    test('produces a different key than Argon2id for identical input', () {
      // Sanity check that we are not accidentally calling the same KDF
      // under both names.
      final pbkdf2 = BackupCrypto.deriveKeyPbkdf2Legacy('pw', salt);
      final argon2 = BackupCrypto.deriveKeyArgon2id('pw', salt);
      expect(pbkdf2, isNot(equals(argon2)));
    });
  });
}
