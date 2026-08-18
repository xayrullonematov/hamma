import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/plugins/builtin/proxmox_plugin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxmoxPlugin parseNodes testing', () {
    test('handles missing CPU and mem keys correctly', () {
      final state = ProxmoxPanelState();

      final jsonWithMissingKeys = '''
      {
        "data": [
          {
            "node": "pve1",
            "status": "online"
          }
        ]
      }
      ''';

      final nodes = state.parseNodes(jsonWithMissingKeys);

      expect(nodes.length, 1);
      final node = nodes.first;
      expect(node.name, 'pve1');
      expect(node.status, 'online');
      expect(node.cpu, 0.0);
      expect(node.memMb, 0);
    });
  });
}
