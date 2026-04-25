abstract class SshException implements Exception {
  final String userMessage;
  final String? suggestedAction;
  final dynamic originalError;

  const SshException({
    required this.userMessage,
    this.suggestedAction,
    this.originalError,
  });

  @override
  String toString() => userMessage;
}

class SshNetworkException extends SshException {
  const SshNetworkException({
    required super.userMessage,
    super.suggestedAction,
    super.originalError,
  });
}

class SshAuthenticationException extends SshException {
  const SshAuthenticationException({
    required super.userMessage,
    super.suggestedAction,
    super.originalError,
  });
}

class SshTimeoutException extends SshException {
  const SshTimeoutException({
    super.userMessage = 'The connection timed out.',
    super.suggestedAction = 'Check if the server is online and reachable.',
    super.originalError,
  });
}

class SshHostKeyException extends SshException {
  const SshHostKeyException({
    required super.userMessage,
    super.suggestedAction,
    super.originalError,
  });
}

class SshUnknownHostKeyException extends SshHostKeyException {
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  const SshUnknownHostKeyException({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    super.originalError,
  }) : super(
          userMessage: 'The server\'s identity is unknown.',
          suggestedAction: 'Verify the fingerprint before continuing.',
        );
}

class SshUnknownHostKeyRejectedException extends SshHostKeyException {
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  const SshUnknownHostKeyRejectedException({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    super.originalError,
  }) : super(
          userMessage: 'The server identity was rejected by the user.',
          suggestedAction: 'You must trust the host key to connect.',
        );
}

class SshHostKeyMismatchException extends SshHostKeyException {
  final String host;
  final int port;
  final String expectedAlgorithm;
  final String expectedFingerprint;
  final String actualAlgorithm;
  final String actualFingerprint;

  const SshHostKeyMismatchException({
    required this.host,
    required this.port,
    required this.expectedAlgorithm,
    required this.expectedFingerprint,
    required this.actualAlgorithm,
    required this.actualFingerprint,
    super.originalError,
  }) : super(
          userMessage: 'Security Warning: Server identity has changed!',
          suggestedAction: 'This could be a man-in-the-middle attack. Only continue if you know the server was reinstalled.',
        );
}

class SshPermissionException extends SshException {
  const SshPermissionException({
    required super.userMessage,
    super.suggestedAction,
    super.originalError,
  });
}

class SshUnknownException extends SshException {
  const SshUnknownException({
    required super.userMessage,
    super.suggestedAction,
    super.originalError,
  });
}
