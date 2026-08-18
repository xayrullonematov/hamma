import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/background/background_keepalive.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('BackgroundKeepalive Initialization and State Management', () {
    test('initialize returns normally on non-mobile platforms', () async {
      await expectLater(BackgroundKeepalive.initialize(), completes);
    });

    test('enable returns normally on non-mobile platforms', () async {
      await expectLater(BackgroundKeepalive.enable(), completes);
    });

    test('disable returns normally on non-mobile platforms', () async {
      await expectLater(BackgroundKeepalive.disable(), completes);
    });
  });

  group('Tasks Execution (Early Returns)', () {
    test('handleHealthTask returns true early when health monitoring is disabled', () async {
      // By default mock values are empty, so health monitoring is disabled.
      final result = await handleHealthTask();
      expect(result, isTrue);
    });

    test('handleHealthTask returns true early when no saved servers exist', () async {
      FlutterSecureStorage.setMockInitialValues({
        'health_monitoring_enabled': 'true',
      });
      final result = await handleHealthTask();
      expect(result, isTrue);
    });

    test('handleBackupTask completes gracefully without throwing', () async {
      // This will attempt a backup without configuration, likely resulting in false
      // due to caught exceptions inside the task, but the function itself shouldn't throw.
      final result = await handleBackupTask();
      expect(result, isFalse); // Because no backup configuration is set up
    });
  });
}
