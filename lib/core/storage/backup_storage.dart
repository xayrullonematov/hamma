import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where Hamma's encrypted backup blob is shipped to.
///
/// All values share the same `BackupCrypto` (Argon2id + AES-256-GCM)
/// encryption layer; the destination only changes the transport.
/// Cloud destinations (`s3Compat`, `iCloud`, `dropbox`) were added in
/// Phase 5 and ship pre-encrypted blobs over HTTPS / platform-native
/// containers — the cloud provider only ever sees opaque ciphertext.
enum BackupDestination {
  local,
  sftp,
  webdav,
  syncthing,
  s3Compat,
  iCloud,
  dropbox,
}

/// How often the cloud sync engine should produce a fresh encrypted
/// snapshot and ship it to the configured destination. `manual` means
/// the user must press "Sync now" explicitly — no timer fires.
enum CloudSyncCadence { manual, hourly, daily }

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
    // S3-compat (works for AWS S3, Backblaze B2, MinIO, Cloudflare R2)
    this.s3Endpoint = '',
    this.s3Region = 'us-east-1',
    this.s3Bucket = '',
    this.s3AccessKeyId = '',
    this.s3SecretAccessKey = '',
    this.s3Prefix = 'hamma/',
    this.s3UsePathStyle = false,
    // Dropbox
    this.dropboxAccessToken = '',
    this.dropboxAppFolder = '/Apps/Hamma',
    // iCloud
    this.iCloudContainerId = '',
    this.iCloudFolder = 'hamma',
    // Cloud sync engine
    this.cloudCadence = CloudSyncCadence.manual,
    this.cloudDeviceId = '',
    this.lastCloudSyncTime,
    this.lastCloudSyncStatus,
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
  final String s3Endpoint;
  final String s3Region;
  final String s3Bucket;
  final String s3AccessKeyId;
  final String s3SecretAccessKey;
  final String s3Prefix;
  final bool s3UsePathStyle;
  final String dropboxAccessToken;
  final String dropboxAppFolder;
  final String iCloudContainerId;
  final String iCloudFolder;
  final CloudSyncCadence cloudCadence;
  final String cloudDeviceId;
  final DateTime? lastCloudSyncTime;
  final String? lastCloudSyncStatus;
  final bool autoBackupEnabled;
  final DateTime? lastBackupTime;
  final String? lastBackupStatus;

  /// Convenience: is `destination` one of the Phase-5 cloud destinations?
  bool get isCloudDestination =>
      destination == BackupDestination.s3Compat ||
      destination == BackupDestination.iCloud ||
      destination == BackupDestination.dropbox;

  BackupConfig copyWith({
    BackupDestination? destination,
    String? sftpHost,
    int? sftpPort,
    String? sftpUsername,
    String? sftpPassword,
    String? sftpPath,
    String? webdavUrl,
    String? webdavUsername,
    String? webdavPassword,
    String? syncthingPath,
    String? s3Endpoint,
    String? s3Region,
    String? s3Bucket,
    String? s3AccessKeyId,
    String? s3SecretAccessKey,
    String? s3Prefix,
    bool? s3UsePathStyle,
    String? dropboxAccessToken,
    String? dropboxAppFolder,
    String? iCloudContainerId,
    String? iCloudFolder,
    CloudSyncCadence? cloudCadence,
    String? cloudDeviceId,
    DateTime? lastCloudSyncTime,
    String? lastCloudSyncStatus,
    bool? autoBackupEnabled,
    DateTime? lastBackupTime,
    String? lastBackupStatus,
  }) {
    return BackupConfig(
      destination: destination ?? this.destination,
      sftpHost: sftpHost ?? this.sftpHost,
      sftpPort: sftpPort ?? this.sftpPort,
      sftpUsername: sftpUsername ?? this.sftpUsername,
      sftpPassword: sftpPassword ?? this.sftpPassword,
      sftpPath: sftpPath ?? this.sftpPath,
      webdavUrl: webdavUrl ?? this.webdavUrl,
      webdavUsername: webdavUsername ?? this.webdavUsername,
      webdavPassword: webdavPassword ?? this.webdavPassword,
      syncthingPath: syncthingPath ?? this.syncthingPath,
      s3Endpoint: s3Endpoint ?? this.s3Endpoint,
      s3Region: s3Region ?? this.s3Region,
      s3Bucket: s3Bucket ?? this.s3Bucket,
      s3AccessKeyId: s3AccessKeyId ?? this.s3AccessKeyId,
      s3SecretAccessKey: s3SecretAccessKey ?? this.s3SecretAccessKey,
      s3Prefix: s3Prefix ?? this.s3Prefix,
      s3UsePathStyle: s3UsePathStyle ?? this.s3UsePathStyle,
      dropboxAccessToken: dropboxAccessToken ?? this.dropboxAccessToken,
      dropboxAppFolder: dropboxAppFolder ?? this.dropboxAppFolder,
      iCloudContainerId: iCloudContainerId ?? this.iCloudContainerId,
      iCloudFolder: iCloudFolder ?? this.iCloudFolder,
      cloudCadence: cloudCadence ?? this.cloudCadence,
      cloudDeviceId: cloudDeviceId ?? this.cloudDeviceId,
      lastCloudSyncTime: lastCloudSyncTime ?? this.lastCloudSyncTime,
      lastCloudSyncStatus: lastCloudSyncStatus ?? this.lastCloudSyncStatus,
      autoBackupEnabled: autoBackupEnabled ?? this.autoBackupEnabled,
      lastBackupTime: lastBackupTime ?? this.lastBackupTime,
      lastBackupStatus: lastBackupStatus ?? this.lastBackupStatus,
    );
  }

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
      's3Endpoint': s3Endpoint,
      's3Region': s3Region,
      's3Bucket': s3Bucket,
      's3AccessKeyId': s3AccessKeyId,
      's3SecretAccessKey': s3SecretAccessKey,
      's3Prefix': s3Prefix,
      's3UsePathStyle': s3UsePathStyle,
      'dropboxAccessToken': dropboxAccessToken,
      'dropboxAppFolder': dropboxAppFolder,
      'iCloudContainerId': iCloudContainerId,
      'iCloudFolder': iCloudFolder,
      'cloudCadence': cloudCadence.name,
      'cloudDeviceId': cloudDeviceId,
      'lastCloudSyncTime': lastCloudSyncTime?.toIso8601String(),
      'lastCloudSyncStatus': lastCloudSyncStatus,
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
      sftpHost: (json['sftpHost'] as String?) ?? '',
      sftpPort: (json['sftpPort'] as int?) ?? 22,
      sftpUsername: (json['sftpUsername'] as String?) ?? '',
      sftpPassword: (json['sftpPassword'] as String?) ?? '',
      sftpPath: (json['sftpPath'] as String?) ?? '',
      webdavUrl: (json['webdavUrl'] as String?) ?? '',
      webdavUsername: (json['webdavUsername'] as String?) ?? '',
      webdavPassword: (json['webdavPassword'] as String?) ?? '',
      syncthingPath: (json['syncthingPath'] as String?) ?? '',
      s3Endpoint: (json['s3Endpoint'] as String?) ?? '',
      s3Region: (json['s3Region'] as String?) ?? 'us-east-1',
      s3Bucket: (json['s3Bucket'] as String?) ?? '',
      s3AccessKeyId: (json['s3AccessKeyId'] as String?) ?? '',
      s3SecretAccessKey: (json['s3SecretAccessKey'] as String?) ?? '',
      s3Prefix: (json['s3Prefix'] as String?) ?? 'hamma/',
      s3UsePathStyle: (json['s3UsePathStyle'] as bool?) ?? false,
      dropboxAccessToken: (json['dropboxAccessToken'] as String?) ?? '',
      dropboxAppFolder:
          (json['dropboxAppFolder'] as String?) ?? '/Apps/Hamma',
      iCloudContainerId: (json['iCloudContainerId'] as String?) ?? '',
      iCloudFolder: (json['iCloudFolder'] as String?) ?? 'hamma',
      cloudCadence: CloudSyncCadence.values.firstWhere(
        (e) => e.name == json['cloudCadence'],
        orElse: () => CloudSyncCadence.manual,
      ),
      cloudDeviceId: (json['cloudDeviceId'] as String?) ?? '',
      lastCloudSyncTime: json['lastCloudSyncTime'] != null
          ? DateTime.tryParse(json['lastCloudSyncTime'] as String)
          : null,
      lastCloudSyncStatus: json['lastCloudSyncStatus'] as String?,
      autoBackupEnabled: (json['autoBackupEnabled'] as bool?) ?? false,
      lastBackupTime: json['lastBackupTime'] != null
          ? DateTime.tryParse(json['lastBackupTime'] as String)
          : null,
      lastBackupStatus: json['lastBackupStatus'] as String?,
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
      return BackupConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
