import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/backup_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BackupStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const BackupStorage();
  });

  group('BackupConfig serialization', () {
    test('toJson / fromJson round-trips local destination', () {
      const config = BackupConfig(destination: BackupDestination.local);
      final restored = BackupConfig.fromJson(config.toJson());
      expect(restored.destination, BackupDestination.local);
      expect(restored.autoBackupEnabled, isFalse);
    });

    test('toJson / fromJson round-trips SFTP config', () {
      const config = BackupConfig(
        destination: BackupDestination.sftp,
        sftpHost: 'backup.example.com',
        sftpPort: 2222,
        sftpUsername: 'backupuser',
        sftpPassword: 'secret',
        sftpPath: '/home/backups',
        autoBackupEnabled: true,
      );
      final restored = BackupConfig.fromJson(config.toJson());

      expect(restored.destination, BackupDestination.sftp);
      expect(restored.sftpHost, 'backup.example.com');
      expect(restored.sftpPort, 2222);
      expect(restored.sftpUsername, 'backupuser');
      expect(restored.sftpPassword, 'secret');
      expect(restored.sftpPath, '/home/backups');
      expect(restored.autoBackupEnabled, isTrue);
    });

    test('toJson / fromJson round-trips WebDAV config', () {
      const config = BackupConfig(
        destination: BackupDestination.webdav,
        webdavUrl: 'https://dav.example.com',
        webdavUsername: 'user',
        webdavPassword: 'pass',
      );
      final restored = BackupConfig.fromJson(config.toJson());

      expect(restored.destination, BackupDestination.webdav);
      expect(restored.webdavUrl, 'https://dav.example.com');
      expect(restored.webdavUsername, 'user');
    });

    test('toJson / fromJson round-trips lastBackupTime', () {
      final backupTime = DateTime(2026, 4, 30, 12, 0, 0);
      final config = BackupConfig(
        destination: BackupDestination.local,
        lastBackupTime: backupTime,
        lastBackupStatus: 'success',
      );
      final restored = BackupConfig.fromJson(config.toJson());

      expect(restored.lastBackupTime, backupTime);
      expect(restored.lastBackupStatus, 'success');
    });

    test('fromJson handles null lastBackupTime gracefully', () {
      const config = BackupConfig(destination: BackupDestination.local);
      final json = config.toJson();
      json['lastBackupTime'] = null;

      final restored = BackupConfig.fromJson(json);
      expect(restored.lastBackupTime, isNull);
    });

    test('fromJson falls back to local when destination is unknown', () {
      final json = BackupConfig(destination: BackupDestination.local).toJson();
      json['destination'] = 'invalid_destination';

      final restored = BackupConfig.fromJson(json);
      expect(restored.destination, BackupDestination.local);
    });

    test('toJson / fromJson round-trips full S3 cloud config', () {
      final config = BackupConfig(
        destination: BackupDestination.s3Compat,
        s3Endpoint: 'https://s3.example.com',
        s3Region: 'eu-west-1',
        s3Bucket: 'my-vault',
        s3AccessKeyId: 'AKIAIOSFODNN7EXAMPLE',
        s3SecretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        s3Prefix: 'hamma/dev/',
        s3UsePathStyle: true,
        cloudCadence: CloudSyncCadence.hourly,
        cloudDeviceId: 'device-abc',
        lastCloudSyncTime: DateTime.utc(2026, 5, 2, 12, 0, 0),
        lastCloudSyncStatus: 'Success',
      );
      final restored = BackupConfig.fromJson(config.toJson());

      expect(restored.destination, BackupDestination.s3Compat);
      expect(restored.s3Endpoint, 'https://s3.example.com');
      expect(restored.s3Region, 'eu-west-1');
      expect(restored.s3Bucket, 'my-vault');
      expect(restored.s3AccessKeyId, 'AKIAIOSFODNN7EXAMPLE');
      expect(restored.s3SecretAccessKey,
          'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY');
      expect(restored.s3Prefix, 'hamma/dev/');
      expect(restored.s3UsePathStyle, isTrue);
      expect(restored.cloudCadence, CloudSyncCadence.hourly);
      expect(restored.cloudDeviceId, 'device-abc');
      expect(restored.lastCloudSyncTime, DateTime.utc(2026, 5, 2, 12, 0, 0));
      expect(restored.lastCloudSyncStatus, 'Success');
    });

    test('toJson / fromJson round-trips Dropbox cloud config', () {
      const config = BackupConfig(
        destination: BackupDestination.dropbox,
        dropboxAccessToken: 'sl.B-token',
        dropboxAppFolder: '/Apps/Hamma',
      );
      final restored = BackupConfig.fromJson(config.toJson());
      expect(restored.destination, BackupDestination.dropbox);
      expect(restored.dropboxAccessToken, 'sl.B-token');
      expect(restored.dropboxAppFolder, '/Apps/Hamma');
    });

    test('toJson / fromJson round-trips iCloud cloud config', () {
      const config = BackupConfig(
        destination: BackupDestination.iCloud,
        iCloudContainerId: 'iCloud.com.hamma.app',
        iCloudFolder: 'hamma',
      );
      final restored = BackupConfig.fromJson(config.toJson());
      expect(restored.destination, BackupDestination.iCloud);
      expect(restored.iCloudContainerId, 'iCloud.com.hamma.app');
      expect(restored.iCloudFolder, 'hamma');
    });

    test('isCloudDestination flags only Phase-5 cloud destinations', () {
      expect(
        const BackupConfig(destination: BackupDestination.local)
            .isCloudDestination,
        isFalse,
      );
      expect(
        const BackupConfig(destination: BackupDestination.sftp)
            .isCloudDestination,
        isFalse,
      );
      expect(
        const BackupConfig(destination: BackupDestination.s3Compat)
            .isCloudDestination,
        isTrue,
      );
      expect(
        const BackupConfig(destination: BackupDestination.iCloud)
            .isCloudDestination,
        isTrue,
      );
      expect(
        const BackupConfig(destination: BackupDestination.dropbox)
            .isCloudDestination,
        isTrue,
      );
    });

    test('fromJson defaults missing cloud fields to safe values', () {
      final json = const BackupConfig(destination: BackupDestination.local)
          .toJson();
      // Strip every cloud field to simulate an old (pre-Phase-5) blob.
      json
        ..remove('s3Endpoint')
        ..remove('s3Region')
        ..remove('s3Bucket')
        ..remove('s3Prefix')
        ..remove('s3UsePathStyle')
        ..remove('dropboxAccessToken')
        ..remove('dropboxAppFolder')
        ..remove('iCloudContainerId')
        ..remove('iCloudFolder')
        ..remove('cloudCadence');
      final restored = BackupConfig.fromJson(json);
      expect(restored.s3Region, 'us-east-1');
      expect(restored.s3Prefix, 'hamma/');
      expect(restored.s3UsePathStyle, isFalse);
      expect(restored.dropboxAppFolder, '/Apps/Hamma');
      expect(restored.iCloudFolder, 'hamma');
      expect(restored.cloudCadence, CloudSyncCadence.manual);
    });
  });

  group('BackupStorage.loadConfig', () {
    test('returns default local config when nothing is saved', () async {
      final config = await storage.loadConfig();
      expect(config.destination, BackupDestination.local);
      expect(config.autoBackupEnabled, isFalse);
    });
  });

  group('BackupStorage.saveConfig / loadConfig', () {
    test('persists and retrieves an SFTP config', () async {
      const config = BackupConfig(
        destination: BackupDestination.sftp,
        sftpHost: 'backup.io',
        sftpPort: 22,
        sftpUsername: 'ops',
        sftpPassword: 's3cr3t',
        sftpPath: '/backups',
        autoBackupEnabled: true,
      );

      await storage.saveConfig(config);
      final result = await storage.loadConfig();

      expect(result.destination, BackupDestination.sftp);
      expect(result.sftpHost, 'backup.io');
      expect(result.sftpUsername, 'ops');
      expect(result.autoBackupEnabled, isTrue);
    });

    test('overwrites previous config on second save', () async {
      await storage.saveConfig(
        const BackupConfig(destination: BackupDestination.sftp),
      );
      await storage.saveConfig(
        const BackupConfig(destination: BackupDestination.webdav),
      );

      final result = await storage.loadConfig();
      expect(result.destination, BackupDestination.webdav);
    });

    test('persists syncthing destination', () async {
      await storage.saveConfig(
        const BackupConfig(
          destination: BackupDestination.syncthing,
          syncthingPath: '/sync/hamma',
        ),
      );
      final result = await storage.loadConfig();
      expect(result.destination, BackupDestination.syncthing);
      expect(result.syncthingPath, '/sync/hamma');
    });

    test('persists s3Compat destination with credentials', () async {
      await storage.saveConfig(const BackupConfig(
        destination: BackupDestination.s3Compat,
        s3Endpoint: 'https://s3.us-west-002.backblazeb2.com',
        s3Region: 'us-west-002',
        s3Bucket: 'hamma-vault',
        s3AccessKeyId: 'k',
        s3SecretAccessKey: 's',
      ));
      final result = await storage.loadConfig();
      expect(result.destination, BackupDestination.s3Compat);
      expect(result.s3Bucket, 'hamma-vault');
      expect(result.s3Region, 'us-west-002');
    });
  });

  group('BackupDestination enum', () {
    test('contains the four legacy + three Phase-5 cloud destinations', () {
      expect(
        BackupDestination.values.map((e) => e.name),
        containsAll([
          'local',
          'sftp',
          'webdav',
          'syncthing',
          's3Compat',
          'iCloud',
          'dropbox',
        ]),
      );
    });
  });
}
