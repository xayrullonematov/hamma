import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/sftp_service.dart';

class FakeSftpClient implements SftpClient {
  final List<String> rmdirCalls = [];

  @override
  Future<void> rmdir(String path) async {
    rmdirCalls.add(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestableSftpService extends SftpService {
  final SftpClient fakeClient;

  TestableSftpService(this.fakeClient);

  @override
  SftpClient get client => fakeClient;
}

void main() {
  group('SftpService', () {
    test('removeDirectory calls rmdir on the SFTP client with the correct path', () async {
      final fakeClient = FakeSftpClient();
      final service = TestableSftpService(fakeClient);

      await service.removeDirectory('/some/test/dir');

      expect(fakeClient.rmdirCalls, ['/some/test/dir']);
    });
  });
}
