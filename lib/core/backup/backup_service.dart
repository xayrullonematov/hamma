import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:workmanager/workmanager.dart';

import '../error/error_reporter.dart';
import '../ssh/sftp_service.dart';
import '../storage/app_lock_storage.dart';
import '../storage/backup_storage.dart';
import 'backup_crypto.dart';

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
          try {
            await backupFile.delete();
          } catch (e, stack) {
            // Best-effort cleanup of the temp file after the share sheet
            // closes. Failure here is non-fatal (OS will reap the temp
            // file eventually) but we still want telemetry.
            unawaited(ErrorReporter.report(
              e,
              stack,
              hint: 'BackupService: temp file cleanup after share',
            ));
          }
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

      if (!await fileToRestore.exists()) {
        throw const BackupException('Backup file not found.');
      }

      await _decryptAndRestore(password, fileToRestore);
    } on BackupException {
      rethrow;
    } catch (e) {
      throw BackupException('Restore failed: $e');
    }
  }

  Future<File> _createEncryptedBackup(String password) async {
    // Collect ALL data from FlutterSecureStorage
    final allData = await _secureStorage.readAll();
    final encodedPayload = jsonEncode(allData);
    final plaintext = Uint8List.fromList(utf8.encode(encodedPayload));

    final blob = BackupCrypto.encrypt(password, plaintext);

    final tempDir = await getTemporaryDirectory();
    final backupFile = File(p.join(tempDir.path, _backupFilename));
    await backupFile.writeAsBytes(blob, flush: true);

    return backupFile;
  }

  Future<void> _decryptAndRestore(String password, File file) async {
    final blob = await file.readAsBytes();

    final Uint8List plaintext;
    try {
      plaintext = BackupCrypto.decrypt(password, blob);
    } on BackupCryptoException catch (e) {
      throw BackupException(e.message);
    }

    final Map<String, dynamic> decodedData;
    try {
      decodedData = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupException(
        'Backup payload is not in the expected format.',
      );
    }

    // Restore all keys to FlutterSecureStorage. Clear first so old keys
    // that no longer exist on the source device don't linger.
    await _secureStorage.deleteAll();
    for (final entry in decodedData.entries) {
      await _secureStorage.write(key: entry.key, value: entry.value);
    }
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
      '${config.webdavUrl}/$_backupFilename'.replaceAll(
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
      '${config.webdavUrl}/$_backupFilename'.replaceAll(
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
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
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
