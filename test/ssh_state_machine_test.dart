import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/connection_status.dart';
import 'package:hamma/core/ssh/ssh_service.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

// ──────────────────────────────────────────────────────────────────────────────
//  Test doubles
// ──────────────────────────────────────────────────────────────────────────────

/// In-memory replacement for [TrustedHostKeyStorage] — extends the
/// concrete class but overrides every public method so the
/// flutter_secure_storage backend is never actually touched (which
/// would require platform channels in unit tests).
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

/// One scripted response in the [FakeSshConnector] queue.
class _ConnectorResponse {
  _ConnectorResponse.success(this.transport)
      : error = null,
        verifyHostKey = null,
        verifyHostKeyArgs = null;

  _ConnectorResponse.failure(this.error)
      : transport = null,
        verifyHostKey = null,
        verifyHostKeyArgs = null;

  /// On call, invoke the host-key callback with these args before
  /// resolving with [transport]. Used to drive the host-key flow
  /// from the connector side without needing a real handshake.
  _ConnectorResponse.successWithHostKeyVerification({
    required this.transport,
    required this.verifyHostKeyArgs,
  })  : error = null,
        verifyHostKey = true;

  final FakeSshTransport? transport;
  final Object? error;
  final bool? verifyHostKey;
  final ({String algorithm, Uint8List fingerprint})? verifyHostKeyArgs;
}

/// Records every call into the connector and replays a scripted queue
/// of responses (success / failure / success-after-host-key-check).
class FakeSshConnector {
  final List<_ConnectorResponse> _queue = [];
  int callCount = 0;
  final List<({String host, int port, String username})> calls = [];

  void enqueueSuccess(FakeSshTransport transport) {
    _queue.add(_ConnectorResponse.success(transport));
  }

  void enqueueFailure(Object error) {
    _queue.add(_ConnectorResponse.failure(error));
  }

  void enqueueSuccessAfterHostKeyCheck({
    required FakeSshTransport transport,
    String algorithm = 'ssh-ed25519',
    Uint8List? fingerprint,
  }) {
    _queue.add(_ConnectorResponse.successWithHostKeyVerification(
      transport: transport,
      verifyHostKeyArgs: (
        algorithm: algorithm,
        fingerprint: fingerprint ?? Uint8List.fromList(List.filled(32, 0xAB)),
      ),
    ));
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
    if (callCount >= _queue.length) {
      throw StateError(
        'FakeSshConnector: unexpected call #${callCount + 1} '
        '(only ${_queue.length} responses queued)',
      );
    }
    final response = _queue[callCount++];

    if (response.error != null) {
      throw response.error!;
    }

    if (response.verifyHostKey == true) {
      // Drive the host-key callback first, propagate any exception
      // it raises (so unknown / rejected / mismatch flows surface to
      // the state machine).
      await onVerifyHostKey(
        response.verifyHostKeyArgs!.algorithm,
        response.verifyHostKeyArgs!.fingerprint,
      );
    }

    return response.transport!;
  }
}

/// A minimal in-memory [SshTransport] for state-machine tests.
class FakeSshTransport implements SshTransport {
  FakeSshTransport({this.failNextPing = false});

  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  int pingCount = 0;
  int closeCount = 0;
  bool failNextPing;

  @override
  Future<void> get authenticated async {
    // Real SSHClient.authenticated resolves once auth completes; in
    // tests we always get it back already-authenticated because our
    // connector only returns the transport after success.
  }

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

