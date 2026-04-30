import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/connection_status.dart';
import 'package:hamma/core/ssh/ssh_exception.dart';

void main() {
  group('ConnectionStatus flags', () {
    test('disconnected() sets only isDisconnected', () {
      final status = ConnectionStatus.disconnected();

      expect(status.isDisconnected, isTrue);
      expect(status.isConnected, isFalse);
      expect(status.isConnecting, isFalse);
      expect(status.isFailed, isFalse);
    });

    test('connecting() sets isConnecting, nothing else', () {
      final status = ConnectionStatus.connecting();

      expect(status.isConnecting, isTrue);
      expect(status.isConnected, isFalse);
      expect(status.isDisconnected, isFalse);
      expect(status.isFailed, isFalse);
    });

    test('connected() sets only isConnected', () {
      final status = ConnectionStatus.connected();

      expect(status.isConnected, isTrue);
      expect(status.isConnecting, isFalse);
      expect(status.isDisconnected, isFalse);
      expect(status.isFailed, isFalse);
    });

    test('reconnecting() is treated as connecting (isConnecting = true)', () {
      final status = ConnectionStatus.reconnecting(attempts: 1, maxAttempts: 3);

      expect(status.isConnecting, isTrue);
      expect(status.isConnected, isFalse);
      expect(status.isDisconnected, isFalse);
      expect(status.isFailed, isFalse);
    });

    test('failed() sets only isFailed', () {
      const exception = SshNetworkException(userMessage: 'Connection refused');
      final status = ConnectionStatus.failed(exception);

      expect(status.isFailed, isTrue);
      expect(status.isConnected, isFalse);
      expect(status.isConnecting, isFalse);
      expect(status.isDisconnected, isFalse);
    });
  });

  group('ConnectionStatus.reconnecting', () {
    test('carries attempt counts', () {
      final status = ConnectionStatus.reconnecting(attempts: 2, maxAttempts: 5);

      expect(status.reconnectAttempts, 2);
      expect(status.maxReconnectAttempts, 5);
    });

    test('defaults attempt counts to 0', () {
      final status = ConnectionStatus.reconnecting();

      expect(status.reconnectAttempts, 0);
      expect(status.maxReconnectAttempts, 0);
    });
  });

  group('ConnectionStatus.failed', () {
    test('exposes exception userMessage via errorMessage', () {
      const exception = SshAuthenticationException(
        userMessage: 'Authentication failed',
        suggestedAction: 'Check your credentials',
      );
      final status = ConnectionStatus.failed(exception);

      expect(status.errorMessage, 'Authentication failed');
      expect(status.exception, exception);
    });

    test('preserves lastSuccessfulConnection when provided', () {
      final now = DateTime(2026, 4, 30, 12);
      const exception = SshTimeoutException(userMessage: 'Timed out');
      final status = ConnectionStatus.failed(exception, lastSuccessfulConnection: now);

      expect(status.lastSuccessfulConnection, now);
    });
  });

  group('ConnectionStatus.connected', () {
    test('sets lastSuccessfulConnection when provided', () {
      final ts = DateTime(2026, 1, 1);
      final status = ConnectionStatus.connected(lastSuccessfulConnection: ts);

      expect(status.lastSuccessfulConnection, ts);
    });

    test('defaults lastSuccessfulConnection to now when not provided', () {
      final before = DateTime.now();
      final status = ConnectionStatus.connected();
      final after = DateTime.now();

      expect(status.lastSuccessfulConnection, isNotNull);
      expect(
        status.lastSuccessfulConnection!.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        status.lastSuccessfulConnection!.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });

  group('ConnectionStatus.errorMessage', () {
    test('returns null when there is no exception', () {
      expect(ConnectionStatus.disconnected().errorMessage, isNull);
      expect(ConnectionStatus.connected().errorMessage, isNull);
    });
  });

  group('SshConnectionState enum', () {
    test('contains all five expected states', () {
      expect(
        SshConnectionState.values.map((e) => e.name),
        containsAll(['disconnected', 'connecting', 'connected', 'reconnecting', 'failed']),
      );
    });
  });
}
