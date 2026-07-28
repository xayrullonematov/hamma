import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/sftp_service.dart';
import 'package:mocktail/mocktail.dart';

class MockSftpClient extends Mock implements SftpClient {}
class MockSftpFile extends Mock implements SftpFile {}
class FakeSftpFileOpenMode extends Fake implements SftpFileOpenMode {}
class FakeStreamUint8List extends Fake implements Stream<Uint8List> {}

class TestSftpService extends SftpService {
  final SftpClient fakeClient;
  TestSftpService(this.fakeClient);

  @override
  SftpClient get client => fakeClient;
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeSftpFileOpenMode());
    registerFallbackValue(FakeStreamUint8List());
  });

  test('uploadFile error handling cleans up remote file and closes stream', () async {
    final mockClient = MockSftpClient();
    final mockFile = MockSftpFile();

    when(() => mockClient.open(any(), mode: any(named: 'mode')))
        .thenAnswer((_) async => mockFile);

    when(() => mockFile.write(any()))
        .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'));

    when(() => mockFile.close()).thenAnswer((_) async => {});
    when(() => mockClient.remove(any())).thenAnswer((_) async => {});

    final service = TestSftpService(mockClient);

    // Create a temporary file to read from
    final tempFile = File('${Directory.systemTemp.path}/test_upload.txt');
    await tempFile.writeAsString('test');

    try {
      await expectLater(
        () => service.uploadFile(tempFile.path, '/remote/path.txt'),
        throwsA(isA<SftpStatusError>()),
      );

      verify(() => mockFile.close()).called(greaterThan(0));
      verify(() => mockClient.remove('/remote/path.txt')).called(1);
    } finally {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
    }
  });

  test('uploadFile properly handles file stream read errors', () async {
    final mockClient = MockSftpClient();
    final mockFile = MockSftpFile();

    when(() => mockClient.open(any(), mode: any(named: 'mode')))
        .thenAnswer((_) async => mockFile);

    // We need to simulate the file stream throwing an exception when read.
    // However, File(path).openRead() returns a lazy Stream. When passing a stream to
    // file.write(stream), if file.write does not consume the stream, the stream read error
    // will never occur. To simulate a failure in reading the stream, we just make
    // mockFile.write throw when any stream is passed in, matching what happens if it consumes
    // a bad stream, OR we just let write throw PathNotFoundException to simulate it bubbling up.
    when(() => mockFile.write(any()))
        .thenThrow(const PathNotFoundException('/this/file/does/not/exist.txt', const OSError('No such file or directory')));

    when(() => mockFile.close()).thenAnswer((_) async => {});
    when(() => mockClient.remove(any())).thenAnswer((_) async => {});

    final service = TestSftpService(mockClient);

    await expectLater(
      () => service.uploadFile('/this/file/does/not/exist.txt', '/remote/path.txt'),
      throwsA(isA<PathNotFoundException>()),
    );

    verify(() => mockFile.close()).called(greaterThan(0));
    verify(() => mockClient.remove('/remote/path.txt')).called(1);
  });
}
