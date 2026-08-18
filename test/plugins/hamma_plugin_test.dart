import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/plugins/hamma_api.dart';
import 'package:hamma/plugins/hamma_plugin.dart';

class _TestPlugin extends HammaPlugin {
  @override
  PluginManifest get manifest => const PluginManifest(
    id: 'test_plugin',
    name: 'Test Plugin',
    version: '1.0.0',
    author: 'Test Author',
    description: 'A test plugin.',
    icon: Icons.extension,
  );

  @override
  PluginCapabilities get capabilities => const PluginCapabilities();

  @override
  Widget buildPanel(BuildContext context, HammaApi api) {
    return const SizedBox();
  }
}

class _TestConfigReader implements HammaPluginConfigReader {
  @override
  Future<String?> readConfig(String key) async {
    return null;
  }
}

void main() {
  group('HammaPlugin', () {
    test(
      'resolveDynamicAllowedHosts returns an empty list by default',
      () async {
        final plugin = _TestPlugin();
        final configReader = _TestConfigReader();

        final result = await plugin.resolveDynamicAllowedHosts(configReader);

        expect(result, isEmpty);
      },
    );
  });
}
