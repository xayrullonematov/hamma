import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/ssh_exception.dart';

void main() {
  group('SshNetworkException', () {
    test('stores userMessage and implements Exception', () {
      const e = SshNetworkException(userMessage: 'Network unreachable');
      expect(e.userMessage, 'Network unreachable');
      expect(e, isA<SshException>());
      expect(e, isA<Exception>());
    });

    test('toString returns userMessage', () {
      const e = SshNetworkException(userMessage: 'Connection refused');
      expect(e.toString(), 'Connection refused');
    });

    test('stores optional suggestedAction', () {
      const e = SshNetworkException(
        userMessage: 'Error',
        suggestedAction: 'Check firewall',
      );
      expect(e.suggestedAction, 'Check firewall');
    });

    test('stores optional originalError', () {
      final original = Exception('raw');
      final e = SshNetworkException(
        userMessage: 'Error',
        originalError: original,
      );
      expect(e.originalError, original);
    });

    test('suggestedAction is null when not provided', () {
      const e = SshNetworkException(userMessage: 'Error');
      expect(e.suggestedAction, isNull);
    });
  });

  group('SshAuthenticationException', () {
    test('stores userMessage', () {
      const e = SshAuthenticationException(
        userMessage: 'Authentication failed',
        suggestedAction: 'Check your credentials',
      );
      expect(e.userMessage, 'Authentication failed');
      expect(e.suggestedAction, 'Check your credentials');
    });

    test('is a subtype of SshException', () {
      const e = SshAuthenticationException(userMessage: 'Auth error');
      expect(e, isA<SshException>());
    });
  });

  group('SshTimeoutException', () {
    test('has sensible default message', () {
      const e = SshTimeoutException();
      expect(e.userMessage, 'The connection timed out.');
      expect(e.suggestedAction, contains('online'));
    });

    test('allows overriding the default message', () {
      const e = SshTimeoutException(userMessage: 'Custom timeout');
      expect(e.userMessage, 'Custom timeout');
    });
  });

  group('SshHostKeyException hierarchy', () {
    test('SshUnknownHostKeyException stores host, port, algorithm, fingerprint', () {
      const e = SshUnknownHostKeyException(
        host: 'example.com',
        port: 22,
        algorithm: 'ssh-rsa',
        fingerprint: 'AA:BB:CC',
      );
      expect(e.host, 'example.com');
      expect(e.port, 22);
      expect(e.algorithm, 'ssh-rsa');
      expect(e.fingerprint, 'AA:BB:CC');
      expect(e.userMessage, "The server's identity is unknown.");
      expect(e, isA<SshHostKeyException>());
    });

    test('SshUnknownHostKeyRejectedException has correct messages', () {
      const e = SshUnknownHostKeyRejectedException(
        host: 'server.io',
        port: 2222,
        algorithm: 'ecdsa-sha2-nistp256',
        fingerprint: '11:22:33',
      );
      expect(e.userMessage, 'The server identity was rejected by the user.');
      expect(e.suggestedAction, contains('trust'));
      expect(e, isA<SshHostKeyException>());
    });

    test('SshHostKeyMismatchException stores both expected and actual keys', () {
      const e = SshHostKeyMismatchException(
        host: 'example.com',
        port: 22,
        expectedAlgorithm: 'ssh-rsa',
        expectedFingerprint: 'AA:BB',
        actualAlgorithm: 'ecdsa-sha2-nistp256',
        actualFingerprint: 'CC:DD',
      );
      expect(e.expectedAlgorithm, 'ssh-rsa');
      expect(e.actualAlgorithm, 'ecdsa-sha2-nistp256');
      expect(e.expectedFingerprint, 'AA:BB');
      expect(e.actualFingerprint, 'CC:DD');
      expect(e.userMessage, contains('Security Warning'));
    });
  });

  group('SshPermissionException', () {
    test('stores message and is SshException', () {
      const e = SshPermissionException(userMessage: 'Permission denied');
      expect(e.userMessage, 'Permission denied');
      expect(e, isA<SshException>());
    });
  });

  group('SshUnknownException', () {
    test('stores message and is SshException', () {
      const e = SshUnknownException(userMessage: 'Unknown error occurred');
      expect(e.userMessage, 'Unknown error occurred');
      expect(e, isA<SshException>());
    });

    test('toString returns userMessage', () {
      const e = SshUnknownException(userMessage: 'Something went wrong');
      expect(e.toString(), 'Something went wrong');
    });
  });
}
