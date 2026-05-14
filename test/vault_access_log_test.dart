import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_access_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VaultAccessLog', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('log appends and trims correctly', () async {
      final accessLog = VaultAccessLog();

      final event = VaultAccessEvent(
        secretId: 's1',
        action: VaultAccessAction.copied,
        timestamp: DateTime.now(),
      );

      await accessLog.log(event);
      
      final last = await accessLog.lastAccessed('s1');
      expect(last, isNotNull);
    });

    test('lastAccessed returns newest timestamp', () async {
      final accessLog = VaultAccessLog();
      final now = DateTime.now();
      final older = now.subtract(const Duration(hours: 1));
      
      await accessLog.log(VaultAccessEvent(
        secretId: 's1',
        action: VaultAccessAction.revealed,
        timestamp: older,
      ));

      await accessLog.log(VaultAccessEvent(
        secretId: 's1',
        action: VaultAccessAction.copied,
        timestamp: now,
      ));

      final last = await accessLog.lastAccessed('s1');
      // Use millisecond comparison to avoid precision issues in serialization if any
      expect(last?.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    });

    test('recentEvents returns limited list', () async {
       final accessLog = VaultAccessLog();
       
       for (int i = 0; i < 100; i++) {
         await accessLog.log(VaultAccessEvent(
           secretId: 's$i',
           action: VaultAccessAction.copied,
           timestamp: DateTime.now(),
         ));
       }
       
       final recent = await accessLog.recentEvents(limit: 10);
       expect(recent.length, 10);
    });

    test('trims to 500 events', () async {
       final accessLog = VaultAccessLog();
       
       // Log more than 500 events
       for (int i = 0; i < 550; i++) {
         await accessLog.log(VaultAccessEvent(
           secretId: 's$i',
           action: VaultAccessAction.copied,
           timestamp: DateTime.now(),
         ));
       }
       
       final all = await accessLog.recentEvents(limit: 1000);
       expect(all.length, 500);
       // The first one should be the last one logged (s549)
       expect(all.first.secretId, 's549');
    });
  });
}