  /// Simulates a clean transport closure (e.g., `client.done` resolving
  /// because the remote peer closed the connection).
  void simulateClosure() {
    if (_closed) return;
    _closed = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  /// Simulates an erroring transport closure (e.g., `client.done`
  /// completing with an error because the socket dropped).
  void simulateError(Object error) {
    if (_closed) return;
    _closed = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.completeError(error);
  }

  bool get isClosed => _closed;

  // Command/forwarding methods are unused by the state machine. Tests
  // that exercise execute/shell/forwardLocal need their own fakes.
  @override
  Future<Uint8List> run(String command) =>
      throw UnimplementedError('FakeSshTransport.run');

  @override
  Future<SSHSession> execute(String command) =>
      throw UnimplementedError('FakeSshTransport.execute');

  @override
  Future<SSHSession> shell({SSHPtyConfig? pty}) =>
      throw UnimplementedError('FakeSshTransport.shell');

  @override
  Future<SSHForwardChannel> forwardLocal(String host, int port) =>
      throw UnimplementedError('FakeSshTransport.forwardLocal');
}

// ──────────────────────────────────────────────────────────────────────────────
//  Test helpers
// ──────────────────────────────────────────────────────────────────────────────

/// Build a service wired with no-op keepalive and zero-second backoff
/// so `Timer(Duration(seconds:0), ...)` fires on the next event-loop
/// turn instead of in 5+ seconds.
SshService makeService({
  required FakeSshConnector connector,
  TrustedHostKeyStorage? storage,
  int maxReconnectAttempts = 5,
}) {
  return SshService(
    connector: connector.call,
    trustedHostKeyStorage: storage ?? InMemoryTrustedHostKeyStorage(),
    enableBackgroundKeepalive: () async {},
    disableBackgroundKeepalive: () async {},
    reconnectBackoffSeconds: const [0, 0, 0, 0, 0],
    maxReconnectAttempts: maxReconnectAttempts,
  );
}

/// Run the event loop until all pending microtasks and zero-delay
/// timers have fired. Repeated a few times to flush chained timers
/// (the auto-reconnect loop schedules a timer that itself awaits a
/// connect that may schedule another timer).
Future<void> drain([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> connectDefault(SshService service) =>
    service.connect(
      host: 'host.example',
      port: 22,
      username: 'alice',
      password: 'pw',
    );

// ──────────────────────────────────────────────────────────────────────────────
//  Tests
// ──────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SshService.debugClearInstances();
  });

  group('State transitions — happy path', () {
    test('disconnected → connecting → connected on successful connect',
        () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      final transitions = <SshConnectionState>[];
      final sub = service.status.listen((s) => transitions.add(s.state));

      await connectDefault(service);

      // Allow the listener microtask to drain.
      await drain();
      await sub.cancel();

      expect(service.currentStatus.state, SshConnectionState.connected);
      expect(transitions, contains(SshConnectionState.connecting));
      expect(transitions.last, SshConnectionState.connected);
      expect(connector.callCount, 1);
      expect(service.isConnected, isTrue);
    });

    test('connect populates lastSuccessfulConnection timestamp', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      final before = DateTime.now();
      await connectDefault(service);
      final after = DateTime.now();

      final ts = service.currentStatus.lastSuccessfulConnection;
      expect(ts, isNotNull);
      expect(ts!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(ts.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('connected → disconnected on explicit disconnect()', () async {
      final transport = FakeSshTransport();
      final connector = FakeSshConnector()..enqueueSuccess(transport);
      final service = makeService(connector: connector);

      await connectDefault(service);
      await service.disconnect();

      expect(service.currentStatus.state, SshConnectionState.disconnected);
      expect(transport.closeCount, greaterThanOrEqualTo(1));
      expect(service.debugHasHeartbeat, isFalse);
      expect(service.debugHasPendingReconnect, isFalse);
    });

    test('successful connect arms the heartbeat timer', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);

      expect(service.debugHasHeartbeat, isTrue);
      await service.disconnect();
    });
  });

