import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/plugins/builtin/proxmox_plugin.dart';

void main() {
  group('ProxmoxPlugin JSON decoding tests', () {
    group('parseProxmoxNodes', () {
      test('successfully parses valid JSON response', () {
        final jsonResponse = jsonEncode({
          'data': [
            {
              'node': 'pve1',
              'status': 'online',
              'cpu': 0.15,
              'mem': 10485760, // 10 MiB
            },
            {
              'node': 'pve2',
              'status': 'offline',
            }
          ]
        });

        final nodes = parseProxmoxNodes(jsonResponse);

        expect(nodes.length, 2);

        expect(nodes[0].name, 'pve1');
        expect(nodes[0].status, 'online');
        expect(nodes[0].cpu, 15.0);
        expect(nodes[0].memMb, 10);

        expect(nodes[1].name, 'pve2');
        expect(nodes[1].status, 'offline');
        expect(nodes[1].cpu, 0.0);
        expect(nodes[1].memMb, 0);
      });

      test('throws FormatException on invalid JSON syntax', () {
        const invalidJson = '{"data": [ { "node"'; // malformed json
        expect(
          () => parseProxmoxNodes(invalidJson),
          throwsA(isA<FormatException>()),
        );
      });

      test('returns empty list if response is not a Map', () {
        const jsonResponse = '["data"]'; // valid JSON but array, not map
        final nodes = parseProxmoxNodes(jsonResponse);
        expect(nodes, isEmpty);
      });

      test('returns empty list if data key is missing or not a List', () {
        const jsonResponseMissingData = '{"other_key": []}';
        expect(parseProxmoxNodes(jsonResponseMissingData), isEmpty);

        const jsonResponseDataNotList = '{"data": "not a list"}';
        expect(parseProxmoxNodes(jsonResponseDataNotList), isEmpty);
      });

      test('ignores data elements that are not Maps', () {
        final jsonResponse = jsonEncode({
          'data': [
            {'node': 'pve1'},
            'invalid_element',
            ['another_invalid'],
          ]
        });

        final nodes = parseProxmoxNodes(jsonResponse);
        expect(nodes.length, 1);
        expect(nodes.first.name, 'pve1');
      });
    });

    group('parseProxmoxResources', () {
      test('successfully parses valid JSON and filters by type qemu or lxc', () {
        final jsonResponse = jsonEncode({
          'data': [
            {
              'type': 'qemu',
              'vmid': 100,
              'name': 'web-vm',
              'status': 'running',
              'node': 'pve1'
            },
            {
              'type': 'lxc',
              'vmid': '101',
              'name': 'db-container',
              'status': 'stopped',
              'node': 'pve2'
            },
            {
              'type': 'storage', // should be filtered out
              'node': 'pve1'
            }
          ]
        });

        final resources = parseProxmoxResources(jsonResponse);

        expect(resources.length, 2);

        expect(resources[0].type, 'qemu');
        expect(resources[0].vmid, '100');
        expect(resources[0].name, 'web-vm');
        expect(resources[0].status, 'running');
        expect(resources[0].node, 'pve1');

        expect(resources[1].type, 'lxc');
        expect(resources[1].vmid, '101');
      });

      test('throws FormatException on invalid JSON syntax', () {
        const invalidJson = 'invalid';
        expect(
          () => parseProxmoxResources(invalidJson),
          throwsA(isA<FormatException>()),
        );
      });

      test('returns empty list if response is not a Map', () {
        const jsonResponse = '"string response"';
        final resources = parseProxmoxResources(jsonResponse);
        expect(resources, isEmpty);
      });

      test('returns empty list if data key is missing or not a List', () {
        const jsonResponseDataNotList = '{"data": {}}';
        expect(parseProxmoxResources(jsonResponseDataNotList), isEmpty);
      });

      test('handles missing properties in valid resources gracefully', () {
        final jsonResponse = jsonEncode({
          'data': [
            {
              'type': 'qemu'
            }
          ]
        });

        final resources = parseProxmoxResources(jsonResponse);
        expect(resources.length, 1);
        final res = resources.first;
        expect(res.type, 'qemu');
        expect(res.vmid, '?');
        expect(res.name, '?');
        expect(res.status, 'unknown');
        expect(res.node, '-');
      });
    });
  });
}
