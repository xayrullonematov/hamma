/// Production-grade integration tests for the SSH state machine in
/// [SshService]. Driven entirely by hand-rolled fakes injected through
/// the constructor seam — no real socket, no real timers (in the
/// backoff-exhaustion test), no platform channels.
///
/// Synchronization in these tests is built on three primitives:
///
/// 1. [waitForState] — completion signal via the broadcast status
///    stream's `firstWhere`. Replaces ad-hoc microtask polling.
/// 2. [waitForCallCount] — completion signal via [FakeSshConnector]'s
///    `callEvents` stream. Lets a test await "the auto-reconnect loop
///    has just made its Nth attempt" without sleeping or guessing.
/// 3. `package:fake_async` — used in the backoff-exhaustion test to
///    advance the virtual clock past a real backoff schedule so we
///    actually exercise [Timer]-based backoff with realistic values.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/connection_status.dart';
import 'package:hamma/core/ssh/ssh_service.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

// ──────────────────────────────────────────────────────────────────────────────
//  Test doubles
// ──────────────────────────────────────────────────────────────────────────────

/// Pure in-memory [TrustedHostKeyStorage] for tests. Never touches
/// `flutter_secure_storage` — the abstract interface lets us drop in
/// this implementation without subclassing the secure backend.
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
///
/// Emits each call onto [callEvents] so tests can await the *Nth*
/// invocation as a completion signal instead of polling.
class FakeSshConnector {
  final List<_ConnectorResponse> _queue = [];
  final StreamController<int> _callsController =
      StreamController<int>.broadcast();
  int callCount = 0;
  final List<({String host, int port, String username})> calls = [];

  /// Broadcasts the new [callCount] after every connector invocation.
  Stream<int> get callEvents => _callsController.stream;

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
    _callsController.add(callCount);

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

  Future<void> dispose() => _callsController.close();
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

/// Default safety net for completion-signal helpers. Generous enough
/// that a healthy machine on a slow CI box will never trip it, tight
/// enough that a hung test fails in seconds rather than minutes.
const Duration _defaultWaitTimeout = Duration(seconds: 2);

/// Build a service wired with no-op keepalive and zero-second backoff
/// so `Timer(Duration(seconds:0), ...)` fires on the next event-loop
/// turn instead of in 5+ seconds. Used by every test except the
/// backoff-exhaustion test, which uses `fakeAsync` to drive a
/// realistic backoff schedule under a virtual clock.
SshService makeService({
  required FakeSshConnector connector,
  TrustedHostKeyStorage? storage,
  int maxReconnectAttempts = 5,
  List<int> reconnectBackoffSeconds = const [0, 0, 0, 0, 0],
}) {
  return SshService(
    connector: connector.call,
    trustedHostKeyStorage: storage ?? InMemoryTrustedHostKeyStorage(),
    enableBackgroundKeepalive: () async {},
    disableBackgroundKeepalive: () async {},
    reconnectBackoffSeconds: reconnectBackoffSeconds,
    maxReconnectAttempts: maxReconnectAttempts,
  );
}

/// Completion signal: returns a Future that completes when [service]'s
/// connection status reaches [target]. If the state has *already* been
/// reached, the future completes synchronously.
///
/// Times out (failing the test with a clear diagnostic) if the target
/// state is not reached within [timeout].
Future<ConnectionStatus> waitForState(
  SshService service,
  SshConnectionState target, {
  Duration timeout = _defaultWaitTimeout,
}) {
  if (service.currentStatus.state == target) {
    return Future.value(service.currentStatus);
  }
  return service.status
      .firstWhere((s) => s.state == target)
      .timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'waitForState($target) timed out after $timeout — '
          'last state was ${service.currentStatus.state}',
        ),
      );
}

