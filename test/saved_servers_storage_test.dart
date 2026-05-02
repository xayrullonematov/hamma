import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/core/storage/saved_servers_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SavedServersStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const SavedServersStorage();
  });

  const alice = ServerProfile(
    id: 'srv-001',
    name: 'Alice',
    host: '10.0.0.1',
    port: 22,
    username: 'alice',
    password: 'pass1',
  );

  const bob = ServerProfile(
    id: 'srv-002',
    name: 'Bob',
    host: '10.0.0.2',
    port: 2222,
    username: 'bob',
    password: 'pass2',
  );

  group('loadServers', () {
    test('returns empty list when nothing has been saved', () async {
      final result = await storage.loadServers();
      expect(result, isEmpty);
    });

    test('returns saved servers in order', () async {
      await storage.saveServers([alice, bob]);

      final result = await storage.loadServers();

      expect(result, hasLength(2));
      expect(result[0].id, alice.id);
      expect(result[1].id, bob.id);
    });

    test('preserves all fields through save/load round-trip', () async {
      const profile = ServerProfile(
        id: 'srv-full',
        name: 'Full Profile',
        host: 'full.example.com',
        port: 22,
        username: 'root',
        password: 'hunter2',
        privateKey: '-----BEGIN RSA PRIVATE KEY-----',
        privateKeyPassword: 'key-secret',
      );

      await storage.saveServers([profile]);
      final result = await storage.loadServers();
      final loaded = result.first;

      expect(loaded.id, profile.id);
      expect(loaded.name, profile.name);
      expect(loaded.host, profile.host);
      expect(loaded.port, profile.port);
      expect(loaded.username, profile.username);
      expect(loaded.password, profile.password);
      expect(loaded.privateKey, profile.privateKey);
      expect(loaded.privateKeyPassword, profile.privateKeyPassword);
    });
  });

  group('saveServers', () {
    test('overwrites previous list with new one', () async {
      await storage.saveServers([alice]);
      await storage.saveServers([bob]);

      final result = await storage.loadServers();

      expect(result, hasLength(1));
      expect(result.first.id, bob.id);
    });

    test('saves empty list — subsequent load returns empty', () async {
      await storage.saveServers([alice, bob]);
      await storage.saveServers([]);

      final result = await storage.loadServers();
      expect(result, isEmpty);
    });
  });

  group('clearServers', () {
    test('removes all saved servers', () async {
      await storage.saveServers([alice, bob]);
      await storage.clearServers();

      final result = await storage.loadServers();
      expect(result, isEmpty);
    });

    test('is idempotent when nothing was saved', () async {
      await expectLater(storage.clearServers(), completes);
      final result = await storage.loadServers();
      expect(result, isEmpty);
    });
  });

  group('delete single server (filter + re-save pattern)', () {
    test('removes the target server and keeps others', () async {
      await storage.saveServers([alice, bob]);

      final servers = await storage.loadServers();
      final updated = servers.where((s) => s.id != alice.id).toList();
      await storage.saveServers(updated);

      final result = await storage.loadServers();
      expect(result, hasLength(1));
      expect(result.first.id, bob.id);
    });
  });

  group('duplicate ID normalisation', () {
    test('assigns new IDs when two profiles share the same id', () async {
      const dup = ServerProfile(
        id: 'srv-001',
        name: 'Duplicate',
        host: '10.0.0.99',
        port: 22,
        username: 'dup',
        password: 'dup-pass',
      );

      await storage.saveServers([alice, dup]);

      final result = await storage.loadServers();
      final ids = result.map((s) => s.id).toList();

      expect(ids.toSet().length, 2);
    });
  });
}
