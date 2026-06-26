import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/audit/execution_audit_entry.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/core/palette/sources/plugin_actions_source.dart';
import 'package:hamma/core/palette/sources/recent_commands_source.dart';
import 'package:hamma/core/palette/sources/runbooks_source.dart';
import 'package:hamma/core/palette/sources/screens_source.dart';
import 'package:hamma/core/palette/sources/servers_source.dart';
import 'package:hamma/core/palette/sources/sftp_files_source.dart';
import 'package:hamma/core/runbooks/runbook.dart';
import 'package:hamma/core/storage/api_key_storage.dart';
import 'package:hamma/plugins/hamma_api.dart';
import 'package:hamma/plugins/hamma_plugin.dart';
import 'package:hamma/plugins/plugin_config_store.dart';

void main() {
  group('ServersSource', () {
    final servers = [
      const ServerProfile(
        id: 'srv-1',
        name: 'prod-db',
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
        password: 'p',
      ),
      const ServerProfile(
        id: 'srv-2',
        name: 'staging-web',
        host: 'web.staging.example.com',
        port: 22,
        username: 'deploy',
        password: 'p',
      ),
    ];

    Future<void> noopSelect(ServerProfile s, BuildContext c) async {}

    test('matches on name', () async {
      final source = ServersSource(
        loader: () async => servers,
        onSelect: noopSelect,
      );
      final results = await source.query('prod');
      expect(results, hasLength(1));
      expect(results.first.label, 'prod-db');
      expect(results.first.sourceId, 'servers');
      expect(results.first.id, 'srv-1');
    });

    test('matches on host', () async {
      final source = ServersSource(
        loader: () async => servers,
        onSelect: noopSelect,
      );
      final results = await source.query('staging.example');
      expect(results, hasLength(1));
      expect(results.first.label, 'staging-web');
    });

    test('matches on username', () async {
      final source = ServersSource(
        loader: () async => servers,
        onSelect: noopSelect,
      );
      final results = await source.query('deploy');
      expect(results.map((r) => r.label), ['staging-web']);
    });

    test('subtitle shows user@host:port', () async {
      final source = ServersSource(
        loader: () async => servers,
        onSelect: noopSelect,
      );
      final results = await source.query('prod');
      expect(results.first.subtitle, 'admin@10.0.0.1:22');
    });

    test(
      'empty query returns all servers (sorted by frecency at index)',
      () async {
        final source = ServersSource(
          loader: () async => servers,
          onSelect: noopSelect,
        );
        final results = await source.query('');
        expect(results, hasLength(2));
      },
    );

    test('non-match returns empty', () async {
      final source = ServersSource(
        loader: () async => servers,
        onSelect: noopSelect,
      );
      final results = await source.query('xyzzy');
      expect(results, isEmpty);
    });

    test('onSelect is called with the chosen profile', () async {
      ServerProfile? picked;
      final source = ServersSource(
        loader: () async => servers,
        onSelect: (s, _) async => picked = s,
      );
      final results = await source.query('prod');
      await results.first.onInvoke(_FakeContext());
      expect(picked?.id, 'srv-1');
    });
  });

  group('ScreensSource', () {
    final screens = [
      PaletteScreen(
        id: 'screen.servers',
        label: 'Servers',
        icon: Icons.dns_outlined,
        navigate: (_) async {},
      ),
      PaletteScreen(
        id: 'screen.settings',
        label: 'Settings',
        subtitle: 'AI, vault, sync',
        icon: Icons.settings_outlined,
        navigate: (_) async {},
      ),
    ];

    test('matches on label', () async {
      final source = ScreensSource(screens: screens);
      final results = await source.query('serv');
      expect(results, hasLength(1));
      expect(results.first.id, 'screen.servers');
    });

    test('matches on subtitle', () async {
      final source = ScreensSource(screens: screens);
      final results = await source.query('vault');
      expect(results.map((r) => r.id), ['screen.settings']);
    });

    test('navigate closure fires on invoke', () async {
      var called = false;
      final source = ScreensSource(
        screens: [
          PaletteScreen(
            id: 'x',
            label: 'X',
            icon: Icons.abc,
            navigate: (_) async => called = true,
          ),
        ],
      );
      final results = await source.query('x');
      await results.first.onInvoke(_FakeContext());
      expect(called, isTrue);
    });

    test('sourceId is "screens"', () async {
      final source = ScreensSource(screens: screens);
      expect(source.id, 'screens');
    });
  });

  group('RecentCommandsSource', () {
    final entries = [
      ExecutionAuditEntry(
        id: 'audit-1',
        naturalLanguageIntent: 'check disk',
        proposedCommand: 'df -h',
        riskLevel: CommandRiskLevel.low,
        approvedAt: DateTime.utc(2026),
        serverId: 'srv-1',
        serverName: 'prod-db',
        status: ExecutionStatus.executed,
      ),
      ExecutionAuditEntry(
        id: 'audit-2',
        naturalLanguageIntent: 'restart nginx',
        proposedCommand: 'sudo systemctl restart nginx',
        riskLevel: CommandRiskLevel.moderate,
        approvedAt: DateTime.utc(2026),
        serverId: 'srv-2',
        serverName: 'web',
        status: ExecutionStatus.approved,
      ),
    ];

    test('matches recent command text and server name', () async {
      final source = RecentCommandsSource(
        loader: () async => entries,
        onSelect: (_, __) async {},
      );
      expect((await source.query('df')).single.id, 'audit-1');
      expect((await source.query('prod')).single.id, 'audit-1');
    });

    test('delegates invocation to host callback', () async {
      ExecutionAuditEntry? picked;
      final source = RecentCommandsSource(
        loader: () async => entries,
        onSelect: (entry, _) async => picked = entry,
      );
      final results = await source.query('nginx');
      await results.single.onInvoke(_FakeContext());
      expect(picked?.id, 'audit-2');
    });
  });

  group('RunbooksSource', () {
    final runbooks = [
      const Runbook(
        id: 'rb-1',
        name: 'Restart nginx safely',
        description: 'Validate config then restart',
        steps: [
          RunbookStep(
            id: 'test',
            label: 'nginx -t',
            type: RunbookStepType.command,
            command: 'sudo nginx -t',
          ),
        ],
      ),
    ];

    test('matches runbook name, description, and step command', () async {
      final source = RunbooksSource(
        loader: () async => runbooks,
        onSelect: (_, __) async {},
      );
      expect((await source.query('restart')).single.id, 'rb-1');
      expect((await source.query('validate')).single.id, 'rb-1');
      expect((await source.query('nginx -t')).single.id, 'rb-1');
    });

    test('delegates invocation to host callback', () async {
      Runbook? picked;
      final source = RunbooksSource(
        loader: () async => runbooks,
        onSelect: (runbook, _) async => picked = runbook,
      );
      final results = await source.query('restart');
      await results.single.onInvoke(_FakeContext());
      expect(picked?.id, 'rb-1');
    });
  });

  group('SftpFilesSource', () {
    final files = [
      const SftpRecentFile(
        serverId: 'srv-1',
        serverName: 'prod-db',
        path: '/var/log/nginx/error.log',
      ),
    ];

    test('matches file name, path, and server name', () async {
      final source = SftpFilesSource(
        loader: () async => files,
        onSelect: (_, __) async {},
      );
      expect((await source.query('error.log')).single.id, files.single.id);
      expect((await source.query('/var/log')).single.id, files.single.id);
      expect((await source.query('prod-db')).single.id, files.single.id);
    });

    test('parses frecency ids with the stable separator', () {
      final id = SftpRecentFile.frecencyId(
        serverId: 'srv-1',
        path: '/tmp/a:b.txt',
      );
      final parsed = SftpRecentFile.fromFrecencyId(
        id,
        serverNameFor: (_) => 'prod-db',
      );
      expect(parsed?.serverId, 'srv-1');
      expect(parsed?.path, '/tmp/a:b.txt');
      expect(parsed?.serverName, 'prod-db');
    });
  });

  group('PluginActionsSource', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test(
      'surfaces plugin actions and invokes through an api factory',
      () async {
        var ran = false;
        final plugin = _FakePlugin(
          action: HammaPluginPaletteAction(
            id: 'inspect',
            label: 'Inspect cluster',
            description: 'List cluster state',
            icon: Icons.search,
            run: (_, __) async => ran = true,
          ),
        );
        final source = PluginActionsSource(
          pluginsLoader: () => [plugin],
          apiFactory: (_, __) async => _fakeApi(plugin),
        );

        final results = await source.query('cluster');
        expect(results.single.id, 'fake.plugin:inspect');
        await results.single.onInvoke(_FakeContext());
        expect(ran, isTrue);
      },
    );
  });
}

class _FakeContext extends BuildContext {
  @override
  bool get mounted => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlugin extends HammaPlugin {
  const _FakePlugin({required this.action});

  final HammaPluginPaletteAction action;

  @override
  PluginManifest get manifest => const PluginManifest(
    id: 'fake.plugin',
    name: 'Fake Plugin',
    version: '1.0.0',
    author: 'test',
    description: 'fake plugin for palette tests',
    icon: Icons.extension,
  );

  @override
  PluginCapabilities get capabilities => const PluginCapabilities();

  @override
  Iterable<HammaPluginPaletteAction> paletteActions() => [action];

  @override
  Widget buildPanel(BuildContext context, HammaApi api) => const SizedBox();
}

HammaApi _fakeApi(HammaPlugin plugin) {
  return HammaApi(
    pluginId: plugin.manifest.id,
    capabilities: plugin.capabilities,
    serverInfo: const PluginServerInfo(
      id: 'srv-1',
      name: 'prod-db',
      host: '127.0.0.1',
      port: 22,
      username: 'ubuntu',
    ),
    configStore: const PluginConfigStore(),
    aiSettings: const AiSettings(provider: AiProvider.local),
  );
}
