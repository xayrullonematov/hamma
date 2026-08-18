import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:hamma/plugins/builtin/proxmox_plugin.dart';
import 'package:hamma/plugins/hamma_api.dart';

class FakeHammaApi implements HammaApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<String?> readConfig(String key) async => null;
}

void main() {
  testWidgets('parseResources handles invalid structures', (WidgetTester tester) async {
    final api = FakeHammaApi();

    // We can just instantiate the panel and use create State
    // The panel widget is not public, it is built via buildPanel

    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: Builder(
          builder: (context) {
            return ProxmoxPlugin().buildPanel(context, api);
          }
        )
      )
    ));

    // Find the state by finding a widget inside it or itself, but we can't reference private types directly
    // Let's find by type using runtimeType hack
    final panelWidget = ProxmoxPlugin().buildPanel(
      tester.element(find.byType(Container).first),
      api,
    );
    final state = tester.state(find.byType(panelWidget.runtimeType)) as dynamic;

    // Testing invalid JSON types
    final list1 = state.parseResources('[]');
    expect(list1, isEmpty);

    final list2 = state.parseResources('{"data": {}}');
    expect(list2, isEmpty);

    final list3 = state.parseResources('{"data": [{"type": "qemu", "vmid": "100"}]}');
    expect(list3.length, 1);
  });
}
