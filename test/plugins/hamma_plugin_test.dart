import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/plugins/hamma_plugin.dart';

void main() {
  group('PluginCapabilities', () {
    test('default constructor assigns default values', () {
      const capabilities = PluginCapabilities();

      expect(capabilities.needsSshSession, isFalse);
      expect(capabilities.needsLocalAi, isFalse);
      expect(capabilities.needsNetworkPort, isFalse);
      expect(capabilities.allowedHosts, isEmpty);
      expect(capabilities.permissionsSummary, isEmpty);
    });

    test('custom values are assigned correctly', () {
      const capabilities = PluginCapabilities(
        needsSshSession: true,
        needsLocalAi: true,
        needsNetworkPort: true,
        allowedHosts: ['example.com', 'api.example.com'],
        permissionsSummary: 'Requires access to SSH, Local AI, and network requests.',
      );

      expect(capabilities.needsSshSession, isTrue);
      expect(capabilities.needsLocalAi, isTrue);
      expect(capabilities.needsNetworkPort, isTrue);
      expect(capabilities.allowedHosts, equals(['example.com', 'api.example.com']));
      expect(capabilities.permissionsSummary, equals('Requires access to SSH, Local AI, and network requests.'));
    });
  });
}
