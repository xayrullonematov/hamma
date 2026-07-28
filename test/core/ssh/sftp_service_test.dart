import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/sftp_service.dart';

class _FakeSftpClient implements SftpClient {
  final Future<SftpFile> Function(String, {SftpFileOpenMode mode}) openCallback;

  _FakeSftpClient({required this.openCallback});

  @override
  Future<SftpFile> open(String path, {SftpFileOpenMode mode = SftpFileOpenMode.read}) {
    return openCallback(path, mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSftpFile implements SftpFile {
  final Future<Uint8List> Function({int? length, int offset})? readBytesCallback;

  // Custom tracking property, not an override of SftpFile
  bool hasBeenClosed = false;

  _FakeSftpFile({this.readBytesCallback});

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) {
    if (readBytesCallback != null) {
      return readBytesCallback!(length: length, offset: offset);
    }
    throw UnimplementedError();
  }

  @override
  Future<void> close() async {
    hasBeenClosed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestSftpService extends SftpService {
  final SftpClient mockClient;

  TestSftpService(this.mockClient);

  @override
  SftpClient get client => mockClient;
}

void main() {
  group('SftpService', () {
    test('readFile throws exception and closes file if readBytes fails', () async {
      final fakeFile = _FakeSftpFile(
        readBytesCallback: ({int? length, int offset = 0}) async {
          throw Exception('Failed to read bytes');
        },
      );

      final fakeClient = _FakeSftpClient(
        openCallback: (String path, {SftpFileOpenMode mode = SftpFileOpenMode.read}) async {
          return fakeFile;
        },
      );

      final service = TestSftpService(fakeClient);

      await expectLater(
        service.readFile('test.txt'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('Failed to read bytes'))),
      );

      expect(fakeFile.hasBeenClosed, isTrue);
    });
  });
}
