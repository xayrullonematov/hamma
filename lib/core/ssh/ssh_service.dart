import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:pointycastle/export.dart' as pc;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../background/background_keepalive.dart';
import '../storage/trusted_host_key_storage.dart';
import '../vault/vault_injector.dart';
import '../vault/vault_secret.dart';
import 'connection_status.dart';
import 'ssh_exception.dart';
import 'ssh_transport.dart';

export 'ssh_exception.dart';
export 'ssh_transport.dart' show SshTransport, SshConnector, DartSsh2Transport;

/// Default backoff schedule (in seconds) used by the auto-reconnect
/// loop. Exposed so tests can replace it with `[0, 0, 0, 0, 0]` for
/// deterministic, instantaneous retries.
const List<int> kDefaultReconnectBackoffSeconds = [5, 10, 20, 30, 60];

/// Maximum number of consecutive auto-reconnect attempts before
/// giving up and entering the terminal `failed` state.
const int kDefaultMaxReconnectAttempts = 5;

class SshService {
  static final Map<String, SshService> _instances = {};

  /// Gets or creates a shared SshService instance for a specific server.
  static SshService forServer(String serverId) {
    return _instances.putIfAbsent(serverId, () => SshService());
  }

  /// Removes a server instance from the registry.
  static void removeInstance(String serverId) {
    _instances.remove(serverId);
  }

  /// Test-only: clears the entire instance registry. Use in `setUp`
  /// of tests that exercise [forServer] / [removeInstance].
  @visibleForTesting
  static void debugClearInstances() {
    _instances.clear();
  }

  /// All constructor parameters are optional and default to the real
  /// production wiring; tests inject fakes for the connector and the
  /// background-keepalive callbacks, and a zeroed backoff schedule
  /// to keep the auto-reconnect timer fast.
  ///
  /// Throws [ArgumentError] if [reconnectBackoffSeconds] is non-null
  /// but empty (the auto-reconnect loop would index past the end on
  /// the first retry), if any backoff entry is negative (Dart's
  /// [Timer] does not accept negative durations), or if
  /// [maxReconnectAttempts] is negative.
  SshService({
    TrustedHostKeyStorage? trustedHostKeyStorage,
    SshConnector? connector,
    Future<void> Function()? enableBackgroundKeepalive,
    Future<void> Function()? disableBackgroundKeepalive,
    List<int>? reconnectBackoffSeconds,
    int maxReconnectAttempts = kDefaultMaxReconnectAttempts,
  })  : _trustedHostKeyStorage =
            trustedHostKeyStorage ?? const SecureTrustedHostKeyStorage(),
        _connector = connector ?? defaultSshConnector,
        _enableBackgroundKeepalive =
            enableBackgroundKeepalive ?? BackgroundKeepalive.enable,
        _disableBackgroundKeepalive =
            disableBackgroundKeepalive ?? BackgroundKeepalive.disable,
        _backoffSeconds =
            reconnectBackoffSeconds ?? kDefaultReconnectBackoffSeconds,
        _maxReconnectAttempts = maxReconnectAttempts {
    if (reconnectBackoffSeconds != null && reconnectBackoffSeconds.isEmpty) {
      throw ArgumentError.value(
        reconnectBackoffSeconds,
        'reconnectBackoffSeconds',
        'must contain at least one entry; the auto-reconnect loop '
            'reads index 0 on the first retry',
      );
    }
    if (reconnectBackoffSeconds != null &&
        reconnectBackoffSeconds.any((s) => s < 0)) {
      throw ArgumentError.value(
        reconnectBackoffSeconds,
        'reconnectBackoffSeconds',
        'all entries must be non-negative seconds',
      );
    }
    if (maxReconnectAttempts < 0) {
      throw ArgumentError.value(
        maxReconnectAttempts,
        'maxReconnectAttempts',
        'must be non-negative (0 disables auto-reconnect retries '
            'after the initial failure)',
      );
    }
    _statusNotifier = ValueNotifier<ConnectionStatus>(_currentStatus);
  }

