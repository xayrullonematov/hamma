import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../background/background_keepalive.dart';
import '../storage/trusted_host_key_storage.dart';

class SshService {
  SshService({TrustedHostKeyStorage? trustedHostKeyStorage})
    : _trustedHostKeyStorage =
          trustedHostKeyStorage ?? const TrustedHostKeyStorage();

  SSHClient? _client;
  final Map<int, ServerSocket> _activeForwards = {};
  final TrustedHostKeyStorage _trustedHostKeyStorage;

  bool get isConnected => _client != null;
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
    await disconnect();

    final trustedHostKey = await _trustedHostKeyStorage.loadTrustedHostKey(
      host: host,
      port: port,
    );
    final resolvedPrivateKey = privateKey?.trim();
    final identities =
        resolvedPrivateKey == null || resolvedPrivateKey.isEmpty
            ? null
            : SSHKeyPair.fromPem(resolvedPrivateKey, privateKeyPassword);

    final socket = await SSHSocket.connect(host, port);
    final client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: () => password,
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
  }

  Future<String> execute(String command) async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH client is not connected.');
    }

    try {
      final output = await client.run(command);
      return utf8.decode(output);
    } catch (error) {
      if (_looksLikeDisconnect(error)) {
        await disconnect();
      }
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
    } catch (error) {
      if (_looksLikeDisconnect(error)) {
        await disconnect();
      }
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
    await BackgroundKeepalive.disable();
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
