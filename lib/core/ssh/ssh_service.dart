import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:pointycastle/export.dart' as pc;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../background/background_keepalive.dart';
import '../storage/trusted_host_key_storage.dart';

class SshService {
  SshService({TrustedHostKeyStorage? trustedHostKeyStorage})
    : _trustedHostKeyStorage =
          trustedHostKeyStorage ?? const TrustedHostKeyStorage();

  SSHClient? _client;
  final Map<int, ServerSocket> _activeForwards = {};
  final TrustedHostKeyStorage _trustedHostKeyStorage;
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  Timer? _heartbeatTimer;

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

  bool get isConnected => _client != null;
  String? get password => _lastPassword;
  Stream<bool> get connectionState => _connectionStateController.stream;
  List<int> get activeForwardedPorts => _activeForwards.keys.toList();

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

    await disconnect();

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

      List<SSHKeyPair>? identities;
      if (privateKey != null && privateKey.isNotEmpty) {
        try {
          identities = SSHKeyPair.fromPem(privateKey, privateKeyPassword);
        } catch (e) {
          throw Exception('Invalid SSH private key or passphrase: $e');
        }
      }

      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );

      final client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: () => password.isNotEmpty ? password : null,
        onVerifyHostKey: (algorithm, fingerprintBytes) async {
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
        },
      );

      await client.authenticated;
      try {
        await BackgroundKeepalive.enable();
      } catch (_) {
        client.close();
        rethrow;
      }
      _client = client;
      _startHeartbeat();
      _connectionStateController.add(true);
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> reconnect() async {
    if (_lastHost == null) {
      throw StateError('No previous connection to reconnect to.');
    }

    await connect(
      host: _lastHost!,
      port: _lastPort!,
      username: _lastUsername!,
      password: _lastPassword!,
      privateKey: _lastPrivateKey,
      privateKeyPassword: _lastPrivateKeyPassword,
      onTrustHostKey: _lastOnTrustHostKey,
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_client != null) {
        try {
          _client!.ping();
        } catch (_) {
          _handleDisconnect();
        }
      }
    });
  }

  void _handleDisconnect() {
    if (_client != null) {
      _client = null;
      _heartbeatTimer?.cancel();
      _connectionStateController.add(false);
    }
  }

  Future<String> execute(String command) async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH client is not connected.');
    }

    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Executing SSH command',
        category: 'ssh',
        data: {'command': command},
      ),
    );

    try {
      final output = await client.run(command);
      return utf8.decode(output);
    } catch (error, stackTrace) {
      if (_looksLikeDisconnect(error)) {
        _handleDisconnect();
        await disconnect();
      }
      Sentry.captureException(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<SSHSession> streamCommand(String command) async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH client is not connected.');
    }

    try {
      return await client.execute(command);
    } catch (error, stackTrace) {
      if (_looksLikeDisconnect(error)) {
        _handleDisconnect();
        await disconnect();
      }
      Sentry.captureException(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<SSHSession> startShell({int width = 80, int height = 24}) async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH client is not connected.');
    }

    try {
      return client.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: width, height: height),
      );
    } catch (error, stackTrace) {
      if (_looksLikeDisconnect(error)) {
        _handleDisconnect();
        await disconnect();
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
    final client = _client;
    if (client == null) {
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
            client: client,
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

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    final forwardedSockets = _activeForwards.values.toList();
    _activeForwards.clear();
    for (final serverSocket in forwardedSockets) {
      try {
        await serverSocket.close();
      } catch (_) {
        // Ignore close failures during disconnect.
      }
    }
    _client?.close();
    _client = null;
    _connectionStateController.add(false);
    await BackgroundKeepalive.disable();
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
    required SSHClient client,
    required Socket socket,
    required String remoteHost,
    required int remotePort,
  }) async {
    SSHForwardChannel? forward;

    try {
      forward = await client.forwardLocal(remoteHost, remotePort);
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
      'not connected',
      'connection reset',
      'broken pipe',
      'socketexception',
      'connection closed',
      'channel is not open',
      'failed host handshake',
    ];

    return patterns.any(message.contains);
  }
}

class SshUnknownHostKeyException implements Exception {
  const SshUnknownHostKeyException({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  @override
  String toString() {
    return 'Unknown SSH host key for $host:$port.\n'
        'Algorithm: $algorithm\n'
        'Fingerprint: $fingerprint';
  }
}

class SshUnknownHostKeyRejectedException implements Exception {
  const SshUnknownHostKeyRejectedException({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  @override
  String toString() {
    return 'SSH host key was not trusted for $host:$port.\n'
        'Algorithm: $algorithm\n'
        'Fingerprint: $fingerprint';
  }
}

class SshHostKeyMismatchException implements Exception {
  const SshHostKeyMismatchException({
    required this.host,
    required this.port,
    required this.expectedAlgorithm,
    required this.expectedFingerprint,
    required this.actualAlgorithm,
    required this.actualFingerprint,
  });

  final String host;
  final int port;
  final String expectedAlgorithm;
  final String expectedFingerprint;
  final String actualAlgorithm;
  final String actualFingerprint;

  @override
  String toString() {
    return 'SSH host key mismatch for $host:$port.\n'
        'Expected: $expectedAlgorithm $expectedFingerprint\n'
        'Received: $actualAlgorithm $actualFingerprint\n'
        'Do not continue unless you have verified the server key changed.';
  }
}
