import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/plugins/hamma_plugin.dart';
import 'package:hamma/plugins/hamma_api.dart';

void main() {
  group('HammaPluginPaletteAction', () {
    test('assigns properties correctly', () async {
      bool runCalled = false;
      Future<void> mockRun(BuildContext context, HammaApi api) async {
        runCalled = true;
      }

      final action = HammaPluginPaletteAction(
        id: 'test_id',
        label: 'Test Label',
        description: 'Test Description',
        icon: Icons.add,
        run: mockRun,
      );

      expect(action.id, 'test_id');
      expect(action.label, 'Test Label');
      expect(action.description, 'Test Description');
      expect(action.icon, Icons.add);

      // Test the run callback
      final context = _MockBuildContext();
      final api = _MockHammaApi();
      await action.run(context, api);
      expect(runCalled, isTrue);
    });
  });
}

class _MockBuildContext extends BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHammaApi implements HammaApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