  SshTransport? _transport;
  final Map<int, ServerSocket> _activeForwards = {};
  final TrustedHostKeyStorage _trustedHostKeyStorage;
  final SshConnector _connector;
  final Future<void> Function() _enableBackgroundKeepalive;
  final Future<void> Function() _disableBackgroundKeepalive;
  final List<int> _backoffSeconds;
  final int _maxReconnectAttempts;

  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();
  late final ValueNotifier<ConnectionStatus> _statusNotifier;
  ConnectionStatus _currentStatus = ConnectionStatus.disconnected();
  int _reconnectAttempts = 0;
  bool _autoReconnectEnabled = true;
  DateTime? _lastSuccessfulConnection;

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  // Store last connection parameters for reconnection
  String? _lastHost;
  int? _lastPort;
  String? _lastUsername;
  String? _lastPassword;
  String? _lastPrivateKey;
  String? _lastPrivateKeyPassword;
  Future<bool> Function({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  })? _lastOnTrustHostKey;

  bool get isConnected => _currentStatus.isConnected;
  Stream<ConnectionStatus> get status => _statusController.stream;
  ConnectionStatus get currentStatus => _currentStatus;
  ValueListenable<ConnectionStatus> get statusNotifier => _statusNotifier;
  bool get autoReconnectEnabled => _autoReconnectEnabled;

  // Keep the old stream for backward compatibility if needed, but updated to emits bools based on status
  Stream<bool> get connectionState => status.map((s) => s.isConnected);

  List<int> get activeForwardedPorts => _activeForwards.keys.toList();

  /// Test-only: current consecutive reconnect attempt count.
  @visibleForTesting
  int get debugReconnectAttempts => _reconnectAttempts;

  /// Test-only: whether an auto-reconnect timer is currently armed.
  @visibleForTesting
  bool get debugHasPendingReconnect => _reconnectTimer?.isActive ?? false;

  /// Test-only: whether the heartbeat timer is currently armed.
  @visibleForTesting
  bool get debugHasHeartbeat => _heartbeatTimer?.isActive ?? false;

  void _updateStatus(ConnectionStatus status) {
    _currentStatus = status;
    _statusController.add(status);
    _statusNotifier.value = status;
  }

