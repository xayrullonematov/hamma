import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Thin abstraction over the parts of `dartssh2`'s [SSHClient] that
/// [SshService] actually uses.
///
/// Allows the connection state machine in [SshService] to be unit-
/// tested with a fake transport that doesn't require a real network
/// or a running SSH server. The default production implementation is
/// [DartSsh2Transport], which is a 1:1 pass-through to [SSHClient].
abstract class SshTransport {
  /// Resolved when the underlying SSH client has finished
  /// authenticating; throws if authentication failed (wrong
  /// credentials, host-key rejected, etc).
  Future<void> get authenticated;

  /// Resolved when the underlying transport closes for any reason.
  /// Errors out (rather than completing normally) when the transport
  /// closed because of an error.
  Future<void> get done;

  /// Sends a keepalive ping. Throws when the transport is closed.
  Future<void> ping();

  /// Closes the transport. Idempotent.
  void close();

  /// Run a one-shot command and return its stdout bytes.
  ///
  /// [environment] is forwarded as SSH `env` channel requests
  /// (SSH_MSG_CHANNEL_REQUEST type "env") **before** the command
  /// starts, so the values travel over the wire as protocol-level
  /// env frames and never appear in the command text. Stock sshd
  /// only honours these for names listed in `AcceptEnv`; for names
  /// it rejects, the variable is silently absent on the remote
  /// side, so callers that need the value to be available
  /// regardless of sshd policy must also wrap the command body
  /// (see `VaultInjector.buildEnvCommand`).
  Future<Uint8List> run(String command, {Map<String, String>? environment});

  /// Start a streaming session for [command].
  Future<SSHSession> execute(String command);

  /// Open an interactive PTY shell.
  Future<SSHSession> shell({SSHPtyConfig? pty});

  /// Open a local-to-remote port forward channel.
  Future<SSHForwardChannel> forwardLocal(String host, int port);
}

/// Function the SSH state machine calls to create a new transport.
///
/// The host-key verification closure is built by the caller (so the
/// state machine owns the user-prompt + storage logic) and passed in
/// here as [onVerifyHostKey] — exactly matching dartssh2's
/// `SSHClient.onVerifyHostKey` signature so the default connector
/// can pass it through unchanged.
typedef SshConnector = Future<SshTransport> Function({
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
});

/// Production [SshConnector] implementation. Performs the real
/// `SSHSocket.connect` + `SSHClient` handshake and waits for
/// `authenticated`. Throws whatever `dartssh2` raises (network
/// errors, auth errors, host-key callback errors); the state
/// machine's error mapper is responsible for translating those to
/// the `SshException` hierarchy.
Future<SshTransport> defaultSshConnector({
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
    onVerifyHostKey: onVerifyHostKey,
  );

  await client.authenticated;
  return DartSsh2Transport(client);
}

/// Pass-through [SshTransport] backed by a real dartssh2 [SSHClient].
class DartSsh2Transport implements SshTransport {
  DartSsh2Transport(this._client);

  final SSHClient _client;

  @override
  Future<void> get authenticated => _client.authenticated;

  @override
  Future<void> get done => _client.done;

  @override
  Future<void> ping() => _client.ping();

  @override
  void close() => _client.close();

  @override
  Future<Uint8List> run(String command, {Map<String, String>? environment}) =>
      _client.run(command, environment: environment);

  @override
  Future<SSHSession> execute(String command) => _client.execute(command);

  @override
  Future<SSHSession> shell({SSHPtyConfig? pty}) => _client.shell(pty: pty);

  @override
  Future<SSHForwardChannel> forwardLocal(String host, int port) =>
      _client.forwardLocal(host, port);
}