  group('State transitions — failure paths', () {
    test('network failure → failed → schedules auto-reconnect', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(const SocketException('Connection refused'));
      final service = makeService(connector: connector);

      await expectLater(connectDefault(service), throwsA(isA<Exception>()));

      expect(service.currentStatus.state, SshConnectionState.reconnecting,
          reason: 'After a recoverable failure, _triggerAutoReconnect '
              'immediately moves the status to reconnecting');
      expect(service.debugHasPendingReconnect, isTrue);
      await service.disconnect();
    });

    test(
        'authentication failure → failed → does NOT schedule auto-reconnect',
        () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(Exception('authentication failed'));
      final service = makeService(connector: connector);

      await expectLater(connectDefault(service), throwsA(isA<Exception>()));

      expect(service.currentStatus.state, SshConnectionState.failed);
      expect(service.currentStatus.exception,
          isA<SshAuthenticationException>());
      expect(service.debugHasPendingReconnect, isFalse,
          reason: 'Auth failures must never trigger auto-reconnect');
    });

    test('host-key rejection → failed → does NOT schedule auto-reconnect',
        () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(const SshUnknownHostKeyRejectedException(
          host: 'host.example',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: 'SHA256:abc',
        ));
      final service = makeService(connector: connector);

      await expectLater(
        connectDefault(service),
        throwsA(isA<SshHostKeyException>()),
      );

      expect(service.currentStatus.state, SshConnectionState.failed);
      expect(service.debugHasPendingReconnect, isFalse,
          reason: 'Host-key issues must never trigger auto-reconnect');
    });

    test('timeout error is mapped to SshTimeoutException', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(TimeoutException('connect timeout'));
      final service = makeService(connector: connector);

      // Capture the stream because the post-failure auto-reconnect
      // immediately overwrites the failed state with a reconnecting
      // state (which has no exception field), so we have to look at
      // the transition itself rather than the latest snapshot.
      final exceptions = <SshException?>[];
      final sub = service.status.listen((s) => exceptions.add(s.exception));

      await expectLater(connectDefault(service), throwsA(anything));
      await drain();
      await sub.cancel();
      await service.disconnect();

      expect(
        exceptions.whereType<SshTimeoutException>(),
        isNotEmpty,
        reason: 'TimeoutException must be mapped to SshTimeoutException '
            'in at least one emitted status before auto-reconnect kicks in',
      );
    });
  });

  group('Auto-reconnect — backoff & retry loop', () {
    test('clean transport closure triggers reconnect when auto enabled',
        () async {
      final t1 = FakeSshTransport();
      final t2 = FakeSshTransport();
      final connector = FakeSshConnector()
        ..enqueueSuccess(t1)
        ..enqueueSuccess(t2);
      final service = makeService(connector: connector);

      await connectDefault(service);
      expect(service.currentStatus.state, SshConnectionState.connected);

      t1.simulateClosure();
      // Drain so the .then on done fires → _handleDisconnect →
      // _triggerAutoReconnect → Timer(0) → reconnect → connect → success.
      await drain(10);

      expect(connector.callCount, 2);
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
    });

    test('errored transport closure triggers reconnect when auto enabled',
        () async {
      final t1 = FakeSshTransport();
      final t2 = FakeSshTransport();
      final connector = FakeSshConnector()
        ..enqueueSuccess(t1)
        ..enqueueSuccess(t2);
      final service = makeService(connector: connector);

      await connectDefault(service);
      t1.simulateError(const SocketException('reset by peer'));
      await drain(10);

      expect(connector.callCount, 2);
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
    });

    test('disabled auto-reconnect leaves state at disconnected after drop',
        () async {
      final t1 = FakeSshTransport();
      final connector = FakeSshConnector()..enqueueSuccess(t1);
      final service = makeService(connector: connector);

      await connectDefault(service);
      service.disableAutoReconnect();
      t1.simulateClosure();
      await drain();

      expect(service.currentStatus.state, SshConnectionState.disconnected);
      expect(service.debugHasPendingReconnect, isFalse);
    });

    test(
        'consecutive failures up to maxReconnectAttempts → terminal failed',
        () async {
      // 1 manual failed + 5 retry attempts (cap = 5) all fail.
      final connector = FakeSshConnector();
      for (var i = 0; i < 6; i++) {
        connector.enqueueFailure(const SocketException('still down'));
      }
      final service = makeService(connector: connector, maxReconnectAttempts: 5);

      await expectLater(connectDefault(service), throwsA(anything));
      // Now drain repeatedly so each scheduled Timer(0) fires and the
      // next reconnect fails again.
      for (var i = 0; i < 10; i++) {
        await drain();
      }

      expect(connector.callCount, 6,
          reason: '1 manual + 5 auto-reconnect attempts = 6 connector calls');
      expect(service.currentStatus.state, SshConnectionState.failed);
      expect(service.currentStatus.exception, isA<SshUnknownException>());
      expect(
        service.currentStatus.exception?.userMessage,
        contains('Automatic reconnection failed'),
      );
      expect(service.debugHasPendingReconnect, isFalse);
    });

    test('successful reconnect resets the attempt counter', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(const SocketException('blip'))
        ..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await expectLater(connectDefault(service), throwsA(anything));
      await drain(10);

      expect(service.currentStatus.state, SshConnectionState.connected);
      expect(service.debugReconnectAttempts, 0);
      await service.disconnect();
    });

    test('disableAutoReconnect cancels a pending reconnect timer', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(const SocketException('down'));
      final service = makeService(connector: connector);

      await expectLater(connectDefault(service), throwsA(anything));
      expect(service.debugHasPendingReconnect, isTrue);

      service.disableAutoReconnect();

      expect(service.debugHasPendingReconnect, isFalse);
      expect(service.autoReconnectEnabled, isFalse);
    });

    test('enableAutoReconnect re-arms after disconnect with prior host',
        () async {
      final connector = FakeSshConnector()
        ..enqueueSuccess(FakeSshTransport())
        ..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);
      service.disableAutoReconnect();
      await service.disconnect();

      expect(service.currentStatus.state, SshConnectionState.disconnected);

      service.enableAutoReconnect();
      expect(service.debugHasPendingReconnect, isTrue,
          reason: 'enableAutoReconnect must re-arm a reconnect timer when '
              'we are disconnected and have a known last host');

      await drain(10);
      expect(connector.callCount, 2);
      await service.disconnect();
    });
  });

  group('Heartbeat', () {
    test('heartbeat timer is cancelled on disconnect', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);
      expect(service.debugHasHeartbeat, isTrue);

      await service.disconnect();
      expect(service.debugHasHeartbeat, isFalse);
    });

    test('heartbeat timer is cancelled on transport closure', () async {
      final t = FakeSshTransport();
      final connector = FakeSshConnector()
        ..enqueueSuccess(t)
        ..enqueueFailure(const SocketException('still down'));
      // Disable auto-reconnect path quickly by using a service with
      // auto-reconnect disabled after first connect.
      final service = makeService(connector: connector);

      await connectDefault(service);
      service.disableAutoReconnect();
      t.simulateClosure();
      await drain();

      expect(service.debugHasHeartbeat, isFalse);
    });
  });

  group('Manual reconnect', () {
    test('reconnect() throws StateError when no prior connection', () async {
      final connector = FakeSshConnector();
      final service = makeService(connector: connector);

      await expectLater(service.reconnect(), throwsA(isA<StateError>()));
    });

    test('reconnect() reuses last credentials and increments attempt counter',
        () async {
      final connector = FakeSshConnector()
        ..enqueueSuccess(FakeSshTransport())
        ..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);
      // Force the next reconnect to look like a retry by leaving the
      // current state at "reconnecting".
      service.disableAutoReconnect();
      await service.reconnect();

      expect(connector.callCount, 2);
      expect(connector.calls[1].host, 'host.example');
      expect(connector.calls[1].username, 'alice');
      await service.disconnect();
    });
  });

  group('Host-key verification flow', () {
    test('first connection with no trusted key and no callback throws '
        'SshUnknownHostKeyException', () async {
      final storage = InMemoryTrustedHostKeyStorage();
      final connector = FakeSshConnector()
        ..enqueueSuccessAfterHostKeyCheck(
          transport: FakeSshTransport(),
          fingerprint: Uint8List.fromList(List.filled(32, 0xCA)),
        );
      final service = makeService(connector: connector, storage: storage);

      // No onTrustHostKey callback supplied.
      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'alice',
          password: 'pw',
        ),
        throwsA(isA<SshUnknownHostKeyException>()),
      );

      expect(storage.savedCount, 0);
      expect(service.currentStatus.exception, isA<SshHostKeyException>());
      expect(service.debugHasPendingReconnect, isFalse);
    });

    test(
        'first connection with callback returning false throws '
        'SshUnknownHostKeyRejectedException and does not save', () async {
      final storage = InMemoryTrustedHostKeyStorage();
      final connector = FakeSshConnector()
        ..enqueueSuccessAfterHostKeyCheck(
          transport: FakeSshTransport(),
        );
      final service = makeService(connector: connector, storage: storage);

      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'alice',
          password: 'pw',
          onTrustHostKey: ({required host, required port, required algorithm, required fingerprint}) async => false,
        ),
        throwsA(isA<SshUnknownHostKeyRejectedException>()),
      );

      expect(storage.savedCount, 0);
      expect(service.debugHasPendingReconnect, isFalse);
    });

    test(
        'first connection with callback returning true saves the key '
        'and reaches connected', () async {
      final storage = InMemoryTrustedHostKeyStorage();
      final connector = FakeSshConnector()
        ..enqueueSuccessAfterHostKeyCheck(transport: FakeSshTransport());
      final service = makeService(connector: connector, storage: storage);

      var callbackInvocations = 0;
      await service.connect(
        host: 'host.example',
        port: 22,
        username: 'alice',
        password: 'pw',
        onTrustHostKey: ({required host, required port, required algorithm, required fingerprint}) async {
          callbackInvocations++;
          return true;
        },
      );

      expect(callbackInvocations, 1);
      expect(storage.savedCount, 1);
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
    });

    test(
        'subsequent connection with matching trusted key does NOT call the '
        'callback', () async {
      final storage = InMemoryTrustedHostKeyStorage();
      final fingerprint = Uint8List.fromList(List.filled(32, 0xAB));

      // Pre-seed the storage with the same fingerprint the connector
      // will report. SHA256:<base64 of 32 bytes without padding>.
      const trustedFingerprint =
          'SHA256:q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s';
      await storage.saveTrustedHostKey(
        host: 'host.example',
        port: 22,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: trustedFingerprint,
        ),
      );

      final connector = FakeSshConnector()
        ..enqueueSuccessAfterHostKeyCheck(
          transport: FakeSshTransport(),
          algorithm: 'ssh-ed25519',
          fingerprint: fingerprint,
        );
      final service = makeService(connector: connector, storage: storage);

      var callbackInvocations = 0;
      await service.connect(
        host: 'host.example',
        port: 22,
        username: 'alice',
        password: 'pw',
        onTrustHostKey: ({required host, required port, required algorithm, required fingerprint}) async {
          callbackInvocations++;
          return true;
        },
      );

      expect(callbackInvocations, 0,
          reason: 'Callback must NOT fire when fingerprint matches storage');
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
    });

    test(
        'subsequent connection with mismatched key throws '
        'SshHostKeyMismatchException', () async {
      final storage = InMemoryTrustedHostKeyStorage();
      await storage.saveTrustedHostKey(
        host: 'host.example',
        port: 22,
        record: const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'SHA256:OLDFINGERPRINT',
        ),
      );

      final connector = FakeSshConnector()
        ..enqueueSuccessAfterHostKeyCheck(
          transport: FakeSshTransport(),
          fingerprint: Uint8List.fromList(List.filled(32, 0xFF)),
        );
      final service = makeService(connector: connector, storage: storage);

      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'alice',
          password: 'pw',
          onTrustHostKey: ({required host, required port, required algorithm, required fingerprint}) async => true,
        ),
        throwsA(isA<SshHostKeyMismatchException>()),
      );

      expect(service.debugHasPendingReconnect, isFalse,
          reason: 'Host-key mismatches must never trigger auto-reconnect');
    });
  });

  group('Status stream & ValueNotifier', () {
    test('ValueNotifier reflects the most recent status', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      expect(service.statusNotifier.value.state,
          SshConnectionState.disconnected);

      await connectDefault(service);
      expect(service.statusNotifier.value.state, SshConnectionState.connected);

      await service.disconnect();
      expect(service.statusNotifier.value.state,
          SshConnectionState.disconnected);
    });

    test('status stream is broadcast — multiple listeners receive events',
        () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      final aEvents = <SshConnectionState>[];
      final bEvents = <SshConnectionState>[];
      final subA = service.status.listen((s) => aEvents.add(s.state));
      final subB = service.status.listen((s) => bEvents.add(s.state));

      await connectDefault(service);
      await drain();

      expect(aEvents, isNotEmpty);
      expect(bEvents, isNotEmpty);
      expect(aEvents, equals(bEvents));

      await subA.cancel();
      await subB.cancel();
      await service.disconnect();
    });

    test('connectionState stream emits booleans matching isConnected',
        () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      final bools = <bool>[];
      final sub = service.connectionState.listen(bools.add);

      await connectDefault(service);
      await drain();
      await service.disconnect();
      await drain();
      await sub.cancel();

      expect(bools, contains(true));
      expect(bools.last, isFalse);
    });
  });

  group('isHealthy', () {
    test('returns false when no transport is connected', () {
      final service = makeService(connector: FakeSshConnector());
      expect(service.isHealthy(), isFalse);
    });

    test('returns true after a successful connect', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);
      expect(service.isHealthy(), isTrue);
      await service.disconnect();
    });
  });

  group('Active forwards', () {
    test('activeForwardedPorts is empty by default', () {
      final service = makeService(connector: FakeSshConnector());
      expect(service.activeForwardedPorts, isEmpty);
    });

    test('disconnect clears any active forwarded ports list', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);
      await connectDefault(service);

      expect(service.activeForwardedPorts, isEmpty);
      await service.disconnect();
      expect(service.activeForwardedPorts, isEmpty);
    });
  });

  group('Server registry (forServer / removeInstance)', () {
    test('forServer returns the same instance for the same id', () {
      final a = SshService.forServer('server-1');
      final b = SshService.forServer('server-1');
      expect(identical(a, b), isTrue);
    });

    test('forServer returns different instances for different ids', () {
      final a = SshService.forServer('server-1');
      final b = SshService.forServer('server-2');
      expect(identical(a, b), isFalse);
    });

    test('removeInstance allows a fresh instance for the same id', () {
      final a = SshService.forServer('server-1');
      SshService.removeInstance('server-1');
      final b = SshService.forServer('server-1');
      expect(identical(a, b), isFalse);
    });
  });

  group('Command APIs require a live transport', () {
    test('execute() throws StateError when not connected', () async {
      final service = makeService(connector: FakeSshConnector());
      await expectLater(
        service.execute('ls'),
        throwsA(isA<StateError>()),
      );
    });

    test('streamCommand() throws StateError when not connected', () async {
      final service = makeService(connector: FakeSshConnector());
      await expectLater(
        service.streamCommand('ls'),
        throwsA(isA<StateError>()),
      );
    });

    test('startShell() throws StateError when not connected', () async {
      final service = makeService(connector: FakeSshConnector());
      await expectLater(
        service.startShell(),
        throwsA(isA<StateError>()),
      );
    });

    test('startLocalForwarding() throws StateError when not connected',
        () async {
      final service = makeService(connector: FakeSshConnector());
      await expectLater(
        service.startLocalForwarding(
          localPort: 12345,
          remoteHost: 'remote',
          remotePort: 80,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
