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
  });

  group('BackupDestination enum', () {
    test('contains all four expected values', () {
      expect(
        BackupDestination.values.map((e) => e.name),
        containsAll(['local', 'sftp', 'webdav', 'syncthing']),
      );
    });
  });
}
