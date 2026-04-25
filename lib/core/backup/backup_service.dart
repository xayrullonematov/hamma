import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:share_plus/share_plus.dart';
import 'package:workmanager/workmanager.dart';

import '../ssh/sftp_service.dart';
import '../storage/app_lock_storage.dart';
import 'backup_storage.dart';

class BackupService {
  const BackupService({
    FlutterSecureStorage? secureStorage,
    AppLockStorage? appLockStorage,
    BackupStorage? backupStorage,
    SftpService? sftpService,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _appLockStorage = appLockStorage ?? const AppLockStorage(),
       _backupStorage = backupStorage ?? const BackupStorage(),
       _sftpService = sftpService;

  final FlutterSecureStorage _secureStorage;
  final AppLockStorage _appLockStorage;
  final BackupStorage _backupStorage;
  final SftpService? _sftpService;

  static const _backupFilename = 'hamma_backup.aes';
  static const _backupTaskName = 'com.hamma.daily_backup';

  /// Performs a backup based on the saved configuration.
  Future<void> backupToDestination({String? manualPassword}) async {
    final config = await _backupStorage.loadConfig();
    final password = manualPassword ?? await _appLockStorage.readPin();

    if (password == null || password.isEmpty) {
      throw const BackupException(
        'A master PIN or password is required for backup encryption.',
      );
    }

    try {
      final backupFile = await _createEncryptedBackup(password);

      switch (config.destination) {
        case BackupDestination.local:
          await Share.shareXFiles(
            [XFile(backupFile.path)],
            subject: 'Hamma Backup',
          );
          break;

        case BackupDestination.sftp:
          await _uploadToSftp(config, backupFile);
          break;

        case BackupDestination.webdav:
          await _uploadToWebDav(config, backupFile);
          break;

        case BackupDestination.syncthing:
          await _copyToSyncthing(config, backupFile);
          break;
      }

      await _backupStorage.saveConfig(
        BackupConfig(
          destination: config.destination,
          sftpHost: config.sftpHost,
          sftpPort: config.sftpPort,
          sftpUsername: config.sftpUsername,
          sftpPassword: config.sftpPassword,
          sftpPath: config.sftpPath,
          webdavUrl: config.webdavUrl,
          webdavUsername: config.webdavUsername,
          webdavPassword: config.webdavPassword,
          syncthingPath: config.syncthingPath,
          autoBackupEnabled: config.autoBackupEnabled,
          lastBackupTime: DateTime.now(),
          lastBackupStatus: 'Success',
        ),
      );
    } catch (e) {
      await _backupStorage.saveConfig(
        BackupConfig(
          destination: config.destination,
          sftpHost: config.sftpHost,
          sftpPort: config.sftpPort,
          sftpUsername: config.sftpUsername,
          sftpPassword: config.sftpPassword,
          sftpPath: config.sftpPath,
          webdavUrl: config.webdavUrl,
          webdavUsername: config.webdavUsername,
          webdavPassword: config.webdavPassword,
          syncthingPath: config.syncthingPath,
          autoBackupEnabled: config.autoBackupEnabled,
          lastBackupTime: DateTime.now(),
          lastBackupStatus: 'Failed: $e',
        ),
      );
      rethrow;
    }
  }

  /// Restores data from a destination.
  Future<void> restoreFromDestination({
    String? manualPassword,
    String? localFilePath,
  }) async {
    final config = await _backupStorage.loadConfig();
    final password = manualPassword ?? await _appLockStorage.readPin();

    if (password == null || password.isEmpty) {
      throw const BackupException(
        'A master PIN or password is required for backup decryption.',
      );
    }

    File? fileToRestore;

    try {
      if (localFilePath != null) {
        fileToRestore = File(localFilePath);
      } else {
        switch (config.destination) {
          case BackupDestination.local:
            final result = await FilePicker.platform.pickFiles();
            if (result == null || result.files.isEmpty) return;
            fileToRestore = File(result.files.single.path!);
            break;
          case BackupDestination.sftp:
            fileToRestore = await _downloadFromSftp(config);
            break;
          case BackupDestination.webdav:
            fileToRestore = await _downloadFromWebDav(config);
            break;
          case BackupDestination.syncthing:
            fileToRestore = await _getFromSyncthing(config);
            break;
        }
      }

      if (fileToRestore == null || !await fileToRestore.exists()) {
        throw const BackupException('Backup file not found.');
      }

      await _decryptAndRestore(password, fileToRestore);
    } catch (e) {
      throw BackupException('Restore failed: $e');
    }
  }

  Future<File> _createEncryptedBackup(String password) async {
    // Collect ALL data from FlutterSecureStorage
    final allData = await _secureStorage.readAll();
    final encodedPayload = jsonEncode(allData);

    final salt = _randomBytes(16);
    final keyBytes = _deriveKey(password, salt);
    final ivBytes = _randomBytes(16);

    final key = encrypt.Key(keyBytes);
    final iv = encrypt.IV(ivBytes);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.gcm),
    );

    final encrypted = encrypter.encrypt(encodedPayload, iv: iv);

    final outputBytes = Uint8List.fromList([
      ...salt,
      ...ivBytes,
      ...encrypted.bytes,
    ]);

    final tempDir = await getTemporaryDirectory();
    final backupFile = File(p.join(tempDir.path, _backupFilename));
    await backupFile.writeAsBytes(outputBytes, flush: true);

    return backupFile;
  }

