import 'ssh_exception.dart';

enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

class ConnectionStatus {
  final SshConnectionState state;
  final SshException? exception;
  final int reconnectAttempts;
  final int maxReconnectAttempts;
  final DateTime? lastSuccessfulConnection;

  const ConnectionStatus({
    required this.state,
    this.exception,
    this.reconnectAttempts = 0,
    this.maxReconnectAttempts = 0,
    this.lastSuccessfulConnection,
  });

  String? get errorMessage => exception?.userMessage;

  factory ConnectionStatus.disconnected() => const ConnectionStatus(state: SshConnectionState.disconnected);

  factory ConnectionStatus.connecting() => const ConnectionStatus(state: SshConnectionState.connecting);

  factory ConnectionStatus.connected({DateTime? lastSuccessfulConnection}) => ConnectionStatus(
        state: SshConnectionState.connected,
        lastSuccessfulConnection: lastSuccessfulConnection ?? DateTime.now(),
      );

  factory ConnectionStatus.reconnecting({
    int attempts = 0,
    int maxAttempts = 0,
    DateTime? lastSuccessfulConnection,
  }) =>
      ConnectionStatus(
        state: SshConnectionState.reconnecting,
        reconnectAttempts: attempts,
        maxReconnectAttempts: maxAttempts,
        lastSuccessfulConnection: lastSuccessfulConnection,
      );

  factory ConnectionStatus.failed(SshException exception, {DateTime? lastSuccessfulConnection}) => ConnectionStatus(
        state: SshConnectionState.failed,
        exception: exception,
        lastSuccessfulConnection: lastSuccessfulConnection,
      );

  bool get isConnected => state == SshConnectionState.connected;
  bool get isConnecting => state == SshConnectionState.connecting || state == SshConnectionState.reconnecting;
  bool get isDisconnected => state == SshConnectionState.disconnected;
  bool get isFailed => state == SshConnectionState.failed;

  @override
  String toString() {
    return 'ConnectionStatus(state: $state, attempts: $reconnectAttempts/$maxReconnectAttempts, error: $errorMessage)';
  }
}
