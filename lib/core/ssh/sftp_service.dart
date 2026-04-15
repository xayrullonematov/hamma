import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../storage/trusted_host_key_storage.dart';
import 'ssh_service.dart'
    show
        SshHostKeyMismatchException,
        SshUnknownHostKeyException,
        SshUnknownHostKeyRejectedException;

class SftpService {
  SftpService({TrustedHostKeyStorage? trustedHostKeyStorage})
    : _trustedHostKeyStorage =
          trustedHostKeyStorage ?? const TrustedHostKeyStorage();

  static const _tempEditPath = '/tmp/hamma_temp_edit';

  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  final TrustedHostKeyStorage _trustedHostKeyStorage;

  bool get isConnected => _sshClient != null && _sftpClient != null;

  SftpClient get client {
    final client = _sftpClient;
    if (client == null) {
      throw StateError('SFTP client is not connected.');
    }

    return client;
  }

  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required String password,
    Future<bool> Function({
      required String host,
      required int port,
      required String algorithm,
      required String fingerprint,
    })?
    onTrustHostKey,
  }) async {
    await dispose();

    final trustedHostKey = await _trustedHostKeyStorage.loadTrustedHostKey(
      host: host,
      port: port,
    );

    final socket = await SSHSocket.connect(host, port);
    final sshClient = SSHClient(
      socket,
      username: username,
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

    try {
      await sshClient.authenticated;
      final sftpClient = await sshClient.sftp();
      await sftpClient.handshake;
      _sshClient = sshClient;
      _sftpClient = sftpClient;
    } catch (_) {
      sshClient.close();
      rethrow;
    }
  }

  Future<List<SftpName>> listDirectory(String path) async {
    return client.listdir(path);
  }

  Future<String> readFile(String path) async {
    final file = await client.open(path, mode: SftpFileOpenMode.read);
    try {
      final bytes = await file.readBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await file.close();
    }
  }

  Future<void> writeFile(String path, String content) async {
    final file = await client.open(
      path,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );

    try {
      final bytes = Uint8List.fromList(utf8.encode(content));
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
  }

  Future<void> writeFileWithSudoFallback(
    String path,
    String content, {
    Future<bool> Function()? onSudoFallbackPrompt,
  }) async {
    try {
      await writeFile(path, content);
      return;
    } catch (error) {
      if (!_isPermissionDeniedError(error)) {
        rethrow;
      }

      final allowSudo = await onSudoFallbackPrompt?.call() ?? true;
      if (!allowSudo) {
        throw const SftpSudoFallbackCancelledException();
      }

      await writeFile(_tempEditPath, content);

      try {
        final escapedTempPath = _shellQuote(_tempEditPath);
        final escapedTargetPath = _shellQuote(path);
        await _runShellCommand(
          "sudo cp -- '$escapedTempPath' '$escapedTargetPath'",
        );
      } finally {
        try {
          final escapedTempPath = _shellQuote(_tempEditPath);
          await _runShellCommand("rm -f -- '$escapedTempPath'");
        } catch (_) {
          // Ignore cleanup failures so the original write result remains visible.
        }
      }
    }
  }

  Future<void> dispose() async {
    _sftpClient?.close();
    _sftpClient = null;
    _sshClient?.close();
    _sshClient = null;
  }

  Future<void> _runShellCommand(String command) async {
    final sshClient = _sshClient;
    if (sshClient == null) {
      throw StateError('SSH client is not connected.');
    }

    final result = await sshClient.runWithResult(command);
    final output = utf8.decode(result.output, allowMalformed: true).trim();
    if (result.exitCode == 0 && result.exitSignal == null) {
      return;
    }

    if (output.isNotEmpty) {
      throw StateError(output);
    }

    throw StateError('Remote command failed: $command');
  }

  bool _isPermissionDeniedError(Object error) {
    if (error is SftpStatusError) {
      return error.code == SftpStatusCode.permissionDenied;
    }

    return error.toString().toLowerCase().contains('permission denied');
  }

  String _shellQuote(String value) {
    return value.replaceAll("'", r"'\''");
  }

  String _formatFingerprint(Uint8List bytes) {
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }
}

class SftpSudoFallbackCancelledException implements Exception {
  const SftpSudoFallbackCancelledException();
}