  Future<void> _decryptAndRestore(String password, File file) async {
    final inputBytes = await file.readAsBytes();
    if (inputBytes.length <= 32) {
      throw const BackupException('Corrupted backup file.');
    }

    final salt = Uint8List.fromList(inputBytes.sublist(0, 16));
    final ivBytes = Uint8List.fromList(inputBytes.sublist(16, 32));
    final encryptedBytes = Uint8List.fromList(inputBytes.sublist(32));

    final keyBytes = _deriveKey(password, salt);
    final key = encrypt.Key(keyBytes);
    final iv = encrypt.IV(ivBytes);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.gcm),
    );

    try {
      final decryptedPayload = encrypter.decrypt(
        encrypt.Encrypted(encryptedBytes),
        iv: iv,
      );
      final decodedData = jsonDecode(decryptedPayload) as Map<String, dynamic>;

      // Restore all keys to FlutterSecureStorage
      // We clear first to ensure a clean state
      await _secureStorage.deleteAll();
      for (final entry in decodedData.entries) {
        await _secureStorage.write(key: entry.key, value: entry.value);
      }
    } catch (e) {
      throw const BackupException('Incorrect password or corrupted file.');
    }
  }

  Uint8List _deriveKey(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, 10000, 32));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  // Transport Methods

  Future<void> _uploadToSftp(BackupConfig config, File file) async {
    final sftp = _sftpService ?? SftpService();
    try {
      await sftp.connect(
        host: config.sftpHost,
        port: config.sftpPort,
        username: config.sftpUsername,
        password: config.sftpPassword,
      );
      final remotePath = p.join(config.sftpPath, _backupFilename);
      await sftp.uploadFile(file.path, remotePath);
    } finally {
      await sftp.dispose();
    }
  }

  Future<File> _downloadFromSftp(BackupConfig config) async {
    final sftp = _sftpService ?? SftpService();
    final tempDir = await getTemporaryDirectory();
    final localPath = p.join(tempDir.path, 'restored_backup.aes');
    try {
      await sftp.connect(
        host: config.sftpHost,
        port: config.sftpPort,
        username: config.sftpUsername,
        password: config.sftpPassword,
      );
      final remotePath = p.join(config.sftpPath, _backupFilename);
      await sftp.downloadFile(remotePath, localPath);
      return File(localPath);
    } finally {
      await sftp.dispose();
    }
  }

  Future<void> _uploadToWebDav(BackupConfig config, File file) async {
    final bytes = await file.readAsBytes();
    final uri = Uri.parse(
      '${config.webdavUrl}/${_backupFilename}'.replaceAll(
        RegExp(r'(?<!:)/+'),
        '/',
      ),
    );
    final auth = base64Encode(
      utf8.encode('${config.webdavUsername}:${config.webdavPassword}'),
    );

    final response = await http.put(
      uri,
      headers: {'Authorization': 'Basic $auth'},
      body: bytes,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('WebDAV upload failed: ${response.statusCode}');
    }
  }

  Future<File> _downloadFromWebDav(BackupConfig config) async {
    final uri = Uri.parse(
      '${config.webdavUrl}/${_backupFilename}'.replaceAll(
        RegExp(r'(?<!:)/+'),
        '/',
      ),
    );
    final auth = base64Encode(
      utf8.encode('${config.webdavUsername}:${config.webdavPassword}'),
    );

    final response = await http.get(
      uri,
      headers: {'Authorization': 'Basic $auth'},
    );

    if (response.statusCode != 200) {
      throw Exception('WebDAV download failed: ${response.statusCode}');
    }

    final tempDir = await getTemporaryDirectory();
    final localFile = File(p.join(tempDir.path, 'restored_backup.aes'));
    await localFile.writeAsBytes(response.bodyBytes);
    return localFile;
  }

  Future<void> _copyToSyncthing(BackupConfig config, File file) async {
    final targetPath = p.join(config.syncthingPath, _backupFilename);
    await file.copy(targetPath);
  }

  Future<File> _getFromSyncthing(BackupConfig config) async {
    final sourcePath = p.join(config.syncthingPath, _backupFilename);
    final file = File(sourcePath);
    if (!await file.exists()) {
      throw Exception('Backup file not found in Syncthing folder.');
    }
    return file;
  }

  // Scheduling

  Future<void> scheduleDailyBackup() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await Workmanager().registerPeriodicTask(
      _backupTaskName,
      _backupTaskName,
      frequency: const Duration(hours: 24),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  Future<void> cancelDailyBackup() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await Workmanager().cancelByUniqueName(_backupTaskName);
  }
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}
