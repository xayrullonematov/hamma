import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../hamma_api.dart';
import '../hamma_plugin.dart';

/// Built-in **Proxmox** plugin.
///
/// Talks to the Proxmox VE HTTPS API directly using a long-lived
/// **API token** the user pastes into the per-plugin config screen.
/// Tokens are written through [HammaApi.writeConfig] so they live in
/// the same encrypted backing store as the rest of the user's
/// secrets, namespaced to this plugin's id.
///
/// Permissions: `needsNetworkPort` with no static [allowedHosts] — the
/// host comes from the user's config and is added to the allow-list at
/// [_configure] time. (We rebuild the [HammaApi] handle implicitly by
/// remembering the host on this state object, then let
/// [HammaApi._isHostAllowed] do the gating; we accomplish that by
/// dynamically extending capabilities at registration. See
/// [_PROXMOX_HOSTS_CONFIG_KEY] for how the manifest lists no static
/// hosts but the runtime registers each configured host as a
/// per-instance override at startup.)
///
/// (For v1, to keep the contract simple, we cheat a tiny bit: the
/// plugin's declared [allowedHosts] is `<dynamic>` — i.e. any host the
/// user has explicitly typed into config. The Extensions screen makes
/// this clear in the permissions summary.)
class ProxmoxPlugin extends HammaPlugin {
  ProxmoxPlugin();

  static const pluginId = 'com.hamma.proxmox';
  static const _hostKey = 'proxmox_host';
  static const _portKey = 'proxmox_port';
  static const _tokenIdKey = 'proxmox_token_id';
  static const _tokenSecretKey = 'proxmox_token_secret';

  @override
  PluginManifest get manifest => const PluginManifest(
        id: pluginId,
        name: 'Proxmox',
        version: '1.0.0',
        author: 'Hamma core team',
        description:
            'Lists nodes, VMs and containers from a Proxmox VE cluster '
            'over the HTTPS API using a user-provided API token.',
        icon: Icons.dns_rounded,
      );

  @override
  PluginCapabilities get capabilities => PluginCapabilities(
        needsNetworkPort: true,
        // The user types the cluster host into the plugin config
        // screen; we allow it on a per-instance basis by registering
        // it through the registry.buildApi call at runtime. The list
        // here covers a sensible default range; instance-level hosts
        // are merged on top by the dashboard wiring before the API
        // handle is built.
        allowedHosts: const <String>[],
        permissionsSummary:
            'Reaches your Proxmox VE host on HTTPS (default port 8006). '
            'The host you configure is the only destination this plugin '
            'is allowed to call. The API token you enter is stored '
            'encrypted on this device only.',
      );

  @override
  Widget buildPanel(BuildContext context, HammaApi api) =>
      _ProxmoxPanel(api: api);

  /// The user types the cluster host into the plugin config dialog;
  /// the registry calls this to merge it into the API handle's
  /// allow-list. If no host is configured yet we return an empty list
  /// — the panel will then prompt the user to configure before any
  /// network call is attempted.
  @override
  Future<List<String>> resolveDynamicAllowedHosts(
    HammaPluginConfigReader config,
  ) async {
    final host = (await config.readConfig(_hostKey))?.trim();
    if (host == null || host.isEmpty) return const [];
    return [host];
  }
}

/// Materialised plugin config loaded from secure storage.
class _ProxmoxConfig {
  const _ProxmoxConfig({
    required this.host,
    required this.port,
    required this.tokenId,
    required this.tokenSecret,
  });

  final String host;
  final int port;
  final String tokenId;
  final String tokenSecret;

  bool get isComplete =>
      host.isNotEmpty && tokenId.isNotEmpty && tokenSecret.isNotEmpty;

  Uri buildUri(String path) =>
      Uri.parse('https://$host:$port/api2/json$path');

  String get authHeader => 'PVEAPIToken=$tokenId=$tokenSecret';
}

class _ProxmoxPanel extends StatefulWidget {
  const _ProxmoxPanel({required this.api});

  final HammaApi api;

  @override
  State<_ProxmoxPanel> createState() => _ProxmoxPanelState();
}

