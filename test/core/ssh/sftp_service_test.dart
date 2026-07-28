import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hamma/core/ssh/sftp_service.dart';
import 'package:hamma/core/ssh/ssh_service.dart'
    show
        SshHostKeyMismatchException,
        SshUnknownHostKeyException,
        SshUnknownHostKeyRejectedException;
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

class MockSSHSocket extends Mock implements SSHSocket {}
class MockSSHClient extends Mock implements SSHClient {}
class MockSftpClient extends Mock implements SftpClient {}
class MockSftpFile extends Mock implements SftpFile {}
class MockTrustedHostKeyStorage extends Mock implements TrustedHostKeyStorage {}
class MockSSHSession extends Mock implements SSHSession {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(Stream<Uint8List>.empty());
    registerFallbackValue(
      const TrustedHostKeyRecord(algorithm: 'dummy', fingerprint: 'dummy'),
    );
    registerFallbackValue(SftpFileOpenMode.read);
  });

  group('SftpService Connect & Host Key Logic', () {
    late MockTrustedHostKeyStorage mockStorage;
    late MockSSHSocket mockSocket;
    late MockSSHClient mockSshClient;
    late MockSftpClient mockSftpClient;
    late SftpService service;
    late Future<bool> Function(String, Uint8List)? capturedVerifyHostKey;

    setUp(() {
      mockStorage = MockTrustedHostKeyStorage();
      mockSocket = MockSSHSocket();
      mockSshClient = MockSSHClient();
      mockSftpClient = MockSftpClient();

      when(() => mockSshClient.authenticated).thenAnswer((_) async {});
      when(() => mockSshClient.sftp()).thenAnswer((_) async => mockSftpClient);
      when(() => mockSshClient.close()).thenReturn(null);
      when(() => mockSftpClient.handshake).thenAnswer((_) async => SftpHandsake(3, {}));
      when(() => mockSftpClient.close()).thenReturn(null);

      service = SftpService(
        trustedHostKeyStorage: mockStorage,
        sshSocketFactory: (host, port) async => mockSocket,
        sshClientFactory: (
          socket, {
          required username,
          identities,
          onPasswordRequest,
          onVerifyHostKey,
        }) {
          capturedVerifyHostKey = onVerifyHostKey;
          return mockSshClient;
        },
      );
    });

    test('throws StateError when not connected', () {
      expect(() => service.client, throwsStateError);
      expect(service.isConnected, isFalse);
    });

    test('connects and accepts trusted host key', () async {
      when(
        () => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22),
      ).thenAnswer(
        (_) async => const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: '11:22:33:44',
        ),
      );

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
      );

      expect(service.isConnected, isTrue);
      expect(capturedVerifyHostKey, isNotNull);

      final accepted = await capturedVerifyHostKey!(
        'ssh-ed25519',
        Uint8List.fromList([0x11, 0x22, 0x33, 0x44]),
      );
      expect(accepted, isTrue);
    });

    test('connects and rejects unknown host key when onTrustHostKey is null', () async {
      when(
        () => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22),
      ).thenAnswer((_) async => null);

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
      );

      expect(
        () => capturedVerifyHostKey!(
          'ssh-ed25519',
          Uint8List.fromList([0x11, 0x22, 0x33, 0x44]),
        ),
        throwsA(isA<SshUnknownHostKeyException>()),
      );
    });

    test('connects, prompts for unknown host key, and rejects if false', () async {
      when(
        () => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22),
      ).thenAnswer((_) async => null);

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
        onTrustHostKey: ({
          required host,
          required port,
          required algorithm,
          required fingerprint,
        }) async => false,
      );

      expect(
        () => capturedVerifyHostKey!(
          'ssh-ed25519',
          Uint8List.fromList([0x11, 0x22, 0x33, 0x44]),
        ),
        throwsA(isA<SshUnknownHostKeyRejectedException>()),
      );
    });

    test('connects, prompts for unknown host key, saves and accepts if true', () async {
      when(
        () => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22),
      ).thenAnswer((_) async => null);

      when(
        () => mockStorage.saveTrustedHostKey(
          host: 'localhost',
          port: 22,
          record: any(named: 'record'),
        ),
      ).thenAnswer((_) async {});

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
        onTrustHostKey: ({
          required host,
          required port,
          required algorithm,
          required fingerprint,
        }) async => true,
      );

      final accepted = await capturedVerifyHostKey!(
        'ssh-ed25519',
        Uint8List.fromList([0x11, 0x22, 0x33, 0x44]),
      );

      expect(accepted, isTrue);
      verify(
        () => mockStorage.saveTrustedHostKey(
          host: 'localhost',
          port: 22,
          record: any(named: 'record'),
        ),
      ).called(1);
    });

    test('throws SshHostKeyMismatchException on mismatch', () async {
      when(
        () => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22),
      ).thenAnswer(
        (_) async => const TrustedHostKeyRecord(
          algorithm: 'ssh-ed25519',
          fingerprint: '11:22:33:44',
        ),
      );

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
      );

      expect(
        () => capturedVerifyHostKey!(
          'ssh-ed25519',
          Uint8List.fromList([0x99, 0x99, 0x99]), // wrong fingerprint
        ),
        throwsA(isA<SshHostKeyMismatchException>()),
      );
    });
  });

  group('SftpService File Operations', () {
    late MockTrustedHostKeyStorage mockStorage;
    late MockSSHSocket mockSocket;
    late MockSSHClient mockSshClient;
    late MockSftpClient mockSftpClient;
    late MockSftpFile mockSftpFile;
    late SftpService service;

    setUp(() async {
      mockStorage = MockTrustedHostKeyStorage();
      mockSocket = MockSSHSocket();
      mockSshClient = MockSSHClient();
      mockSftpClient = MockSftpClient();
      mockSftpFile = MockSftpFile();

      when(() => mockSshClient.authenticated).thenAnswer((_) async {});
      when(() => mockSshClient.sftp()).thenAnswer((_) async => mockSftpClient);
      when(() => mockSftpClient.handshake).thenAnswer((_) async => SftpHandsake(3, {}));

      when(() => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22))
          .thenAnswer((_) async => const TrustedHostKeyRecord(
                algorithm: 'ssh-ed25519',
                fingerprint: '11:22:33:44',
              ));

      service = SftpService(
        trustedHostKeyStorage: mockStorage,
        sshSocketFactory: (host, port) async => mockSocket,
        sshClientFactory: (
          socket, {
          required username,
          identities,
          onPasswordRequest,
          onVerifyHostKey,
        }) {
          if (onVerifyHostKey != null) {
            onVerifyHostKey('ssh-ed25519', Uint8List.fromList([0x11, 0x22, 0x33, 0x44]));
          }
          return mockSshClient;
        },
      );

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
      );
    });

    test('listDirectory', () async {
      final dummyStats = <SftpName>[
        SftpName(filename: 'file1.txt', longname: 'file1.txt', attr: SftpFileAttrs()),
      ];
      when(() => mockSftpClient.listdir('/path')).thenAnswer((_) async => dummyStats);

      final result = await service.listDirectory('/path');
      expect(result, equals(dummyStats));
      verify(() => mockSftpClient.listdir('/path')).called(1);
    });

    test('createDirectory', () async {
      when(() => mockSftpClient.mkdir('/path')).thenAnswer((_) async {});
      await service.createDirectory('/path');
      verify(() => mockSftpClient.mkdir('/path')).called(1);
    });

    test('removeFile', () async {
      when(() => mockSftpClient.remove('/path')).thenAnswer((_) async {});
      await service.removeFile('/path');
      verify(() => mockSftpClient.remove('/path')).called(1);
    });

    test('removeDirectory', () async {
      when(() => mockSftpClient.rmdir('/path')).thenAnswer((_) async {});
      await service.removeDirectory('/path');
      verify(() => mockSftpClient.rmdir('/path')).called(1);
    });

    test('readFile', () async {
      when(() => mockSftpClient.open('/path', mode: SftpFileOpenMode.read))
          .thenAnswer((_) async => mockSftpFile);
      when(() => mockSftpFile.readBytes())
          .thenAnswer((_) async => Uint8List.fromList(utf8.encode('hello')));
      when(() => mockSftpFile.close()).thenAnswer((_) async {});

      final result = await service.readFile('/path');
      expect(result, 'hello');
      verify(() => mockSftpFile.close()).called(1);
    });

    test('writeFile', () async {
      when(
        () => mockSftpClient.open(
          '/path',
          mode: any(named: 'mode'),
        ),
      ).thenAnswer((_) async => mockSftpFile);
      when(() => mockSftpFile.writeBytes(any())).thenAnswer((_) async {});
      when(() => mockSftpFile.close()).thenAnswer((_) async {});

      await service.writeFile('/path', 'hello');

      verify(
        () => mockSftpClient.open(
          '/path',
          mode: any(named: 'mode'),
        ),
      ).called(1);
      verify(() => mockSftpFile.writeBytes(any())).called(1);
      verify(() => mockSftpFile.close()).called(1);
    });
  });

  group('SftpService Upload/Download & Sudo Fallback', () {
    late MockTrustedHostKeyStorage mockStorage;
    late MockSSHSocket mockSocket;
    late MockSSHClient mockSshClient;
    late MockSftpClient mockSftpClient;
    late MockSftpFile mockSftpFile;
    late MockSSHSession mockSshSession;
    late SftpService service;

    setUp(() async {
      mockStorage = MockTrustedHostKeyStorage();
      mockSocket = MockSSHSocket();
      mockSshClient = MockSSHClient();
      mockSftpClient = MockSftpClient();
      mockSftpFile = MockSftpFile();
      mockSshSession = MockSSHSession();

      when(() => mockSshClient.authenticated).thenAnswer((_) async {});
      when(() => mockSshClient.sftp()).thenAnswer((_) async => mockSftpClient);
      when(() => mockSftpClient.handshake).thenAnswer((_) async => SftpHandsake(3, {}));

      when(() => mockStorage.loadTrustedHostKey(host: 'localhost', port: 22))
          .thenAnswer((_) async => const TrustedHostKeyRecord(
                algorithm: 'ssh-ed25519',
                fingerprint: '11:22:33:44',
              ));

      service = SftpService(
        trustedHostKeyStorage: mockStorage,
        sshSocketFactory: (host, port) async => mockSocket,
        sshClientFactory: (
          socket, {
          required username,
          identities,
          onPasswordRequest,
          onVerifyHostKey,
        }) {
          if (onVerifyHostKey != null) {
            onVerifyHostKey('ssh-ed25519', Uint8List.fromList([0x11, 0x22, 0x33, 0x44]));
          }
          return mockSshClient;
        },
      );

      await service.connect(
        host: 'localhost',
        port: 22,
        username: 'user',
        password: 'password',
      );
    });

    test('downloadFile', () async {
      when(() => mockSftpClient.open('/remote', mode: any(named: 'mode')))
          .thenAnswer((_) async => mockSftpFile);
      when(() => mockSftpFile.read())
          .thenAnswer((_) => Stream.fromIterable([Uint8List.fromList([1, 2, 3])]));
      when(() => mockSftpFile.close()).thenAnswer((_) async {});

      final tempFile = File('test_download.tmp');
      if (tempFile.existsSync()) tempFile.deleteSync();

      await service.downloadFile('/remote', tempFile.path);

      expect(tempFile.existsSync(), isTrue);
      expect(tempFile.readAsBytesSync(), [1, 2, 3]);

      tempFile.deleteSync();
      verify(() => mockSftpFile.close()).called(1);
    });

    test('uploadFile', () async {
      when(() => mockSftpClient.open('/remote', mode: any(named: 'mode')))
          .thenAnswer((_) async => mockSftpFile);
      // dartssh2's SftpFile.write returns SftpFileWriter which has a `done` Future.
      // We can just throw or mock if needed. If mockSftpFile is fully mocked,
      // we can return a mock SftpFileWriter or just cast a Future.
      // Actually, since we only want the test to pass without executing the stream fully,
      // let's create a dummy SftpFileWriter. Wait, it's easier to mock SftpFileWriter.
      final mockWriter = SftpFileWriter(mockSftpFile, Stream.empty(), 0, null);
      when(() => mockSftpFile.write(any())).thenAnswer((_) => mockWriter);
      when(() => mockSftpFile.close()).thenAnswer((_) async {});

      final tempFile = File('test_upload.tmp');
      tempFile.writeAsBytesSync([4, 5, 6]);

      await service.uploadFile(tempFile.path, '/remote');

      verify(() => mockSftpFile.write(any())).called(1);
      verify(() => mockSftpFile.close()).called(1);

      tempFile.deleteSync();
    });

    test('writeFileWithSudoFallback triggers sudo cp on permission denied', () async {
      // First write fails with permission denied
      when(
        () => mockSftpClient.open('/protected_path', mode: any(named: 'mode')),
      ).thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'));

      // Fallback write succeeds
      when(
        () => mockSftpClient.open('/tmp/hamma_temp_edit', mode: any(named: 'mode')),
      ).thenAnswer((_) async => mockSftpFile);
      when(() => mockSftpFile.writeBytes(any())).thenAnswer((_) async {});
      when(() => mockSftpFile.close()).thenAnswer((_) async {});

      // Sudo cp execution
      when(() => mockSshClient.execute(any())).thenAnswer((_) async => mockSshSession);
      when(() => mockSshSession.stderr).thenAnswer((_) => Stream.empty());
      when(() => mockSshSession.done).thenAnswer((_) async {});

      var promptCalled = false;

      await service.writeFileWithSudoFallback(
        '/protected_path',
        'content',
        onSudoFallbackPrompt: () async {
          promptCalled = true;
          return true; // user accepts sudo
        },
      );

      expect(promptCalled, isTrue);

      verify(
        () => mockSshClient.execute(
          "sudo cp -- '/tmp/hamma_temp_edit' '/protected_path'",
        ),
      ).called(1);

      verify(
        () => mockSshClient.execute(
          "rm -f -- '/tmp/hamma_temp_edit'",
        ),
      ).called(1);
    });
  });
}
