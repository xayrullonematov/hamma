import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/fleet_service.dart';
import 'package:hamma/core/ssh/ssh_transport.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

class InMemoryTrustedHostKeyStorage extends TrustedHostKeyStorage {
  InMemoryTrustedHostKeyStorage();

  final Map<String, TrustedHostKeyRecord> _records = {};

  String _key(String host, int port) => '$host:$port';

  @override
  Future<TrustedHostKeyRecord?> loadTrustedHostKey({
    required String host,
    required int port,
  }) async {
    return _records[_key(host, port)];
  }

  @override
  Future<void> saveTrustedHostKey({
    required String host,
    required int port,
    required TrustedHostKeyRecord record,
  }) async {
    _records[_key(host, port)] = record;
  }
}

class FakeSshTransport implements SshTransport {
  FakeSshTransport({this.delay, this.timeout = false});

  final Duration? delay;
  final bool timeout;

  @override
  Future<void> get authenticated => Future.value();

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> ping() => Future.value();

  @override
  void close() {}

  @override
  Future<Uint8List> run(String command, {Map<String, String>? environment}) async {
    if (delay != null) {
      await Future.delayed(delay!);
    }

    if (timeout) {
      // Simulate taking longer than the commandTimeout (8s)
      await Future.delayed(const Duration(seconds: 10));
      return Uint8List(0);
    }

    return Uint8List.fromList('Success: $command'.codeUnits);
  }

  @override
  Future<SSHSession> execute(String command, {Map<String, String>? environment}) {
    throw UnimplementedError();
  }

  @override
  Future<SSHSession> shell({SSHPtyConfig? pty}) {
    throw UnimplementedError();
  }

  @override
  Future<SSHForwardChannel> forwardLocal(String host, int port) {
    throw UnimplementedError();
  }
}

void main() {
  group('FleetService', () {
    test('executeBulkCommand executes in parallel', () async {
      int connectionCount = 0;

      Future<SshTransport> fakeConnector({
        required String host,
        required int port,
        required String username,
        required String password,
        String? privateKey,
        String? privateKeyPassword,
        required Future<bool> Function(
          String algorithm,
          Uint8List fingerprintBytes,
        ) onVerifyHostKey,
      }) async {
        connectionCount++;
        // Invoke onVerifyHostKey callback as it's required for the flow
        await onVerifyHostKey('ssh-rsa', Uint8List.fromList([1,2,3]));
        return FakeSshTransport(delay: const Duration(milliseconds: 100));
      }

      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: '1.2.3.4', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );
      await storage.saveTrustedHostKey(
        host: '1.2.3.5', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );
      await storage.saveTrustedHostKey(
        host: '1.2.3.6', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );

      final fleetService = FleetService(connector: fakeConnector, trustedHostKeyStorage: storage);

      final servers = [
        ServerProfile(id: '1', name: 'Server 1', host: '1.2.3.4', port: 22, username: 'root', password: 'pw'),
        ServerProfile(id: '2', name: 'Server 2', host: '1.2.3.5', port: 22, username: 'root', password: 'pw'),
        ServerProfile(id: '3', name: 'Server 3', host: '1.2.3.6', port: 22, username: 'root', password: 'pw'),
      ];

      final stopwatch = Stopwatch()..start();

      final results = await fleetService.executeBulkCommand(servers, 'echo hello');

      stopwatch.stop();

      // Sequential execution would take 300ms. If it's parallel, it should take ~100ms.
      expect(stopwatch.elapsedMilliseconds, lessThan(250));
      expect(connectionCount, 3);
      expect(results.length, 3);
      expect(results['1'], 'Success: echo hello');
      expect(results['2'], 'Success: echo hello');
      expect(results['3'], 'Success: echo hello');
    });

    test('executeBulkCommand handles timeout for one server without affecting others', () async {
      Future<SshTransport> fakeConnector({
        required String host,
        required int port,
        required String username,
        required String password,
        String? privateKey,
        String? privateKeyPassword,
        required Future<bool> Function(
          String algorithm,
          Uint8List fingerprintBytes,
        ) onVerifyHostKey,
      }) async {
        await onVerifyHostKey('ssh-rsa', Uint8List.fromList([1,2,3]));
        if (host == '1.2.3.5') {
           return FakeSshTransport(timeout: true);
        }
        return FakeSshTransport(delay: const Duration(milliseconds: 50));
      }

      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: '1.2.3.4', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );
      await storage.saveTrustedHostKey(
        host: '1.2.3.5', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );
      await storage.saveTrustedHostKey(
        host: '1.2.3.6', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );


      // Configure short timeouts so test runs fast
      final fleetService = FleetService(
        connector: fakeConnector,
        trustedHostKeyStorage: storage,
        connectTimeout: const Duration(milliseconds: 100),
        commandTimeout: const Duration(milliseconds: 100)
      );

      final servers = [
        ServerProfile(id: '1', name: 'Server 1', host: '1.2.3.4', port: 22, username: 'root', password: 'pw'),
        ServerProfile(id: '2', name: 'Server 2', host: '1.2.3.5', port: 22, username: 'root', password: 'pw'),
        ServerProfile(id: '3', name: 'Server 3', host: '1.2.3.6', port: 22, username: 'root', password: 'pw'),
      ];

      final results = await fleetService.executeBulkCommand(servers, 'echo test');

      expect(results.length, 3);
      expect(results['1'], 'Success: echo test');
      expect(results['2'], 'Error: Timed out.');
      expect(results['3'], 'Success: echo test');
    });

    test('executeBulkCommand handles network failure (connector throws)', () async {
      Future<SshTransport> fakeConnector({
        required String host,
        required int port,
        required String username,
        required String password,
        String? privateKey,
        String? privateKeyPassword,
        required Future<bool> Function(
          String algorithm,
          Uint8List fingerprintBytes,
        ) onVerifyHostKey,
      }) async {
        if (host == '1.2.3.5') {
           throw Exception('Connection refused');
        }
        await onVerifyHostKey('ssh-rsa', Uint8List.fromList([1,2,3]));
        return FakeSshTransport(delay: const Duration(milliseconds: 10));
      }

      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: '1.2.3.4', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );
      await storage.saveTrustedHostKey(
        host: '1.2.3.5', port: 22, record: const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: '01:02:03')
      );

      final fleetService = FleetService(connector: fakeConnector, trustedHostKeyStorage: storage);

      final servers = [
        ServerProfile(id: '1', name: 'Server 1', host: '1.2.3.4', port: 22, username: 'root', password: 'pw'),
        ServerProfile(id: '2', name: 'Server 2', host: '1.2.3.5', port: 22, username: 'root', password: 'pw'),
      ];

      final results = await fleetService.executeBulkCommand(servers, 'echo test');

      expect(results.length, 2);
      expect(results['1'], 'Success: echo test');
      expect(results['2'], contains('Connection refused'));
    });
  });
}