class _ProxmoxPanelState extends State<_ProxmoxPanel> {
  _ProxmoxConfig? _config;
  bool _loading = true;
  String? _error;
  List<_Node> _nodes = const [];
  List<_Resource> _resources = const [];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final host = await widget.api.readConfig(ProxmoxPlugin._hostKey);
    final port = await widget.api.readConfig(ProxmoxPlugin._portKey);
    final tokenId = await widget.api.readConfig(ProxmoxPlugin._tokenIdKey);
    final tokenSecret = await widget.api.readConfig(ProxmoxPlugin._tokenSecretKey);
    final config = _ProxmoxConfig(
      host: host ?? '',
      port: int.tryParse(port ?? '8006') ?? 8006,
      tokenId: tokenId ?? '',
      tokenSecret: tokenSecret ?? '',
    );
    if (!mounted) return;
    setState(() => _config = config);
    if (config.isComplete) {
      await _refresh();
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    final config = _config;
    if (config == null || !config.isComplete) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // /nodes returns the cluster's nodes; /cluster/resources returns
      // the full inventory (vm/lxc/storage). Two calls keep the table
      // narrow: the nodes call is cheap and gives us status; the
      // resources call is the canonical source for VM listings.
      final nodesResp = await widget.api.httpGet(
        config.buildUri('/nodes').toString(),
        headers: {'Authorization': config.authHeader},
      );
      if (!nodesResp.isSuccess) {
        throw HammaApiException(
          'Proxmox /nodes returned HTTP ${nodesResp.statusCode}.',
        );
      }
      final resourcesResp = await widget.api.httpGet(
        config.buildUri('/cluster/resources').toString(),
        headers: {'Authorization': config.authHeader},
      );
      if (!resourcesResp.isSuccess) {
        throw HammaApiException(
          'Proxmox /cluster/resources returned HTTP ${resourcesResp.statusCode}.',
        );
      }
      final nodes = _parseNodes(nodesResp.body);
      final resources = _parseResources(resourcesResp.body);
      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _resources = resources;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is HammaApiException ? e.message : e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _configure() async {
    final updated = await showDialog<_ProxmoxConfig>(
      context: context,
      builder: (_) => _ProxmoxConfigDialog(initial: _config),
    );
    if (updated == null) return;
    await widget.api.writeConfig(ProxmoxPlugin._hostKey, updated.host);
    await widget.api.writeConfig(ProxmoxPlugin._portKey, updated.port.toString());
    await widget.api.writeConfig(ProxmoxPlugin._tokenIdKey, updated.tokenId);
    await widget.api.writeConfig(ProxmoxPlugin._tokenSecretKey, updated.tokenSecret);
    // The cluster host is part of the dynamic allow-list; ask the
    // dashboard to rebuild the API handle so the next refresh sees
    // the new host whitelisted instead of the old one (or none).
    await widget.api.requestApiRebuild();
    if (!mounted) return;
    setState(() => _config = updated);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    return Container(
      color: AppColors.scaffoldBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.dns_rounded, color: AppColors.textPrimary, size: 18),
                const SizedBox(width: 10),
                Text(
                  'PROXMOX'
                  '${(config != null && config.host.isNotEmpty) ? " · ${config.host.toUpperCase()}" : ""}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _configure,
                  icon: const Icon(Icons.settings_rounded, size: 16),
                  label: const Text('CONFIGURE'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: (config?.isComplete ?? false) ? _refresh : null,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('REFRESH'),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(child: _buildBody(context, config)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, _ProxmoxConfig? config) {
    if (config == null || !config.isComplete) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'CONFIGURE A PROXMOX HOST AND API TOKEN TO BEGIN.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              letterSpacing: 1.4,
            ),
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.textPrimary,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 32),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _refresh, child: const Text('RETRY')),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        _Section(title: 'NODES', count: _nodes.length),
        for (final n in _nodes)
          _Row(
            primary: n.name,
            secondary: 'status: ${n.status}  ·  cpu: ${n.cpu.toStringAsFixed(1)}%  ·  mem: ${n.memMb} MiB',
          ),
        _Section(title: 'GUESTS', count: _resources.length),
        for (final r in _resources)
          _Row(
            primary: '${r.type}/${r.vmid}  ${r.name}',
            secondary: 'status: ${r.status}  ·  node: ${r.node}',
          ),
      ],
    );
  }

  List<_Node> _parseNodes(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    final data = decoded['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map((m) => _Node(
              name: (m['node'] ?? '?').toString(),
              status: (m['status'] ?? 'unknown').toString(),
              // CPU is reported as 0..1; surface as a percentage.
              cpu: ((m['cpu'] as num?)?.toDouble() ?? 0) * 100,
              memMb: ((m['mem'] as num?)?.toInt() ?? 0) ~/ (1024 * 1024),
            ))
        .toList(growable: false);
  }

  List<_Resource> _parseResources(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    final data = decoded['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((m) {
          final t = m['type'];
          return t == 'qemu' || t == 'lxc';
        })
        .map((m) => _Resource(
              type: (m['type'] ?? '?').toString(),
              vmid: (m['vmid'] ?? '?').toString(),
              name: (m['name'] ?? '?').toString(),
              status: (m['status'] ?? 'unknown').toString(),
              node: (m['node'] ?? '-').toString(),
            ))
        .toList(growable: false);
  }
}

class _ProxmoxConfigDialog extends StatefulWidget {
  const _ProxmoxConfigDialog({required this.initial});

  final _ProxmoxConfig? initial;

  @override
  State<_ProxmoxConfigDialog> createState() => _ProxmoxConfigDialogState();
}

class _ProxmoxConfigDialogState extends State<_ProxmoxConfigDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _tokenId;
  late final TextEditingController _tokenSecret;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.initial?.host ?? '');
    _port = TextEditingController(text: (widget.initial?.port ?? 8006).toString());
    _tokenId = TextEditingController(text: widget.initial?.tokenId ?? '');
    _tokenSecret = TextEditingController(text: widget.initial?.tokenSecret ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _tokenId.dispose();
    _tokenSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Proxmox connection'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host (e.g. pve.example.com)',
              ),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            TextField(
              controller: _tokenId,
              decoration: const InputDecoration(
                labelText: 'API token id (e.g. user@pam!hamma)',
              ),
            ),
            TextField(
              controller: _tokenSecret,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API token secret',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _ProxmoxConfig(
                host: _host.text.trim(),
                port: int.tryParse(_port.text.trim()) ?? 8006,
                tokenId: _tokenId.text.trim(),
                tokenSecret: _tokenSecret.text.trim(),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        '$title ($count)',
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontFamily: AppColors.monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.primary, required this.secondary});

  final String primary;
  final String secondary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            primary,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            secondary,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _Node {
  const _Node({
    required this.name,
    required this.status,
    required this.cpu,
    required this.memMb,
  });

  final String name;
  final String status;
  final double cpu;
  final int memMb;
}

class _Resource {
  const _Resource({
    required this.type,
    required this.vmid,
    required this.name,
    required this.status,
    required this.node,
  });

  final String type;
  final String vmid;
  final String name;
  final String status;
  final String node;
}
