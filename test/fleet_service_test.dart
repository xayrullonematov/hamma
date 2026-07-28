import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/core/ssh/fleet_service.dart';
import 'package:hamma/core/ssh/ssh_transport.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';
import 'package:dartssh2/dartssh2.dart';

// ──────────────────────────────────────────────────────────────────────────────
//  Test doubles
// ──────────────────────────────────────────────────────────────────────────────

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

  int get savedCount => _records.length;
}

class FakeSshConnector {
  final List<FakeSshTransport> _successQueue = [];
  final List<Object> _errorQueue = [];
  int callCount = 0;
  final List<({String host, int port, String username})> calls = [];

  void enqueueSuccess(FakeSshTransport transport) {
    _successQueue.add(transport);
  }

  void enqueueFailure(Object error) {
    _errorQueue.add(error);
  }

  Future<SshTransport> call({
    required String host,
    required int port,
    required String username,
    required String password,
    String? privateKey,
    String? privateKeyPassword,
    required Future<bool> Function(String, Uint8List) onVerifyHostKey,
  }) async {
    calls.add((host: host, port: port, username: username));
    callCount++;

    if (_errorQueue.isNotEmpty) {
      throw _errorQueue.removeAt(0);
    }

    if (_successQueue.isEmpty) {
      throw StateError('FakeSshConnector: no more responses queued');
    }

    // Simulate calling host key verification so TOFU logic could be tested
    // Note: since we test default path, we catch exceptions the user-defined
    // onVerifyHostKey might throw (like UnknownHostKeyException) to avoid
    // crashing the test immediately if the mock key is not in storage.
    try {
      await onVerifyHostKey('ssh-ed25519', Uint8List.fromList(List.filled(32, 0xAB)));
    } catch (_) {
      // In tests, the host key might be unknown. The real SshConnector just
      // bubbles this up to FleetService, so we'll throw it here if needed,
      // but FleetService expects the connector itself to throw the SshException.
      rethrow;
    }

    return _successQueue.removeAt(0);
  }
}

class FakeSshTransport implements SshTransport {
  FakeSshTransport({
    this.failNextPing = false,
    this.runResultString = '',
    this.runDelay = Duration.zero,
  });

  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  int pingCount = 0;
  int closeCount = 0;
  bool failNextPing;
  String runResultString;
  Duration runDelay;

  @override
  Future<void> get authenticated async {}

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> ping() async {
    pingCount++;
    if (failNextPing) {
      failNextPing = false;
      throw Exception('Heartbeat ping failed: transport closed');
    }
  }

  @override
  void close() {
    closeCount++;
    if (_closed) return;
    _closed = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  @override
  Future<Uint8List> run(String command, {Map<String, String>? environment}) async {
    if (runDelay > Duration.zero) {
      await Future<void>.delayed(runDelay);
    }
    return Uint8List.fromList(runResultString.codeUnits);
  }

  @override
  Future<SSHSession> execute(String command, {Map<String, String>? environment}) =>
      throw UnimplementedError('FakeSshTransport.execute');

  @override
  Future<SSHSession> shell({SSHPtyConfig? pty}) =>
      throw UnimplementedError('FakeSshTransport.shell');

  @override
  Future<SSHForwardChannel> forwardLocal(String host, int port) =>
      throw UnimplementedError('FakeSshTransport.forwardLocal');
}

// ──────────────────────────────────────────────────────────────────────────────
//  Tests
// ──────────────────────────────────────────────────────────────────────────────

void main() {
  const dummyProfile = ServerProfile(
    id: 'server-1',
    name: 'Production',
    host: 'example.com',
    port: 22,
    username: 'root',
    password: 'password123',
  );

  const fakeMetricsOutput = '''
__HAMMA_CPU_BEGIN__
cpu  100000 0 50000 800000 0 0 0 0 0 0
cpu  100100 0 50100 801000 0 0 0 0 0 0
__HAMMA_RAM_BEGIN__
Mem:        8192        4096        4096
__HAMMA_DISK_BEGIN__
/dev/sda1        50000000 25000000 25000000  50% /
''';

  group('FleetService', () {
    test('pollServer returns valid metrics when transport returns valid data', () async {
      final connector = FakeSshConnector()
        ..enqueueSuccess(FakeSshTransport(runResultString: fakeMetricsOutput));
      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: dummyProfile.host,
        port: dummyProfile.port,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab',
        ),
      );

      final fleetService = FleetService(
        sshConnector: connector.call,
        trustedHostKeyStorage: storage,
      );

      final metrics = await fleetService.pollServer(dummyProfile);

      expect(metrics.isAvailable, isTrue);
      expect(metrics.cpuPercentage, isNotNull);
      expect(metrics.cpuPercentage, greaterThanOrEqualTo(0));
      expect(metrics.ramPercentage, 50.0);
      expect(metrics.diskPercentage, 50.0);
      expect(metrics.errorMessage, isNull);
    });

    test('pollServer handles TimeoutException properly', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(TimeoutException('connection timeout'));
      final storage = InMemoryTrustedHostKeyStorage();

      final fleetService = FleetService(
        sshConnector: connector.call,
        trustedHostKeyStorage: storage,
        connectTimeout: const Duration(milliseconds: 100), // Ensure fast timeout
      );

      final metrics = await fleetService.pollServer(dummyProfile);

      expect(metrics.isAvailable, isFalse);
      expect(metrics.errorMessage, 'Timed out while polling the server.');
    });

    test('executeBulkCommand correctly runs on multiple servers', () async {
      final server2 = dummyProfile.copyWith(id: 'server-2', host: 'test.com');

      final connector = FakeSshConnector()
        ..enqueueSuccess(FakeSshTransport(runResultString: 'Result 1'))
        ..enqueueSuccess(FakeSshTransport(runResultString: 'Result 2'));

      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: dummyProfile.host,
        port: dummyProfile.port,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab',
        ),
      );
      await storage.saveTrustedHostKey(
        host: server2.host,
        port: server2.port,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab',
        ),
      );

      final fleetService = FleetService(
        sshConnector: connector.call,
        trustedHostKeyStorage: storage,
      );

      final results = await fleetService.executeBulkCommand(
        [dummyProfile, server2],
        'echo hello'
      );

      expect(results.length, 2);
      expect(results['server-1'], 'Result 1');
      expect(results['server-2'], 'Result 2');
    });

    test('pollFleet correctly retrieves metrics for multiple servers', () async {
      final server2 = dummyProfile.copyWith(id: 'server-2', host: 'test.com');

      // Future.wait doesn't guarantee execution order. In tests, the calls may be
      // out of order. We can check the host in the connector or just queue two successes
      // since the logic is just MapEntry mapping. Let's make both successful to avoid
      // flakiness with queue order in Future.wait mapping.
      final connector = FakeSshConnector()
        ..enqueueSuccess(FakeSshTransport(runResultString: fakeMetricsOutput))
        ..enqueueSuccess(FakeSshTransport(runResultString: fakeMetricsOutput));

      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: dummyProfile.host,
        port: dummyProfile.port,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab',
        ),
      );
      await storage.saveTrustedHostKey(
        host: server2.host,
        port: server2.port,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab',
        ),
      );

      final fleetService = FleetService(
        sshConnector: connector.call,
        trustedHostKeyStorage: storage,
      );

      final metricsMap = await fleetService.pollFleet([dummyProfile, server2]);

      expect(metricsMap.length, 2);
      expect(metricsMap['server-1']!.isAvailable, isTrue);
      expect(metricsMap['server-2']!.isAvailable, isTrue);
    });
  });
}
