import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as aes;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import 'vault_group.dart';
import 'vault_secret.dart';
import 'vault_storage.dart';

class VaultImportResult {
  final int imported;
  final int skipped;
  final int conflicts;

  VaultImportResult({
    required this.imported,
    required this.skipped,
    required this.conflicts,
  });
}

class VaultExportException implements Exception {
  final String message;
  VaultExportException(this.message);
  @override
  String toString() => message;
}

class VaultExportService {
  final VaultStorage _storage;

  VaultExportService({VaultStorage? storage})
      : _storage = storage ?? VaultStorage();

  static const List<int> _magic = [0x48, 0x4D, 0x56, 0x54]; // 'HMVT'
  static const int _version = 1;
  static const int _iterations = 100000;
  static const int _saltLength = 16;
  static const int _nonceLength = 12;
  static const int _keyLength = 32;

  Future<Uint8List> export(String passphrase) async {
    if (passphrase.isEmpty) {
      throw VaultExportException('Passphrase cannot be empty.');
    }

    final secrets = await _storage.loadAll();
    final groups = await _storage.loadAllGroups();

    final envelope = {
      'version': _version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'groups': groups.map((g) => g.toJson()).toList(),
      'secrets': secrets.map((s) => s.toJson()).toList(),
    };

    final plaintext = utf8.encode(jsonEncode(envelope));
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final key = _deriveKey(passphrase, salt);

    final encrypter = aes.Encrypter(aes.AES(aes.Key(key), mode: aes.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(plaintext, iv: aes.IV(nonce));

    final out = BytesBuilder();
    out.add(_magic);
    out.addByte(_version);
    out.add(salt);
    out.add(nonce);
    out.add(encrypted.bytes); // GCM tag is appended by the encrypt package in GCM mode

    return out.toBytes();
  }

  Future<VaultImportResult> import(Uint8List data, String passphrase) async {
    if (data.length < _magic.length + 1 + _saltLength + _nonceLength + 16) {
      throw VaultExportException('Invalid or truncated export file.');
    }

    // Validate Magic
    for (int i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) {
        throw VaultExportException('Not a valid Hamma vault export file.');
      }
    }

    final version = data[_magic.length];
    if (version != _version) {
      throw VaultExportException('Unsupported export version: $version');
    }

    final salt = data.sublist(_magic.length + 1, _magic.length + 1 + _saltLength);
    final nonce = data.sublist(
      _magic.length + 1 + _saltLength,
      _magic.length + 1 + _saltLength + _nonceLength,
    );
    final ciphertext = data.sublist(_magic.length + 1 + _saltLength + _nonceLength);

    final key = _deriveKey(passphrase, salt);
    final encrypter = aes.Encrypter(aes.AES(aes.Key(key), mode: aes.AESMode.gcm));

    Uint8List plaintext;
    try {
      final decrypted = encrypter.decryptBytes(aes.Encrypted(ciphertext), iv: aes.IV(nonce));
      plaintext = Uint8List.fromList(decrypted);
    } catch (_) {
      throw VaultExportException('Incorrect passphrase or corrupted file.');
    }

    final envelope = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    final secretsRaw = envelope['secrets'] as List? ?? [];
    final groupsRaw = envelope['groups'] as List? ?? [];

    final importedSecrets = secretsRaw
        .whereType<Map<dynamic, dynamic>>()
        .map((s) => VaultSecret.fromJson(s.cast<String, dynamic>()))
        .toList();
    final importedGroups = groupsRaw
        .whereType<Map<dynamic, dynamic>>()
        .map((g) => VaultGroup.fromJson(g.cast<String, dynamic>()))
        .toList();

    return _merge(importedSecrets, importedGroups);
  }

  Future<VaultImportResult> _merge(
    List<VaultSecret> remoteSecrets,
    List<VaultGroup> remoteGroups,
  ) async {
    final localSecrets = await _storage.loadAll();
    final localGroups = await _storage.loadAllGroups();
    final localMeta = await _storage.loadSyncMeta();

    int importedCount = 0;
    int skippedCount = 0;
    int conflictCount = 0;

    final localSecretsMap = {for (final s in localSecrets) s.id: s};
    final localGroupsMap = {for (final g in localGroups) g.id: g};

    final finalSecrets = <String, VaultSecret>{...localSecretsMap};
    final finalGroups = <String, VaultGroup>{...localGroupsMap};
    
    final finalUpdatedAt = <String, DateTime>{...localMeta.updatedAt};
    final finalTombstones = <String, DateTime>{...localMeta.tombstones};
    final finalGroupTombstones = <String, DateTime>{...localMeta.groupTombstones};

    // Merge groups
    for (final remoteG in remoteGroups) {
      final localG = localGroupsMap[remoteG.id];
      final localTomb = localMeta.groupTombstones[remoteG.id];

      if (localTomb != null && localTomb.isAfter(remoteG.updatedAt)) {
        skippedCount++;
        continue;
      }

      if (localG == null || remoteG.updatedAt.isAfter(localG.updatedAt)) {
        finalGroups[remoteG.id] = remoteG;
        finalGroupTombstones.remove(remoteG.id);
        finalUpdatedAt[remoteG.id] = remoteG.updatedAt;
        importedCount++;
        if (localG != null) conflictCount++; // We updated an existing one
      } else {
        skippedCount++;
      }
    }

    // Merge secrets
    for (final remoteS in remoteSecrets) {
      final localS = localSecretsMap[remoteS.id];
      final localTomb = localMeta.tombstones[remoteS.id];

      if (localTomb != null && localTomb.isAfter(remoteS.updatedAt)) {
        skippedCount++;
        continue;
      }

      if (localS == null || remoteS.updatedAt.isAfter(localS.updatedAt)) {
        finalSecrets[remoteS.id] = remoteS;
        finalTombstones.remove(remoteS.id);
        finalUpdatedAt[remoteS.id] = remoteS.updatedAt;
        importedCount++;
        if (localS != null) conflictCount++; // We updated an existing one
      } else {
        skippedCount++;
      }
    }

    await _storage.applyMergedState(
      secrets: finalSecrets.values.toList(),
      groups: finalGroups.values.toList(),
      meta: VaultSyncMeta(
        updatedAt: finalUpdatedAt,
        tombstones: finalTombstones,
        groupTombstones: finalGroupTombstones,
      ),
    );

    return VaultImportResult(
      imported: importedCount,
      skipped: skippedCount,
      conflicts: conflictCount,
    );
  }

  Uint8List _deriveKey(String passphrase, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