  SshException _mapError(dynamic e) {
    if (e is SshException) return e;

    final message = e.toString().toLowerCase();

    if (e is SocketException) {
      if (message.contains('timed out')) {
        return SshTimeoutException(originalError: e);
      }
      return SshNetworkException(
        userMessage: 'Could not reach the server.',
        suggestedAction: 'Check your internet connection and the server address.',
        originalError: e,
      );
    }

    if (message.contains('handshake failed') || message.contains('connection reset')) {
      return SshNetworkException(
        userMessage: 'The connection was interrupted during handshake.',
        suggestedAction: 'This can happen due to poor network or server-side firewall.',
        originalError: e,
      );
    }

    if (message.contains('authentication failed') || message.contains('access denied')) {
      return SshAuthenticationException(
        userMessage: 'Authentication failed.',
        suggestedAction: 'Verify your username, password, or private key.',
        originalError: e,
      );
    }

    if (e is TimeoutException || message.contains('timeout') || message.contains('timed out')) {
      return SshTimeoutException(originalError: e);
    }

    return SshUnknownException(
      userMessage: 'An unexpected SSH error occurred.',
      suggestedAction: 'Try again later or contact support if the issue persists.',
      originalError: e,
    );
  }

  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required String password,
    String? privateKey,
    String? privateKeyPassword,
    Future<bool> Function({
      required String host,
      required int port,
      required String algorithm,
      required String fingerprint,
    })?
    onTrustHostKey,
  }) async {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Connecting to SSH host',
        category: 'ssh',
        data: {'host': host, 'port': port, 'username': username},
      ),
    );

    // If this is a fresh manual connection (not from reconnect loop), reset attempts
    if (_currentStatus.state != SshConnectionState.reconnecting) {
      _reconnectAttempts = 0;
      _updateStatus(ConnectionStatus.connecting());
    }

    // Connect always cancels any pending auto-reconnect timer
    cancelAutoReconnect();

    // Cleanup existing transport if any
    await disconnect(updateStatus: false, cancelAuto: true);

    _lastHost = host;
    _lastPort = port;
    _lastUsername = username;
    _lastPassword = password;
    _lastPrivateKey = privateKey;
    _lastPrivateKeyPassword = privateKeyPassword;
    _lastOnTrustHostKey = onTrustHostKey;

    try {
      final trustedHostKey = await _trustedHostKeyStorage.loadTrustedHostKey(
        host: host,
        port: port,
      );

      // Build the dartssh2-style host-key callback. The state machine
      // owns this closure (rather than the connector) so the user-
      // prompt + storage logic is exercised by SshService unit tests.
      Future<bool> onVerifyHostKey(
        String algorithm,
        Uint8List fingerprintBytes,
      ) async {
        final fingerprint = _formatFingerprint(fingerprintBytes);

        if (trustedHostKey == null) {
          if (onTrustHostKey == null) {
            throw SshUnknownHostKeyException(
              host: host,
              port: port,
              algorithm: algorithm,
              fingerprint: fingerprint,
            );
          }

          final accepted = await onTrustHostKey(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint,
          );
          if (!accepted) {
            throw SshUnknownHostKeyRejectedException(
              host: host,
              port: port,
              algorithm: algorithm,
              fingerprint: fingerprint,
            );
          }

          await _trustedHostKeyStorage.saveTrustedHostKey(
            host: host,
            port: port,
            record: TrustedHostKeyRecord(
              algorithm: algorithm,
              fingerprint: fingerprint,
            ),
          );
          return true;
        }

        final isTrustedFingerprint =
            trustedHostKey.fingerprint == fingerprint &&
            trustedHostKey.algorithm == algorithm;
        if (isTrustedFingerprint) {
          return true;
        }

        throw SshHostKeyMismatchException(
          host: host,
          port: port,
          expectedAlgorithm: trustedHostKey.algorithm,
          expectedFingerprint: trustedHostKey.fingerprint,
          actualAlgorithm: algorithm,
          actualFingerprint: fingerprint,
        );
      }

      final transport = await _connector(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKey: privateKey,
        privateKeyPassword: privateKeyPassword,
        onVerifyHostKey: onVerifyHostKey,
      );

      try {
        await _enableBackgroundKeepalive();
      } catch (_) {
        transport.close();
        rethrow;
      }
      _transport = transport;
      _reconnectAttempts = 0; // Reset on true success
      _lastSuccessfulConnection = DateTime.now();

      // Detect transport closure immediately — covers network drops, server
      // reboots, and any case where the underlying socket closes without an
      // explicit call to disconnect().
      transport.done.then((_) {
        _handleDisconnect(reason: 'Transport closed');
      }, onError: (_) {
        _handleDisconnect(reason: 'Transport error');
      });

      _startHeartbeat();
      _updateStatus(ConnectionStatus.connected(lastSuccessfulConnection: _lastSuccessfulConnection));
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      final sshError = _mapError(e);
      _updateStatus(ConnectionStatus.failed(sshError, lastSuccessfulConnection: _lastSuccessfulConnection));

      // Trigger auto-reconnect if enabled and error is recoverable (not auth or host key issue)
      if (_autoReconnectEnabled &&
          _lastHost != null &&
          sshError is! SshAuthenticationException &&
          sshError is! SshHostKeyException) {
        _triggerAutoReconnect();
      }

      rethrow;
    }
  }

  Future<void> reconnect() async {
    if (_lastHost == null) {
      throw StateError('No previous connection to reconnect to.');
    }

    cancelAutoReconnect();

    _reconnectAttempts++;
    _updateStatus(ConnectionStatus.reconnecting(
      attempts: _reconnectAttempts,
      maxAttempts: _maxReconnectAttempts,
      lastSuccessfulConnection: _lastSuccessfulConnection,
    ));

    try {
      await connect(
        host: _lastHost!,
        port: _lastPort!,
        username: _lastUsername!,
        password: _lastPassword!,
        privateKey: _lastPrivateKey,
        privateKeyPassword: _lastPrivateKeyPassword,
        onTrustHostKey: _lastOnTrustHostKey,
      );
    } catch (e) {
      // connect() already set status to failed.
      rethrow;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final transport = _transport;
      if (transport != null) {
        // ping() returns a Future — use .then/.catchError so async errors
        // are caught rather than silently dropped in a try/catch.
        transport.ping().then((_) {}, onError: (_) {
          _handleDisconnect(reason: 'Heartbeat ping failed');
        });
      }
    });
  }

  void _handleDisconnect({String? reason}) {
    if (_transport != null || _currentStatus.isConnected) {
      _transport = null;
      _heartbeatTimer?.cancel();

      // If auto-reconnect is enabled, we move to a "waiting" reconnecting state
      if (_autoReconnectEnabled && _lastHost != null && _reconnectAttempts < _maxReconnectAttempts) {
        _triggerAutoReconnect();
      } else {
        _updateStatus(ConnectionStatus.disconnected());
      }
    }
  }

  void _triggerAutoReconnect() {
    cancelAutoReconnect();

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _updateStatus(ConnectionStatus.failed(
        const SshUnknownException(
          userMessage: 'Automatic reconnection failed.',
          suggestedAction: 'Please try to reconnect manually when the server is back online.',
        ),
        lastSuccessfulConnection: _lastSuccessfulConnection,
      ));
      return;
    }

    // Show "Reconnecting (Attempt X/N)" immediately so user knows we are trying
    _updateStatus(ConnectionStatus.reconnecting(
      attempts: _reconnectAttempts + 1,
      maxAttempts: _maxReconnectAttempts,
      lastSuccessfulConnection: _lastSuccessfulConnection,
    ));

    // Backoff schedule is injectable so tests can use [0,0,0,0,0]
    // for fast deterministic retries.
    final delay = Duration(
      seconds: _backoffSeconds[min(_reconnectAttempts, _backoffSeconds.length - 1)],
    );

    _reconnectTimer = Timer(delay, () async {
      // Guard: Ensure we still want to reconnect
      if (!_autoReconnectEnabled || _currentStatus.isConnected || _currentStatus.isDisconnected) {
        return;
      }

      try {
        await reconnect();
      } catch (_) {
        // reconnect() failed, loop triggers again from connect()'s catch block or we do it here if needed
        // Since connect() handles triggering auto-reconnect on failure, we don't need to do it here
        // to avoid double-timers.
      }
    });
  }

  void enableAutoReconnect() {
    _autoReconnectEnabled = true;
    if (_currentStatus.isDisconnected && _lastHost != null) {
      _triggerAutoReconnect();
    }
  }

  void disableAutoReconnect() {
    _autoReconnectEnabled = false;
    cancelAutoReconnect();
  }

  void cancelAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  bool isHealthy() {
    if (_transport == null) return false;
    try {
      _transport!.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Run [command] on the connected transport.
  ///
  /// When [vaultSecrets] is supplied, every `${vault:NAME}` placeholder
  /// is substituted with the matching secret value at the SSH boundary.
  /// The Sentry breadcrumb deliberately records the **pre-substitution**
  /// command (with placeholders intact) so the secret value never lands
  /// in the breadcrumb buffer or the crash report. Callers that surface
  /// this method's input string in the in-app command-history pane
  /// should likewise persist the placeholder form, not the substituted
  /// form.
  Future<String> execute(
    String command, {
    Iterable<VaultSecret> vaultSecrets = const [],
  }) async {
    final transport = _transport;
    if (transport == null) {
      throw StateError('SSH client is not connected.');
    }

    final injector = VaultInjector(vaultSecrets.toList(growable: false));
    final hasPlaceholders = injector.hasPlaceholders(command);
    final wrapped =
        hasPlaceholders ? injector.buildEnvCommand(command) : null;
    final commandToRun = wrapped?.wrappedCommand ?? command;
    // SSH protocol env-frame channel + inline wrapper fallback.
    // See docs/secrets-vault.md.
    final envForChannel = wrapped?.env;

    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Executing SSH command',
        category: 'ssh',
        data: {
          // Always log the placeholder form so the breadcrumb never
          // contains the substituted secret value.
          'command': command,
          if (hasPlaceholders)
            'vaultPlaceholders': wrapped!.placeholderNames,
        },
      ),
    );

    try {
      final output = await transport.run(
        commandToRun,
        environment: envForChannel,
      );
      return utf8.decode(output);
    } catch (error, stackTrace) {
      if (_looksLikeDisconnect(error)) {
        _handleDisconnect(reason: 'Command failed: $error');
      }
      Sentry.captureException(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<SSHSession> streamCommand(String command) async {
    final transport = _transport;
    if (transport == null) {
      throw StateError('SSH client is not connected.');
    }

    try {
      return await transport.execute(command);
    } catch (error, stackTrace) {
      if (_looksLikeDisconnect(error)) {
        _handleDisconnect(reason: 'Stream command failed: $error');
      }
      Sentry.captureException(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<SSHSession> startShell({int width = 80, int height = 24}) async {
    final transport = _transport;
    if (transport == null) {
      throw StateError('SSH client is not connected.');
    }

    try {
      return await transport.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: width, height: height),
      );
    } catch (error, stackTrace) {
      if (_looksLikeDisconnect(error)) {
        _handleDisconnect(reason: 'Shell failed: $error');
      }
      Sentry.captureException(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> startLocalForwarding({
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    final transport = _transport;
    if (transport == null) {
      throw StateError('SSH client is not connected.');
    }
    if (_activeForwards.containsKey(localPort)) {
      throw StateError('Local port $localPort is already being forwarded.');
    }

    final serverSocket = await ServerSocket.bind('127.0.0.1', localPort);
    _activeForwards[localPort] = serverSocket;

    serverSocket.listen(
      (socket) {
        unawaited(
          _handleForwardedConnection(
            transport: transport,
            socket: socket,
            remoteHost: remoteHost,
            remotePort: remotePort,
          ),
        );
      },
      onError: (_) {},
      onDone: () {
        if (identical(_activeForwards[localPort], serverSocket)) {
          _activeForwards.remove(localPort);
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> stopLocalForwarding(int localPort) async {
    final serverSocket = _activeForwards.remove(localPort);
    if (serverSocket == null) {
      return;
    }

    try {
      await serverSocket.close();
    } catch (_) {
      // Ignore close failures to keep forwarding cleanup non-fatal.
    }
  }

  Future<void> disconnect({bool updateStatus = true, bool cancelAuto = true}) async {
    _heartbeatTimer?.cancel();
    if (cancelAuto) cancelAutoReconnect();

    final forwardedSockets = _activeForwards.values.toList();
    _activeForwards.clear();
    for (final serverSocket in forwardedSockets) {
      try {
        await serverSocket.close();
      } catch (_) {
        // Ignore close failures during disconnect.
      }
    }
    _transport?.close();
    _transport = null;
    if (updateStatus) {
      _updateStatus(ConnectionStatus.disconnected());
    }
    await _disableBackgroundKeepalive();
  }

  static String extractPublicKey(String privateKeyPem, [String? passphrase]) {
    try {
      final keyPairs = SSHKeyPair.fromPem(privateKeyPem, passphrase);
      if (keyPairs.isEmpty) {
        throw Exception('No key pairs found in the provided PEM.');
      }
      return _formatAuthorizedKey(keyPairs.first.toPublicKey());
    } catch (e) {
      throw Exception('Failed to extract public key: $e');
    }
  }

  static ({String privateKey, String publicKey}) generateEd25519() {
    try {
      final keyPair = ed25519.SigningKey.generate();
      final privateKeyBytes = keyPair.asTypedList;
      final publicKeyBytes = keyPair.publicKey.asTypedList;

      final sshKeyPair = OpenSSHEd25519KeyPair(
        publicKeyBytes,
        privateKeyBytes,
        'hamma-generated-key',
      );

      return (
        privateKey: sshKeyPair.toPem(),
        publicKey: _formatAuthorizedKey(sshKeyPair.toPublicKey()),
      );
    } catch (e) {
      throw Exception('Failed to generate Ed25519 key: $e');
    }
  }

  static ({String privateKey, String publicKey}) generateRsa([
    int bitrate = 4096,
  ]) {
    try {
      final keyGen = pc.RSAKeyGenerator()
        ..init(
          pc.ParametersWithRandom(
            pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), bitrate, 64),
            _getSecureRandom(),
          ),
        );

      final pair = keyGen.generateKeyPair();
      final myPublic = pair.publicKey as pc.RSAPublicKey;
      final myPrivate = pair.privateKey as pc.RSAPrivateKey;

      final rsaPrivateKey = RsaPrivateKey(
        BigInt.zero, // version
        myPublic.n!,
        myPublic.publicExponent!,
        myPrivate.privateExponent!,
        myPrivate.p!,
        myPrivate.q!,
        myPrivate.privateExponent! % (myPrivate.p! - BigInt.one), // exp1
        myPrivate.privateExponent! % (myPrivate.q! - BigInt.one), // exp2
        myPrivate.q!.modInverse(myPrivate.p!), // coef
      );

      return (
        privateKey: rsaPrivateKey.toPem(),
        publicKey: _formatAuthorizedKey(rsaPrivateKey.toPublicKey()),
      );
    } catch (e) {
      throw Exception('Failed to generate RSA key: $e');
    }
  }

  static String _formatAuthorizedKey(dynamic public) {
    final encoded = public.encode() as Uint8List;
    final base64Encoded = base64.encode(encoded);

    // Extract type string (length-prefixed UTF-8)
    final length =
        (encoded[0] << 24) |
        (encoded[1] << 16) |
        (encoded[2] << 8) |
        encoded[3];
    final type = utf8.decode(encoded.sublist(4, 4 + length));

    return '$type $base64Encoded';
  }

  static pc.SecureRandom _getSecureRandom() {
    final secureRandom = pc.FortunaRandom();
    final seed = Uint8List(32);
    final random = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = random.nextInt(256);
    }
    secureRandom.seed(pc.KeyParameter(seed));
    return secureRandom;
  }

  Future<void> _handleForwardedConnection({
    required SshTransport transport,
    required Socket socket,
    required String remoteHost,
    required int remotePort,
  }) async {
    SSHForwardChannel? forward;

    try {
      forward = await transport.forwardLocal(remoteHost, remotePort);
      await _bridgeForwardedConnection(socket: socket, forward: forward);
    } catch (_) {
      try {
        await forward?.close();
      } catch (_) {
        // Ignore close failures when a forwarded channel could not start.
      }
      try {
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
    }
  }

  Future<void> _bridgeForwardedConnection({
    required Socket socket,
    required SSHForwardChannel forward,
  }) async {
    final remoteToLocal = forward.stream
        .cast<List<int>>()
        .handleError((_) {})
        .pipe(socket)
        .catchError((_) {});
    final localToRemote = socket
        .cast<List<int>>()
        .handleError((_) {})
        .pipe(forward.sink)
        .catchError((_) {});

    await Future.wait([remoteToLocal, localToRemote], eagerError: false);

    try {
      await forward.close();
    } catch (_) {
      // Ignore close failures on disconnect.
    }
    try {
      await socket.close();
    } catch (_) {
      socket.destroy();
    }
  }

  String _formatFingerprint(Uint8List bytes) {
    if (bytes.length == 32) {
      return 'SHA256:${base64.encode(bytes).replaceAll('=', '')}';
    }
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }

  bool _looksLikeDisconnect(Object error) {
    final message = error.toString().toLowerCase();
    const patterns = [
      // dartssh2 SSHStateError messages
      'transport is closed',
      'transport closed',
      'sshstateerror',
      // Generic socket / network closure
      'not connected',
      'connection reset',
      'broken pipe',
      'socketexception',
      'connection closed',
      'connection lost',
      'network is unreachable',
      // SSH channel / session errors
      'channel is not open',
      'failed host handshake',
    ];

    return patterns.any(message.contains);
  }
}
