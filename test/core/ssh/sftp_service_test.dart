import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/sftp_service.dart';
import 'package:hamma/core/ssh/ssh_service.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';
import 'package:mocktail/mocktail.dart';

class MockSftpClient extends Mock implements SftpClient {}
class MockSftpFile extends Mock implements SftpFile {}
class MockSSHClient extends Mock implements SSHClient {}
class MockSSHSession extends Mock implements SSHSession {}
class MockTrustedHostKeyStorage extends Mock implements TrustedHostKeyStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SftpService', () {
    late SftpService service;
    late MockSftpClient mockSftpClient;
    late MockSSHClient mockSSHClient;
    late MockTrustedHostKeyStorage mockStorage;

    setUpAll(() {
      registerFallbackValue(Uint8List(0));
      registerFallbackValue(Stream<Uint8List>.empty());
      registerFallbackValue(SftpFileOpenMode.read);
      registerFallbackValue(const TrustedHostKeyRecord(algorithm: 'ssh-rsa', fingerprint: ''));
    });

    setUp(() {
      mockSftpClient = MockSftpClient();
      mockSSHClient = MockSSHClient();
      mockStorage = MockTrustedHostKeyStorage();
      service = SftpService(trustedHostKeyStorage: mockStorage);
    });

    test('client throws StateError if not connected', () {
      expect(() => service.client, throwsStateError);
      expect(service.isConnected, isFalse);
    });

    test('isConnected is true when clients are set', () {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      expect(service.isConnected, isTrue);
      expect(service.client, mockSftpClient);
    });

    test('listDirectory calls client.listdir', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      when(() => mockSftpClient.listdir(any())).thenAnswer((_) async => []);

      final result = await service.listDirectory('/path');
      expect(result, isEmpty);
      verify(() => mockSftpClient.listdir('/path')).called(1);
    });

    test('createDirectory calls client.mkdir', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      when(() => mockSftpClient.mkdir(any())).thenAnswer((_) async {});

      await service.createDirectory('/path/dir');
      verify(() => mockSftpClient.mkdir('/path/dir')).called(1);
    });

    test('removeDirectory calls client.rmdir', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      when(() => mockSftpClient.rmdir(any())).thenAnswer((_) async {});

      await service.removeDirectory('/path/dir');
      verify(() => mockSftpClient.rmdir('/path/dir')).called(1);
    });

    test('removeFile calls client.remove', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      when(() => mockSftpClient.remove(any())).thenAnswer((_) async {});

      await service.removeFile('/path/file.txt');
      verify(() => mockSftpClient.remove('/path/file.txt')).called(1);
    });

    test('readFile reads bytes and closes file', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      final mockFile = MockSftpFile();
      when(() => mockSftpClient.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.readBytes())
          .thenAnswer((_) async => Uint8List.fromList(utf8.encode('hello')));
      when(() => mockFile.close()).thenAnswer((_) async {});

      final result = await service.readFile('/path/file.txt');
      expect(result, 'hello');
      verify(() => mockSftpClient.open('/path/file.txt', mode: SftpFileOpenMode.read)).called(1);
      verify(() => mockFile.readBytes()).called(1);
      verify(() => mockFile.close()).called(1);
    });

    test('writeFile writes encoded bytes and closes file', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      final mockFile = MockSftpFile();
      when(() => mockSftpClient.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.writeBytes(any())).thenAnswer((_) async {});
      when(() => mockFile.close()).thenAnswer((_) async {});

      await service.writeFile('/path/file.txt', 'hello');

      verify(() => mockSftpClient.open('/path/file.txt', mode: any(named: 'mode'))).called(1);
      verify(() => mockFile.writeBytes(any(that: isA<Uint8List>()))).called(1);
      verify(() => mockFile.close()).called(1);
    });

    test('downloadFile reads stream and writes to local file', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      final mockFile = MockSftpFile();
      when(() => mockSftpClient.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.read(length: any(named: 'length')))
          .thenAnswer((_) => Stream.fromIterable([Uint8List.fromList([1, 2, 3])]));
      when(() => mockFile.close()).thenAnswer((_) async {});

      final tempDir = await Directory.systemTemp.createTemp('sftp_test');
      final tempFile = File('${tempDir.path}/test_download.txt');
      await service.downloadFile('/remote/file', tempFile.path);

      expect(await tempFile.exists(), isTrue);
      expect(await tempFile.readAsBytes(), [1, 2, 3]);

      await tempDir.delete(recursive: true);
      verify(() => mockSftpClient.open('/remote/file', mode: SftpFileOpenMode.read)).called(1);
      verify(() => mockFile.read()).called(1);
      verify(() => mockFile.close()).called(1);
    });

    test('uploadFile reads local file and writes stream', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      final mockFile = MockSftpFile();
      when(() => mockSftpClient.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);

      final mockWriter = SftpFileWriter(mockFile, Stream.empty(), 0, null);
      when(() => mockFile.write(any())).thenAnswer((_) => mockWriter);
      when(() => mockFile.close()).thenAnswer((_) async {});

      final tempDir = await Directory.systemTemp.createTemp('sftp_test');
      final tempFile = File('${tempDir.path}/test_upload.txt');
      await tempFile.writeAsBytes([4, 5, 6]);

      await service.uploadFile(tempFile.path, '/remote/file');

      await tempDir.delete(recursive: true);
      verify(() => mockSftpClient.open('/remote/file', mode: any(named: 'mode'))).called(1);
      verify(() => mockFile.write(any())).called(1);
      verify(() => mockFile.close()).called(1);
    });

    test('writeFileWithSudoFallback tries regular write and succeeds', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);
      final mockFile = MockSftpFile();
      when(() => mockSftpClient.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.writeBytes(any())).thenAnswer((_) async {});
      when(() => mockFile.close()).thenAnswer((_) async {});

      var promptCalled = false;
      await service.writeFileWithSudoFallback(
        '/path/file.txt',
        'hello',
        onSudoFallbackPrompt: () async {
          promptCalled = true;
          return true;
        },
      );

      expect(promptCalled, isFalse);
      verify(() => mockSftpClient.open('/path/file.txt', mode: any(named: 'mode'))).called(1);
    });

    test('writeFileWithSudoFallback triggers sudo fallback on permission denied', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);

      final mockFile = MockSftpFile();
      final mockTempFile = MockSftpFile();
      final mockSession = MockSSHSession();

      // First open for /etc/file.txt throws permission denied
      when(() => mockSftpClient.open('/etc/file.txt', mode: any(named: 'mode')))
          .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'));

      // Second open for temp path succeeds
      when(() => mockSftpClient.open('/tmp/hamma_temp_edit', mode: any(named: 'mode')))
          .thenAnswer((_) async => mockTempFile);
      when(() => mockTempFile.writeBytes(any())).thenAnswer((_) async {});
      when(() => mockTempFile.close()).thenAnswer((_) async {});

      // mock _runShellCommand ssh executions
      when(() => mockSSHClient.execute(any())).thenAnswer((_) async => mockSession);
      when(() => mockSession.stderr).thenAnswer((_) => Stream.empty());
      when(() => mockSession.done).thenAnswer((_) async {});

      var promptCalled = false;
      await service.writeFileWithSudoFallback(
        '/etc/file.txt',
        'hello',
        onSudoFallbackPrompt: () async {
          promptCalled = true;
          return true;
        },
      );

      expect(promptCalled, isTrue);
      verify(() => mockSftpClient.open('/etc/file.txt', mode: any(named: 'mode'))).called(1);
      verify(() => mockSftpClient.open('/tmp/hamma_temp_edit', mode: any(named: 'mode'))).called(1);

      // Verification for sudo cp command
      verify(() => mockSSHClient.execute("sudo cp -- '/tmp/hamma_temp_edit' '/etc/file.txt'")).called(1);
      // Verification for rm command
      verify(() => mockSSHClient.execute("rm -f -- '/tmp/hamma_temp_edit'")).called(1);
    });

    test('writeFileWithSudoFallback cancels when prompt returns false', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);

      when(() => mockSftpClient.open('/etc/file.txt', mode: any(named: 'mode')))
          .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'));

      expect(
        () => service.writeFileWithSudoFallback(
          '/etc/file.txt',
          'hello',
          onSudoFallbackPrompt: () async => false,
        ),
        throwsA(isA<SftpSudoFallbackCancelledException>())
      );
    });

    test('dispose closes both clients and clears state', () async {
      service.setClientsForTest(mockSSHClient, mockSftpClient);

      expect(service.isConnected, isTrue);

      await service.dispose();

      verify(() => mockSftpClient.close()).called(1);
      verify(() => mockSSHClient.close()).called(1);
      expect(service.isConnected, isFalse);
    });
  });
}
