import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_auth_service.dart';
import 'package:hamma/core/storage/app_lock_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultAuthService service;
  late AppLockStorage appLockStorage;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    appLockStorage = const AppLockStorage();
    await appLockStorage.savePin('1234');
    service = VaultAuthService(
      appLockStorage: appLockStorage,
      gracePeriodDuration: const Duration(seconds: 1),
    );
  });

  group('VaultAuthService Lockout', () {
    test('locks out after 3 failed attempts', () async {
      expect(service.isLockedOut, isFalse);

      await service.verifyPin('wrong');
      await service.verifyPin('wrong');
      await service.verifyPin('wrong');

      expect(service.isLockedOut, isTrue);
      expect(service.lockoutRemaining.inSeconds, closeTo(60, 2));
    });

    test('resets failed attempts on success', () async {
      await service.verifyPin('wrong');
      await service.verifyPin('wrong');
      await service.verifyPin('1234');
      
      await service.verifyPin('wrong');
      await service.verifyPin('wrong');
      
      expect(service.isLockedOut, isFalse);
    });
  });

  group('VaultAuthService Grace Period', () {
    test('remains authenticated within grace period', () async {
      expect(service.isAuthenticated, isFalse);
      
      await service.verifyPin('1234');
      expect(service.isAuthenticated, isTrue);
      
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(service.isAuthenticated, isTrue);
      
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(service.isAuthenticated, isFalse);
    });

    test('resetGracePeriod clears authentication', () async {
      await service.verifyPin('1234');
      expect(service.isAuthenticated, isTrue);
      
      service.resetGracePeriod();
      expect(service.isAuthenticated, isFalse);
    });
  });
}
