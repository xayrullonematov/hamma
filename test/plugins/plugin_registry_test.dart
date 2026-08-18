import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/core/ssh/ssh_service.dart';
import 'package:hamma/core/storage/api_key_storage.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/plugins/builtin/kubernetes_plugin.dart';
import 'package:hamma/plugins/builtin/proxmox_plugin.dart';
import 'package:hamma/plugins/hamma_plugin.dart';
import 'package:hamma/plugins/plugin_config_store.dart';
import 'package:hamma/plugins/plugin_registry.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class MockPluginConfigStore extends Mock implements PluginConfigStore {}

class MockSshService extends Mock implements SshService {}

class MockHammaPlugin extends Mock implements HammaPlugin {
  @override
  final manifest = const PluginManifest(
    id: 'test_plugin',
    name: 'Test Plugin',
    version: '1.0.0',
    author: 'Test Author',
    description: 'A plugin for testing',
    icon: Icons.extension,
  );

  @override
  final capabilities = const PluginCapabilities(needsSshSession: true);

  @override
  Future<List<String>> resolveDynamicAllowedHosts(
    HammaPluginConfigReader config,
  ) async {
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    FlutterSecureStorage.setMockInitialValues({});
    PluginRegistry.debugReset();
  });

  test('instance is a singleton', () {
    final instance1 = PluginRegistry.instance;
    final instance2 = PluginRegistry.instance;
    expect(identical(instance1, instance2), isTrue);
  });

  test('debugReset clears the singleton', () {
    final instance1 = PluginRegistry.instance;
    PluginRegistry.debugReset();
    final instance2 = PluginRegistry.instance;
    expect(identical(instance1, instance2), isFalse);
  });

  test('registerBuiltins adds Kubernetes and Proxmox plugins exactly once', () {
    final registry = PluginRegistry.instance;
    expect(registry.all, isEmpty);

    registry.registerBuiltins();
    expect(registry.all.length, 2);
    expect(
      registry.all.any((p) => p.manifest.id == KubernetesPlugin.pluginId),
      isTrue,
    );
    expect(
      registry.all.any((p) => p.manifest.id == ProxmoxPlugin.pluginId),
      isTrue,
    );

    // Idempotent
    registry.registerBuiltins();
    expect(registry.all.length, 2);
  });

  test('register adds plugin if id does not exist', () {
    final registry = PluginRegistry.instance;
    final plugin = MockHammaPlugin();
    registry.register(plugin);

    expect(registry.all.length, 1);
    expect(registry.all.first, plugin);

    // Duplicate ignored
    registry.register(plugin);
    expect(registry.all.length, 1);
  });

  test('load restores enabled ids correctly', () async {
    FlutterSecureStorage.setMockInitialValues({
      'plugin_registry_enabled_ids': 'plugin1, plugin2 , plugin3',
    });

    final registry = PluginRegistry.instance;
    await registry.load();

    expect(registry.isEnabled('plugin1'), isTrue);
    expect(registry.isEnabled('plugin2'), isTrue);
    expect(registry.isEnabled('plugin3'), isTrue);
    expect(registry.isEnabled('unknown'), isFalse);
  });

  test('load enables builtins on first launch', () async {
    final registry = PluginRegistry.instance;
    await registry.load();

    expect(registry.isEnabled(KubernetesPlugin.pluginId), isTrue);
    expect(registry.isEnabled(ProxmoxPlugin.pluginId), isTrue);
  });

  test('setEnabled toggles state and notifies listeners', () async {
    final registry = PluginRegistry.instance;
    await registry.load();

    final plugin = MockHammaPlugin();
    registry.register(plugin);

    var notified = false;
    registry.addListener(() => notified = true);

    expect(registry.isEnabled('test_plugin'), isFalse);

    await registry.setEnabled('test_plugin', true);
    expect(registry.isEnabled('test_plugin'), isTrue);
    expect(notified, isTrue);

    notified = false;
    await registry.setEnabled('test_plugin', false);
    expect(registry.isEnabled('test_plugin'), isFalse);
    expect(notified, isTrue);
  });

  test('buildApi returns HammaApi configured for the plugin', () async {
    final registry = PluginRegistry.instance;

    final plugin = MockHammaPlugin();
    final server = const ServerProfile(
      id: 'server1',
      name: 'Test Server',
      host: '1.2.3.4',
      port: 22,
      username: 'root',
      password: 'password',
    );
    final sshService = MockSshService();
    final aiSettings = const AiSettings(provider: AiProvider.local);

    final api = await registry.buildApi(
      plugin: plugin,
      server: server,
      sshService: sshService,
      aiSettings: aiSettings,
    );

    expect(api.pluginId, 'test_plugin');
    expect(api.capabilities.needsSshSession, isTrue);
    expect(api.serverInfo.name, 'Test Server');
  });
}
