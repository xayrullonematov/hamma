import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/server_profile.dart';
import '../storage/api_key_storage.dart';
import '../storage/saved_servers_storage.dart';

class BackupService {
  const BackupService({
    SavedServersStorage? savedServersStorage,
    ApiKeyStorage? apiKeyStorage,
  }) : _savedServersStorage =
           savedServersStorage ?? const SavedServersStorage(),
       _apiKeyStorage = apiKeyStorage ?? const ApiKeyStorage();

  final SavedServersStorage _savedServersStorage;
  final ApiKeyStorage _apiKeyStorage;

  Future<void> exportBackup(String password) async {
    _validatePassword(password);

    try {
      final servers = await _savedServersStorage.loadServers();
      final aiSettings = await _apiKeyStorage.loadSettings();
      final encodedPayload = jsonEncode({
        'servers': servers.map((server) => server.toJson()).toList(),
        'aiSettings': aiSettings.toJson(),
      });

      final key = _deriveKey(password);
      final ivBytes = _randomBytes(16);
      final iv = encrypt.IV(ivBytes);
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );
      final encryptedPayload = encrypter.encrypt(encodedPayload, iv: iv);

      final outputBytes = Uint8List.fromList([
        ...ivBytes,
        ...encryptedPayload.bytes,
      ]);

      final temporaryDirectory = await getTemporaryDirectory();
      final backupFile = File('${temporaryDirectory.path}/hamma_backup.aes');
      await backupFile.writeAsBytes(outputBytes, flush: true);

      await Share.shareXFiles(
        [XFile(backupFile.path)],
        subject: 'Hamma Backup',
        text: 'Encrypted Hamma backup file',
      );
    } catch (error) {
      if (error is BackupException) {
        rethrow;
      }

      throw BackupException('Could not export backup: $error');
    }
  }

  Future<void> importBackup(String password, String filePath) async {
    _validatePassword(password);

    try {
      final inputBytes = await File(filePath).readAsBytes();
      if (inputBytes.length <= 16) {
        throw const BackupException('Incorrect password or corrupted file');
      }

      final ivBytes = Uint8List.fromList(inputBytes.sublist(0, 16));
      final encryptedBytes = Uint8List.fromList(inputBytes.sublist(16));
      final key = _deriveKey(password);
      final iv = encrypt.IV(ivBytes);
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );

      final decryptedPayload = encrypter.decrypt(
        encrypt.Encrypted(encryptedBytes),
        iv: iv,
      );
      final decodedPayload = jsonDecode(decryptedPayload);
      if (decodedPayload is! Map) {
        throw const BackupException('Incorrect password or corrupted file');
      }

      final payload = Map<String, dynamic>.from(decodedPayload);
      final rawServers = payload['servers'];
      final rawAiSettings = payload['aiSettings'];
      if (rawServers is! List || rawAiSettings is! Map) {
        throw const BackupException('Incorrect password or corrupted file');
      }

      final servers = rawServers
          .map<ServerProfile>((item) {
            if (item is! Map) {
              throw const BackupException(
                'Incorrect password or corrupted file',
              );
            }

            return ServerProfile.fromJson(Map<String, dynamic>.from(item));
          })
          .toList(growable: false);
      final aiSettings = AiSettings.fromJson(
        Map<String, dynamic>.from(rawAiSettings),
      );

      await _savedServersStorage.saveServers(servers);
      await _apiKeyStorage.saveSettings(
        provider: aiSettings.provider,
        apiKey: aiSettings.apiKey,
        openRouterModel: aiSettings.openRouterModel,
      );
    } catch (error) {
      if (error is BackupException &&
          error.message == 'Master password is required.') {
        rethrow;
      }

      throw const BackupException('Incorrect password or corrupted file');
    }
  }

  encrypt.Key _deriveKey(String password) {
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    return encrypt.Key(Uint8List.fromList(keyBytes));
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  void _validatePassword(String password) {
    if (password.trim().isEmpty) {
      throw const BackupException('Master password is required.');
    }
  }
}

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
