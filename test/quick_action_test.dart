import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/features/quick_actions/quick_actions.dart';

void main() {
  group('QuickAction.fromJson', () {
    test('parses all fields correctly', () {
      final json = {
        'id': 'action-1',
        'label': 'Check Disk',
        'command': 'df -h',
        'isCustom': true,
      };
      final action = QuickAction.fromJson(json);

      expect(action.id, 'action-1');
      expect(action.label, 'Check Disk');
      expect(action.command, 'df -h');
      expect(action.isCustom, isTrue);
    });

    test('defaults isCustom to false when absent', () {
      final action = QuickAction.fromJson({
        'id': 'x',
        'label': 'X',
        'command': 'ls',
      });
      expect(action.isCustom, isFalse);
    });

    test('parses isCustom from string "true"', () {
      final action = QuickAction.fromJson({
        'id': 'x',
        'label': 'X',
        'command': 'ls',
        'isCustom': 'true',
      });
      expect(action.isCustom, isTrue);
    });

    test('parses isCustom from string "false"', () {
      final action = QuickAction.fromJson({
        'id': 'x',
        'label': 'X',
        'command': 'ls',
        'isCustom': 'false',
      });
      expect(action.isCustom, isFalse);
    });

    test('defaults id, label, command to empty string when absent', () {
      final action = QuickAction.fromJson({});
      expect(action.id, '');
      expect(action.label, '');
      expect(action.command, '');
    });

    test('coerces non-string id to string', () {
      final action = QuickAction.fromJson({'id': 42, 'label': 'L', 'command': 'c'});
      expect(action.id, '42');
    });
  });

  group('QuickAction.toJson', () {
    test('serializes all fields', () {
      const action = QuickAction(
        id: 'action-2',
        label: 'Restart',
        command: 'sudo reboot',
        isCustom: true,
      );
      final json = action.toJson();

      expect(json['id'], 'action-2');
      expect(json['label'], 'Restart');
      expect(json['command'], 'sudo reboot');
      expect(json['isCustom'], isTrue);
    });

    test('round-trips through fromJson correctly', () {
      const original = QuickAction(
        id: 'rt-1',
        label: 'Round Trip',
        command: 'echo round-trip',
        isCustom: false,
      );
      final restored = QuickAction.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.label, original.label);
      expect(restored.command, original.command);
      expect(restored.isCustom, original.isCustom);
    });
  });

  group('kQuickActions', () {
    test('contains at least one action', () {
      expect(kQuickActions, isNotEmpty);
    });

    test('all built-in actions have non-empty id, label, and command', () {
      for (final action in kQuickActions) {
        expect(action.id, isNotEmpty, reason: 'action ${action.label} has empty id');
        expect(action.label, isNotEmpty);
        expect(action.command, isNotEmpty);
      }
    });

    test('all built-in action IDs are unique', () {
      final ids = kQuickActions.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('built-in actions have isCustom = false', () {
      for (final action in kQuickActions) {
        expect(action.isCustom, isFalse, reason: '${action.id} should not be custom');
      }
    });
  });
}