/// Completion signal: returns a Future that completes when [connector]
/// has been invoked at least [n] times. If the connector has already
/// been called that many times, the future completes synchronously.
Future<void> waitForCallCount(
  FakeSshConnector connector,
  int n, {
  Duration timeout = _defaultWaitTimeout,
}) async {
  if (connector.callCount >= n) return;
  await connector.callEvents
      .firstWhere((c) => c >= n)
      .timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'waitForCallCount($n) timed out after $timeout — '
          'connector observed only ${connector.callCount} calls',
        ),
      );
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

  group('Constructor guards', () {
    test('throws ArgumentError when reconnectBackoffSeconds is empty', () {
      expect(
        () => SshService(reconnectBackoffSeconds: const []),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'reconnectBackoffSeconds',
          ),
        ),
      );
    });

    test(
        'throws ArgumentError when reconnectBackoffSeconds contains a '
        'negative entry', () {
      expect(
        () => SshService(reconnectBackoffSeconds: const [5, -1, 10]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'reconnectBackoffSeconds',
          ),
        ),
      );
    });

    test('throws ArgumentError when maxReconnectAttempts is negative', () {
      expect(
        () => SshService(maxReconnectAttempts: -1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'maxReconnectAttempts',
          ),
        ),
      );
    });

    test('accepts zero backoff entries (instant retry)', () {
      // [0] is a valid one-shot retry schedule and must not throw.
      expect(
        () => SshService(reconnectBackoffSeconds: const [0]),
        returnsNormally,
      );
    });

    test('accepts zero maxReconnectAttempts (no retries after first fail)',
        () {
      expect(
        () => SshService(maxReconnectAttempts: 0),
        returnsNormally,
      );
    });
  });

  group('State transitions — happy path', () {
    test('disconnected → connecting → connected on successful connect',
        () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      final transitions = <SshConnectionState>[];
      final sub = service.status.listen((s) => transitions.add(s.state));

      await connectDefault(service);
      await waitForState(service, SshConnectionState.connected);
      await sub.cancel();

      expect(service.currentStatus.state, SshConnectionState.connected);
      expect(transitions, contains(SshConnectionState.connecting));
      expect(transitions.last, SshConnectionState.connected);
      expect(connector.callCount, 1);
      expect(service.isConnected, isTrue);
      await connector.dispose();
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
      await connector.dispose();
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
      await connector.dispose();
    });

    test('successful connect arms the heartbeat timer', () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);

      expect(service.debugHasHeartbeat, isTrue);
      await service.disconnect();
      await connector.dispose();
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
      await connector.dispose();
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
      await connector.dispose();
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
      await connector.dispose();
    });

    test('timeout error is mapped to SshTimeoutException', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(TimeoutException('connect timeout'));
      final service = makeService(connector: connector);

      // Subscribe BEFORE the connect so we capture every transient
      // status — the post-failure auto-reconnect immediately overwrites
      // the failed state with reconnecting (which has no exception
      // field), so we have to look at the transition itself rather
      // than the latest snapshot.
      final exceptions = <SshException>[];
      final sub = service.status
          .where((s) => s.exception != null)
          .listen((s) => exceptions.add(s.exception!));

      await expectLater(connectDefault(service), throwsA(anything));
      // Completion signal: wait until the reconnecting status is
      // scheduled (which only happens AFTER the failed status was
      // emitted with the timeout exception).
      await waitForState(service, SshConnectionState.reconnecting);
      await sub.cancel();
      await service.disconnect();

      expect(
        exceptions.whereType<SshTimeoutException>(),
        isNotEmpty,
        reason: 'TimeoutException must be mapped to SshTimeoutException '
            'in at least one emitted status before auto-reconnect kicks in',
      );
      await connector.dispose();
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
      // Completion signal: wait for the auto-reconnect to actually
      // call the connector a second time, then for the resulting
      // status to settle on `connected`.
      await waitForCallCount(connector, 2);
      await waitForState(service, SshConnectionState.connected);

      expect(connector.callCount, 2);
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
      await connector.dispose();
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
      await waitForCallCount(connector, 2);
      await waitForState(service, SshConnectionState.connected);

      expect(connector.callCount, 2);
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
      await connector.dispose();
    });

    test('disabled auto-reconnect leaves state at disconnected after drop',
        () async {
      final t1 = FakeSshTransport();
      final connector = FakeSshConnector()..enqueueSuccess(t1);
      final service = makeService(connector: connector);

      await connectDefault(service);
      service.disableAutoReconnect();
      t1.simulateClosure();
      await waitForState(service, SshConnectionState.disconnected);

      expect(service.currentStatus.state, SshConnectionState.disconnected);
      expect(service.debugHasPendingReconnect, isFalse);
      await connector.dispose();
    });

    test(
        'consecutive failures up to maxReconnectAttempts → terminal failed',
        () {
      // Run under fake_async so we can use a realistic backoff
      // schedule and explicitly advance the virtual clock past every
      // retry timer instead of relying on zero-second timers.
      fakeAsync((async) {
        final connector = FakeSshConnector();
        for (var i = 0; i < 6; i++) {
          connector.enqueueFailure(const SocketException('still down'));
        }
        final service = SshService(
          connector: connector.call,
          trustedHostKeyStorage: InMemoryTrustedHostKeyStorage(),
          enableBackgroundKeepalive: () async {},
          disableBackgroundKeepalive: () async {},
          reconnectBackoffSeconds: const [1, 2, 4, 8, 16],
          maxReconnectAttempts: 5,
        );

        Object? caught;
        // Block-bodied onError returns void (matches Future<void>).
        // Arrow form would return the assigned value and fail the
        // type check inside Future.then.
        connectDefault(service).then((_) {}, onError: (Object e) {
          caught = e;
        });

        async.flushMicrotasks();
        expect(caught, isNotNull,
            reason: 'Initial connect attempt must reject');
        expect(connector.callCount, 1,
            reason: 'Only the manual attempt has fired so far');

        // Advance well past the cumulative backoff (1+2+4+8+16 = 31s).
        async.elapse(const Duration(seconds: 60));

        expect(connector.callCount, 6,
            reason: '1 manual + 5 auto-reconnect attempts = 6 calls');
        expect(service.currentStatus.state, SshConnectionState.failed);
        expect(service.currentStatus.exception, isA<SshUnknownException>());
        expect(
          service.currentStatus.exception?.userMessage,
          contains('Automatic reconnection failed'),
        );
        expect(service.debugHasPendingReconnect, isFalse);

        // Drain any close()/disconnect() futures the test created.
        connector.dispose();
        async.flushMicrotasks();
      });
    });

    test('successful reconnect resets the attempt counter', () async {
      final connector = FakeSshConnector()
        ..enqueueFailure(const SocketException('blip'))
        ..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await expectLater(connectDefault(service), throwsA(anything));
      await waitForCallCount(connector, 2);
      await waitForState(service, SshConnectionState.connected);

      expect(service.currentStatus.state, SshConnectionState.connected);
      expect(service.debugReconnectAttempts, 0);
      await service.disconnect();
      await connector.dispose();
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
      await connector.dispose();
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

      await waitForCallCount(connector, 2);
      expect(connector.callCount, 2);
      await service.disconnect();
      await connector.dispose();
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
      await connector.dispose();
    });

    test('heartbeat timer is cancelled on transport closure', () async {
      final t = FakeSshTransport();
      final connector = FakeSshConnector()
        ..enqueueSuccess(t)
        ..enqueueFailure(const SocketException('still down'));
      final service = makeService(connector: connector);

      await connectDefault(service);
      service.disableAutoReconnect();
      t.simulateClosure();
      await waitForState(service, SshConnectionState.disconnected);

      expect(service.debugHasHeartbeat, isFalse);
      await connector.dispose();
    });
  });

  group('Manual reconnect', () {
    test('reconnect() throws StateError when no prior connection', () async {
      final connector = FakeSshConnector();
      final service = makeService(connector: connector);

      await expectLater(service.reconnect(), throwsA(isA<StateError>()));
      await connector.dispose();
    });

    test('reconnect() reuses last credentials and increments attempt counter',
        () async {
      final connector = FakeSshConnector()
        ..enqueueSuccess(FakeSshTransport())
        ..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      await connectDefault(service);
      service.disableAutoReconnect();
      await service.reconnect();

      expect(connector.callCount, 2);
      expect(connector.calls[1].host, 'host.example');
      expect(connector.calls[1].username, 'alice');
      await service.disconnect();
      await connector.dispose();
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
      await connector.dispose();
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
          onTrustHostKey: ({
            required host,
            required port,
            required algorithm,
            required fingerprint,
          }) async =>
              false,
        ),
        throwsA(isA<SshUnknownHostKeyRejectedException>()),
      );

      expect(storage.savedCount, 0);
      expect(service.debugHasPendingReconnect, isFalse);
      await connector.dispose();
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
        onTrustHostKey: ({
          required host,
          required port,
          required algorithm,
          required fingerprint,
        }) async {
          callbackInvocations++;
          return true;
        },
      );

      expect(callbackInvocations, 1);
      expect(storage.savedCount, 1);
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
      await connector.dispose();
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
        onTrustHostKey: ({
          required host,
          required port,
          required algorithm,
          required fingerprint,
        }) async {
          callbackInvocations++;
          return true;
        },
      );

      expect(callbackInvocations, 0,
          reason: 'Callback must NOT fire when fingerprint matches storage');
      expect(service.currentStatus.state, SshConnectionState.connected);
      await service.disconnect();
      await connector.dispose();
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
          onTrustHostKey: ({
            required host,
            required port,
            required algorithm,
            required fingerprint,
          }) async =>
              true,
        ),
        throwsA(isA<SshHostKeyMismatchException>()),
      );

      expect(service.debugHasPendingReconnect, isFalse,
          reason: 'Host-key mismatches must never trigger auto-reconnect');
      await connector.dispose();
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
      await connector.dispose();
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
      await waitForState(service, SshConnectionState.connected);

      expect(aEvents, isNotEmpty);
      expect(bEvents, isNotEmpty);
      expect(aEvents, equals(bEvents));

      await subA.cancel();
      await subB.cancel();
      await service.disconnect();
      await connector.dispose();
    });

    test('connectionState stream emits booleans matching isConnected',
        () async {
      final connector = FakeSshConnector()..enqueueSuccess(FakeSshTransport());
      final service = makeService(connector: connector);

      final bools = <bool>[];
      final sub = service.connectionState.listen(bools.add);

      await connectDefault(service);
      await waitForState(service, SshConnectionState.connected);
      await service.disconnect();
      await waitForState(service, SshConnectionState.disconnected);
      await sub.cancel();

      expect(bools, contains(true));
      expect(bools.last, isFalse);
      await connector.dispose();
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
      await connector.dispose();
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
      await connector.dispose();
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
