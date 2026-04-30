import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/custom_actions_storage.dart';
import 'package:hamma/features/quick_actions/quick_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CustomActionsStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const CustomActionsStorage();
  });

  group('loadActions — empty state', () {
    test('returns empty list when nothing is saved', () async {
      final actions = await storage.loadActions();
      expect(actions, isEmpty);
    });
  });

  group('saveActions / loadActions round-trip', () {
    test('saves and retrieves a single action', () async {
      final action = QuickAction(
        id: 'custom-001',
        label: 'Check uptime',
        command: 'uptime',
        isCustom: true,
      );
      await storage.saveActions([action]);

      final result = await storage.loadActions();
      expect(result, hasLength(1));
      expect(result.first.id, 'custom-001');
      expect(result.first.label, 'Check uptime');
      expect(result.first.command, 'uptime');
      expect(result.first.isCustom, isTrue);
    });

    test('saves and retrieves multiple actions in order', () async {
      final actions = [
        const QuickAction(id: 'a', label: 'First', command: 'echo 1', isCustom: true),
        const QuickAction(id: 'b', label: 'Second', command: 'echo 2', isCustom: true),
        const QuickAction(id: 'c', label: 'Third', command: 'echo 3', isCustom: true),
      ];
      await storage.saveActions(actions);

      final result = await storage.loadActions();
      expect(result, hasLength(3));
      expect(result.map((a) => a.id).toList(), ['a', 'b', 'c']);
    });

    test('forces isCustom to true on load even if saved as false', () async {
      final action = const QuickAction(
        id: 'built-in',
        label: 'System Info',
        command: 'uname -a',
        isCustom: false,
      );
      await storage.saveActions([action]);

      final result = await storage.loadActions();
      expect(result.first.isCustom, isTrue);
    });

    test('overwrites previous actions on second save', () async {
      await storage.saveActions([
        const QuickAction(id: 'old', label: 'Old', command: 'old', isCustom: true),
      ]);
      await storage.saveActions([
        const QuickAction(id: 'new', label: 'New', command: 'new', isCustom: true),
      ]);

      final result = await storage.loadActions();
      expect(result, hasLength(1));
      expect(result.first.id, 'new');
    });

    test('saves empty list — subsequent load returns empty', () async {
      await storage.saveActions([
        const QuickAction(id: 'x', label: 'X', command: 'x', isCustom: true),
      ]);
      await storage.saveActions([]);

      final result = await storage.loadActions();
      expect(result, isEmpty);
    });
  });

  group('ID normalisation on load', () {
    test('assigns a new ID when an action has a blank id', () async {
      final action = const QuickAction(id: '', label: 'No ID', command: 'ls', isCustom: true);
      await storage.saveActions([action]);

      final result = await storage.loadActions();
      expect(result.first.id, isNotEmpty);
    });

    test('de-duplicates actions sharing the same id', () async {
      final dup1 = const QuickAction(id: 'dup', label: 'First', command: 'cmd1', isCustom: true);
      final dup2 = const QuickAction(id: 'dup', label: 'Second', command: 'cmd2', isCustom: true);
      await storage.saveActions([dup1, dup2]);

      final result = await storage.loadActions();
      final ids = result.map((a) => a.id).toList();
      expect(ids.toSet().length, 2);
    });
  });

  group('clearActions', () {
    test('removes all saved actions', () async {
      await storage.saveActions([
        const QuickAction(id: 'z', label: 'Z', command: 'z', isCustom: true),
      ]);
      await storage.clearActions();

      final result = await storage.loadActions();
      expect(result, isEmpty);
    });

    test('is idempotent when nothing was saved', () async {
      await expectLater(storage.clearActions(), completes);
      final result = await storage.loadActions();
      expect(result, isEmpty);
    });
  });

  group('CustomActionsStorageException', () {
    test('toString returns the message', () {
      const e = CustomActionsStorageException('Something failed');
      expect(e.toString(), 'Something failed');
      expect(e, isA<Exception>());
    });
  });
}
