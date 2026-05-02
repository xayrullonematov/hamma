import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TrustedHostKeyStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const SecureTrustedHostKeyStorage();
  });

  group('TrustedHostKeyRecord serialization', () {
    test('toJson includes algorithm and fingerprint', () {
      const record = TrustedHostKeyRecord(
        algorithm: 'ssh-rsa',
        fingerprint: 'AA:BB:CC:DD',
      );
      final json = record.toJson();
      expect(json['algorithm'], 'ssh-rsa');
      expect(json['fingerprint'], 'AA:BB:CC:DD');
    });

    test('fromJson round-trips correctly', () {
      const original = TrustedHostKeyRecord(
        algorithm: 'ecdsa-sha2-nistp256',
        fingerprint: '11:22:33:44',
      );
      final restored = TrustedHostKeyRecord.fromJson(original.toJson());
      expect(restored.algorithm, original.algorithm);
      expect(restored.fingerprint, original.fingerprint);
    });

    test('fromJson handles missing fields gracefully with empty strings', () {
      final record = TrustedHostKeyRecord.fromJson({});
      expect(record.algorithm, '');
      expect(record.fingerprint, '');
    });
  });

  group('loadTrustedHostKey', () {
    test('returns null when no key is stored', () async {
      final result = await storage.loadTrustedHostKey(host: 'example.com', port: 22);
      expect(result, isNull);
    });

    test('returns the saved key for the same host+port', () async {
      const record = TrustedHostKeyRecord(
        algorithm: 'ssh-rsa',
        fingerprint: 'AA:BB:CC',
      );
      await storage.saveTrustedHostKey(host: 'example.com', port: 22, record: record);

      final result = await storage.loadTrustedHostKey(host: 'example.com', port: 22);
      expect(result, isNotNull);
      expect(result!.algorithm, 'ssh-rsa');
      expect(result.fingerprint, 'AA:BB:CC');
    });

    test('keys are isolated by host', () async {
      const record = TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: 'AA:BB');
      await storage.saveTrustedHostKey(host: 'server-a.com', port: 22, record: record);

      final result = await storage.loadTrustedHostKey(host: 'server-b.com', port: 22);
      expect(result, isNull);
    });

    test('keys are isolated by port', () async {
      const record = TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: 'AA:BB');
      await storage.saveTrustedHostKey(host: 'example.com', port: 22, record: record);

      final result = await storage.loadTrustedHostKey(host: 'example.com', port: 2222);
      expect(result, isNull);
    });
  });

  group('saveTrustedHostKey', () {
    test('overwrites an existing key for the same host+port', () async {
      const first = TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: 'OLD');
      const second = TrustedHostKeyRecord(algorithm: 'ecdsa-sha2-nistp256', fingerprint: 'NEW');

      await storage.saveTrustedHostKey(host: 'example.com', port: 22, record: first);
      await storage.saveTrustedHostKey(host: 'example.com', port: 22, record: second);

      final result = await storage.loadTrustedHostKey(host: 'example.com', port: 22);
      expect(result!.fingerprint, 'NEW');
      expect(result.algorithm, 'ecdsa-sha2-nistp256');
    });

    test('stores different keys for different ports on the same host', () async {
      const key22 = TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: 'PORT-22');
      const key2222 = TrustedHostKeyRecord(algorithm: 'ssh-ed25519', fingerprint: 'PORT-2222');

      await storage.saveTrustedHostKey(host: 'example.com', port: 22, record: key22);
      await storage.saveTrustedHostKey(host: 'example.com', port: 2222, record: key2222);

      final result22 = await storage.loadTrustedHostKey(host: 'example.com', port: 22);
      final result2222 = await storage.loadTrustedHostKey(host: 'example.com', port: 2222);

      expect(result22!.fingerprint, 'PORT-22');
      expect(result2222!.fingerprint, 'PORT-2222');
    });
  });
}
