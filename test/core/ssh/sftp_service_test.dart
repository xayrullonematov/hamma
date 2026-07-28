import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/sftp_service.dart';
import 'package:hamma/core/ssh/ssh_service.dart'
    show
        SshHostKeyMismatchException,
        SshUnknownHostKeyException,
        SshUnknownHostKeyRejectedException;
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

class InMemoryTrustedHostKeyStorage implements TrustedHostKeyStorage {
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

  @override
  Future<void> removeTrustedHostKey({
    required String host,
    required int port,
  }) async {
    _records.remove(_key(host, port));
  }

  int get savedCount => _records.length;
}

class FakeSSHSocket implements SSHSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSftpClient implements SftpClient {
  bool isClosed = false;

  @override
  Future<SftpHandsake> get handshake async => SftpHandsake(3, {});

  @override
  void close() {
    isClosed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSSHClient implements SSHClient {
  bool isClosed = false;
  FakeSftpClient sftpClient = FakeSftpClient();
  final Completer<void> _authenticatedCompleter = Completer<void>();
  bool simulateAuthenticationError = false;

  Future<bool> Function(String algorithm, Uint8List fingerprintBytes)? onVerifyHostKey;

  FakeSSHClient({this.onVerifyHostKey, this.simulateAuthenticationError = false}) {
    _initAuth();
  }

  void _initAuth() async {
    if (simulateAuthenticationError) {
      _authenticatedCompleter.completeError(Exception('Authentication failed'));
      return;
    }

    if (onVerifyHostKey != null) {
      try {
        final accepted = await onVerifyHostKey!('ssh-ed25519', Uint8List.fromList(List.filled(32, 0xCA)));
        if (!accepted) {
          _authenticatedCompleter.completeError(Exception('Host key rejected'));
          return;
        }
      } catch (e) {
        _authenticatedCompleter.completeError(e);
        return;
      }
    }

    _authenticatedCompleter.complete();
  }

  @override
  Future<void> get authenticated => _authenticatedCompleter.future;

  @override
  Future<SftpClient> sftp() async {
    return sftpClient;
  }

  @override
  void close() {
    isClosed = true;
    sftpClient.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SftpService.connect host-key verification', () {
    late InMemoryTrustedHostKeyStorage storage;

    setUp(() {
      storage = InMemoryTrustedHostKeyStorage();
    });

    test('connect succeeds when trusted host key matches', () async {
      await storage.saveTrustedHostKey(
        host: 'host.example',
        port: 22,
        record: TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: Uint8List.fromList(List.filled(32, 0xCA)).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(':'),
        ),
      );

      final service = SftpService(
        trustedHostKeyStorage: storage,
        socketConnector: (host, port) async => FakeSSHSocket(),
        clientFactory: (socket, {required username, identities, onPasswordRequest, onVerifyHostKey}) {
          return FakeSSHClient(onVerifyHostKey: onVerifyHostKey);
        },
      );

      await service.connect(
        host: 'host.example',
        port: 22,
        username: 'test',
        password: 'password',
      );

      expect(service.isConnected, isTrue);
    });

    test('throws SshHostKeyMismatchException when trusted host key mismatches', () async {
      await storage.saveTrustedHostKey(
        host: 'host.example',
        port: 22,
        record: TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: 'wrong-fingerprint',
        ),
      );

      final service = SftpService(
        trustedHostKeyStorage: storage,
        socketConnector: (host, port) async => FakeSSHSocket(),
        clientFactory: (socket, {required username, identities, onPasswordRequest, onVerifyHostKey}) {
          return FakeSSHClient(onVerifyHostKey: onVerifyHostKey);
        },
      );

      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'test',
          password: 'password',
        ),
        throwsA(isA<SshHostKeyMismatchException>()),
      );

      expect(service.isConnected, isFalse);
    });

    test('throws SshUnknownHostKeyException when no trusted key and no callback', () async {
      final service = SftpService(
        trustedHostKeyStorage: storage,
        socketConnector: (host, port) async => FakeSSHSocket(),
        clientFactory: (socket, {required username, identities, onPasswordRequest, onVerifyHostKey}) {
          return FakeSSHClient(onVerifyHostKey: onVerifyHostKey);
        },
      );

      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'test',
          password: 'password',
        ),
        throwsA(isA<SshUnknownHostKeyException>()),
      );
    });

    test('prompts via onTrustHostKey, saves key, and succeeds if accepted', () async {
      final service = SftpService(
        trustedHostKeyStorage: storage,
        socketConnector: (host, port) async => FakeSSHSocket(),
        clientFactory: (socket, {required username, identities, onPasswordRequest, onVerifyHostKey}) {
          return FakeSSHClient(onVerifyHostKey: onVerifyHostKey);
        },
      );

      int callbackInvocations = 0;
      await service.connect(
        host: 'host.example',
        port: 22,
        username: 'test',
        password: 'password',
        onTrustHostKey: ({required host, required port, required algorithm, required fingerprint}) async {
          callbackInvocations++;
          return true;
        },
      );

      expect(callbackInvocations, 1);
      expect(storage.savedCount, 1);
      expect(service.isConnected, isTrue);
    });

    test('prompts via onTrustHostKey, throws SshUnknownHostKeyRejectedException if rejected', () async {
      final service = SftpService(
        trustedHostKeyStorage: storage,
        socketConnector: (host, port) async => FakeSSHSocket(),
        clientFactory: (socket, {required username, identities, onPasswordRequest, onVerifyHostKey}) {
          return FakeSSHClient(onVerifyHostKey: onVerifyHostKey);
        },
      );

      int callbackInvocations = 0;
      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'test',
          password: 'password',
          onTrustHostKey: ({required host, required port, required algorithm, required fingerprint}) async {
            callbackInvocations++;
            return false;
          },
        ),
        throwsA(isA<SshUnknownHostKeyRejectedException>()),
      );

      expect(callbackInvocations, 1);
      expect(storage.savedCount, 0);
      expect(service.isConnected, isFalse);
    });

    test('closes ssh client and rethrows on authentication failure', () async {
      final service = SftpService(
        trustedHostKeyStorage: storage,
        socketConnector: (host, port) async => FakeSSHSocket(),
        clientFactory: (socket, {required username, identities, onPasswordRequest, onVerifyHostKey}) {
          return FakeSSHClient(onVerifyHostKey: onVerifyHostKey, simulateAuthenticationError: true);
        },
      );

      await expectLater(
        service.connect(
          host: 'host.example',
          port: 22,
          username: 'test',
          password: 'password',
        ),
        throwsA(isException),
      );

      expect(service.isConnected, isFalse);
    });
  });
}
