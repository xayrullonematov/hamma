import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/sftp_service.dart';

class _FakeSftpFile implements SftpFile {
  _FakeSftpFile(this.bytes, {this.shouldThrow = false});

  final Uint8List bytes;
  final bool shouldThrow;
  @override
  bool isClosed = false;

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    if (shouldThrow) {
      throw Exception('readBytes error');
    }
    return bytes;
  }

  @override
  Future<void> close() async {
    isClosed = true;
  }

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _FakeSftpClient implements SftpClient {
  _FakeSftpClient(this.bytes, {this.shouldThrow = false});

  final Uint8List bytes;
  final bool shouldThrow;
  _FakeSftpFile? lastOpenedFile;

  @override
  Future<SftpFile> open(String path, {SftpFileOpenMode mode = SftpFileOpenMode.read}) async {
    lastOpenedFile = _FakeSftpFile(bytes, shouldThrow: shouldThrow);
    return lastOpenedFile!;
  }

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _TestSftpService extends SftpService {
  _TestSftpService(this.fakeClient);

  final _FakeSftpClient fakeClient;

  @override
  SftpClient get client => fakeClient;
}

void main() {
  group('SftpService.readFile', () {
    test('reads and decodes file content', () async {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final fakeClient = _FakeSftpClient(bytes);
      final service = _TestSftpService(fakeClient);

      final content = await service.readFile('/path/to/file.txt');

      expect(content, 'hello world');
      expect(fakeClient.lastOpenedFile!.isClosed, true);
    });

    test('decodes invalid UTF-8 with allowMalformed: true', () async {
      final bytes = Uint8List.fromList([0xFF, 0xFE, 0xFD]);
      final fakeClient = _FakeSftpClient(bytes);
      final service = _TestSftpService(fakeClient);

      final content = await service.readFile('/path/to/file.txt');

      expect(content, isNotNull);
      expect(fakeClient.lastOpenedFile!.isClosed, true);
    });

    test('closes file if reading throws', () async {
      final bytes = Uint8List.fromList([]);
      final fakeClient = _FakeSftpClient(bytes, shouldThrow: true);
      final service = _TestSftpService(fakeClient);

      await expectLater(
        service.readFile('/path/to/file.txt'),
        throwsException,
      );

      expect(fakeClient.lastOpenedFile!.isClosed, true);
    });
  });
}
