import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum BackupDestination { local, sftp, webdav, syncthing }

class BackupConfig {
  const BackupConfig({
    required this.destination,
    this.sftpHost = '',
    this.sftpPort = 22,
    this.sftpUsername = '',
    this.sftpPassword = '',
    this.sftpPath = '/home/user/backups',
    this.webdavUrl = '',
    this.webdavUsername = '',
    this.webdavPassword = '',
    this.syncthingPath = '',
    this.autoBackupEnabled = false,
    this.lastBackupTime,
    this.lastBackupStatus,
  });

  final BackupDestination destination;
  final String sftpHost;
  final int sftpPort;
  final String sftpUsername;
  final String sftpPassword;
  final String sftpPath;
  final String webdavUrl;
  final String webdavUsername;
  final String webdavPassword;
  final String syncthingPath;
  final bool autoBackupEnabled;
  final DateTime? lastBackupTime;
  final String? lastBackupStatus;

  Map<String, dynamic> toJson() {
    return {
      'destination': destination.name,
      'sftpHost': sftpHost,
      'sftpPort': sftpPort,
      'sftpUsername': sftpUsername,
      'sftpPassword': sftpPassword,
      'sftpPath': sftpPath,
      'webdavUrl': webdavUrl,
      'webdavUsername': webdavUsername,
      'webdavPassword': webdavPassword,
      'syncthingPath': syncthingPath,
      'autoBackupEnabled': autoBackupEnabled,
      'lastBackupTime': lastBackupTime?.toIso8601String(),
      'lastBackupStatus': lastBackupStatus,
    };
  }

  factory BackupConfig.fromJson(Map<String, dynamic> json) {
    return BackupConfig(
      destination: BackupDestination.values.firstWhere(
        (e) => e.name == json['destination'],
        orElse: () => BackupDestination.local,
      ),
      sftpHost: json['sftpHost'] ?? '',
      sftpPort: json['sftpPort'] ?? 22,
      sftpUsername: json['sftpUsername'] ?? '',
      sftpPassword: json['sftpPassword'] ?? '',
      sftpPath: json['sftpPath'] ?? '',
      webdavUrl: json['webdavUrl'] ?? '',
      webdavUsername: json['webdavUsername'] ?? '',
      webdavPassword: json['webdavPassword'] ?? '',
      syncthingPath: json['syncthingPath'] ?? '',
      autoBackupEnabled: json['autoBackupEnabled'] ?? false,
      lastBackupTime: json['lastBackupTime'] != null
          ? DateTime.tryParse(json['lastBackupTime'])
          : null,
      lastBackupStatus: json['lastBackupStatus'],
    );
  }
}

class BackupStorage {
  const BackupStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _backupConfigKey = 'backup_config';
  final FlutterSecureStorage _secureStorage;

  Future<BackupConfig> loadConfig() async {
    final raw = await _secureStorage.read(key: _backupConfigKey);
    if (raw == null) return const BackupConfig(destination: BackupDestination.local);
    try {
      return BackupConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return const BackupConfig(destination: BackupDestination.local);
    }
  }

  Future<void> saveConfig(BackupConfig config) async {
    await _secureStorage.write(
      key: _backupConfigKey,
      value: jsonEncode(config.toJson()),
    );
  }
}
