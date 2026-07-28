import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ssh/fleet_service.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/core/storage/trusted_host_key_storage.dart';

class _FakeTrustedHostKeyStorage implements TrustedHostKeyStorage {
  @override
  Future<TrustedHostKeyRecord?> loadTrustedHostKey({required String host, required int port}) async => null;
  @override
  Future<void> saveTrustedHostKey({required String host, required int port, required TrustedHostKeyRecord record}) async {}
}

class _TestFleetService extends FleetService {
  final Map<String, ServerMetrics> mockResponses;
  final Duration delay = const Duration(milliseconds: 50);
  int concurrentCalls = 0;
  int maxConcurrentCalls = 0;

  _TestFleetService({
    required this.mockResponses,
  }) : super(trustedHostKeyStorage: _FakeTrustedHostKeyStorage());

  @override
  Future<ServerMetrics> pollServer(ServerProfile server) async {
    concurrentCalls++;
    if (concurrentCalls > maxConcurrentCalls) {
      maxConcurrentCalls = concurrentCalls;
    }

    await Future<void>.delayed(delay);

    concurrentCalls--;
    return mockResponses[server.id] ?? ServerMetrics.failed('Not mocked');
  }
}

void main() {
  group('FleetService.pollFleet', () {
    test('polls multiple servers concurrently', () async {
      final s1 = ServerProfile(id: '1', name: 's1', host: 'host1', port: 22, username: 'user1', password: 'pwd');
      final s2 = ServerProfile(id: '2', name: 's2', host: 'host2', port: 22, username: 'user2', password: 'pwd');
      final s3 = ServerProfile(id: '3', name: 's3', host: 'host3', port: 22, username: 'user3', password: 'pwd');

      final metrics1 = ServerMetrics(cpuPercentage: 10, ramPercentage: 20, diskPercentage: 30, collectedAt: DateTime.now());
      final metrics2 = ServerMetrics(cpuPercentage: 40, ramPercentage: 50, diskPercentage: 60, collectedAt: DateTime.now());
      final metrics3 = ServerMetrics.failed('Error');

      final service = _TestFleetService(
        mockResponses: {
          '1': metrics1,
          '2': metrics2,
          '3': metrics3,
        },
      );

      final result = await service.pollFleet([s1, s2, s3]);

      // Check results
      expect(result.length, 3);
      expect(result['1'], metrics1);
      expect(result['2'], metrics2);
      expect(result['3'], metrics3);

      // Check concurrency
      expect(service.maxConcurrentCalls, 3);
    });

    test('handles empty list', () async {
      final service = _TestFleetService(mockResponses: {});
      final result = await service.pollFleet([]);
      expect(result, isEmpty);
    });
  });
}
