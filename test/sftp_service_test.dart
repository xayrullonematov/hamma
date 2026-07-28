import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:hamma/core/ssh/sftp_service.dart';

import 'sftp_service_test.mocks.dart';

@GenerateMocks([SftpClient, SSHClient])
void main() {
  group('SftpService', () {
    late SftpService service;
    late MockSftpClient mockSftpClient;
    late MockSSHClient mockSshClient;

    setUp(() {
      mockSftpClient = MockSftpClient();
      mockSshClient = MockSSHClient();
      service = SftpService();
      service.setClientForTesting(mockSshClient, mockSftpClient);
    });

    test('removeFile calls client.remove with correct path', () async {
      when(mockSftpClient.remove(any)).thenAnswer((_) async {});

      await service.removeFile('/test/path.txt');

      verify(mockSftpClient.remove('/test/path.txt')).called(1);
    });
  });
}
