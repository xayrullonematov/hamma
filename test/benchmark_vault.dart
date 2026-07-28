import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hamma/core/vault/vault_storage.dart';
import 'package:hamma/core/vault/vault_group.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Benchmark loadAllGroups', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = VaultStorage();

    // Insert 1000 groups
    for (int i = 0; i < 1000; i++) {
      await storage.upsertGroup(VaultGroup(
        id: 'g$i',
        name: 'Group $i',
        type: CredentialType.generic,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    }

    final stopwatch = Stopwatch()..start();
    for (int i = 0; i < 50; i++) {
      await storage.loadAllGroups();
    }
    stopwatch.stop();

    print('Time taken to loadAllGroups 50 times with 1000 items: ${stopwatch.elapsedMilliseconds}ms');
  });
}
