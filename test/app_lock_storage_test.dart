import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/app_lock_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLockStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const AppLockStorage();
  });

  group('hasPin / readPin with no saved PIN', () {
    test('readPin returns null when nothing saved', () async {
      expect(await storage.readPin(), isNull);
    });

    test('hasPin returns false when nothing saved', () async {
      expect(await storage.hasPin(), isFalse);
    });
  });

  group('savePin', () {
    test('saves and retrieves a PIN', () async {
      await storage.savePin('1234');
      expect(await storage.readPin(), '1234');
      expect(await storage.hasPin(), isTrue);
    });

    test('trims whitespace before saving', () async {
      await storage.savePin('  5678  ');
      expect(await storage.readPin(), '5678');
    });

    test('saving an empty string deletes the PIN', () async {
      await storage.savePin('9999');
      await storage.savePin('');
      expect(await storage.readPin(), isNull);
      expect(await storage.hasPin(), isFalse);
    });

    test('saving a whitespace-only string deletes the PIN', () async {
      await storage.savePin('1111');
      await storage.savePin('   ');
      expect(await storage.readPin(), isNull);
    });

    test('overwriting with a new PIN replaces the old one', () async {
      await storage.savePin('1111');
      await storage.savePin('2222');
      expect(await storage.readPin(), '2222');
    });
  });

  group('deletePin', () {
    test('removes a saved PIN', () async {
      await storage.savePin('4321');
      await storage.deletePin();
      expect(await storage.readPin(), isNull);
      expect(await storage.hasPin(), isFalse);
    });

    test('is idempotent when no PIN was saved', () async {
      await expectLater(storage.deletePin(), completes);
      expect(await storage.hasPin(), isFalse);
    });
  });
}
