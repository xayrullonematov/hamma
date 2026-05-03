import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models/server_profile.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/ssh/connection_status.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../plugins/hamma_api.dart';
import '../../plugins/hamma_plugin.dart';
import '../../plugins/plugin_registry.dart';
import '../docker/docker_manager_screen.dart';
import '../logs/log_viewer_screen.dart';
import '../observability/health_tab.dart';
import '../packages/package_manager_screen.dart';
import '../runbooks/runbooks_screen.dart';
import '../sftp/file_explorer_screen.dart';
import '../services/service_management_screen.dart';
import '../settings/settings_screen.dart';
import '../terminal/terminal_screen.dart';

class ServerDashboardScreen extends StatefulWidget {
  const ServerDashboardScreen({
    super.key,
    required this.server,
    required this.aiProvider,
    required this.apiKey,
    required this.openRouterModel,
    required this.localEndpoint,
    required this.localModel,
    required this.onSaveAiSettings,
    this.onBackupImported,
  });

  final ServerProfile server;
  final AiProvider aiProvider;
  final String apiKey;
  final String? openRouterModel;
  final String localEndpoint;
  final String localModel;
  final Future<void> Function(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
    String? localEndpoint,
    String? localModel,
  )
  onSaveAiSettings;
  final Future<void> Function()? onBackupImported;

  @override
  State<ServerDashboardScreen> createState() => _ServerDashboardScreenState();
}

class _ServerDashboardScreenState extends State<ServerDashboardScreen> {
  late final SshService _sshService;
  final ApiKeyStorage _apiKeyStorage = const ApiKeyStorage();
  late AiProvider _aiProvider;
  late String _apiKey;
  late String? _openRouterModel;
  late String _localEndpoint;
  late String _localModel;

  int _activeTabIndex = 0;

  /// Snapshot of the enabled plugins at last rebuild. Refreshed via
  /// [_onPluginRegistryChanged] when the user toggles a plugin in
  /// Settings → Extensions; the dashboard nav adds / removes tabs to
  /// match without requiring a server reconnect.
  List<HammaPlugin> _enabledPlugins = const [];

  /// Per-plugin cached [HammaApi] futures, keyed by plugin id. We
  /// build the API handle lazily the first time a plugin's tab is
  /// opened so disabled plugins never pay the cost. The cache is
  /// dropped when a plugin is toggled off or when the server changes.
  final Map<String, Future<HammaApi>> _pluginApis = {};

  PluginRegistry get _pluginRegistry => PluginRegistry.instance;

  ServerProfile get _server => widget.server;

  /// Snapshot of the currently-active AI configuration, suitable for
  /// passing into screens that lazily build an [AiCommandService] on
  /// demand (e.g. the Docker logs sheet → Watch with AI).
  ///
  /// We only know the active-provider's API key in this widget (the
  /// other slots aren't loaded into memory), so the resulting map only
  /// includes that one entry.
  AiSettings get _currentAiSettings => AiSettings(
        provider: _aiProvider,
        apiKeys: {_aiProvider: _apiKey},
        openRouterModel: _openRouterModel,
        localEndpoint: _localEndpoint,
        localModel: _localModel,
      );

  @override
  void initState() {
    super.initState();
    _sshService = SshService.forServer(_server.id);
    _aiProvider = widget.aiProvider;
    _apiKey = widget.apiKey;
    _openRouterModel = widget.openRouterModel;
    _localEndpoint = widget.localEndpoint;
    _localModel = widget.localModel;

    _enabledPlugins = _pluginRegistry.enabled;
    _pluginRegistry.addListener(_onPluginRegistryChanged);

    if (_sshService.currentStatus.isDisconnected ||
        _sshService.currentStatus.isFailed) {
      _connect();
    }
  }

  @override
  void dispose() {
    _pluginRegistry.removeListener(_onPluginRegistryChanged);
    super.dispose();
  }

  /// Refresh the dashboard's plugin tab list when the user toggles a
  /// plugin in Settings → Extensions. We drop the cached [HammaApi]
  /// futures for any plugin that just left the enabled set so a
  /// re-enable later builds a fresh handle (capabilities, allow-list,
  /// dynamic hosts can all have changed underneath us).
  void _onPluginRegistryChanged() {
    if (!mounted) return;
    final next = _pluginRegistry.enabled;
    final stillEnabled = next.map((p) => p.manifest.id).toSet();
    _pluginApis.removeWhere((id, _) => !stillEnabled.contains(id));
    setState(() {
      _enabledPlugins = next;
      final maxIndex = _NavItems.items.length + _enabledPlugins.length - 1;
      if (_activeTabIndex > maxIndex) _activeTabIndex = 0;
    });
  }

  /// Lazily build (and cache) the [HammaApi] handle for [plugin]
  /// against the current server session. Cleared by
  /// [_onPluginRegistryChanged] when the plugin is toggled off.
  Future<HammaApi> _apiFor(HammaPlugin plugin) {
    return _pluginApis.putIfAbsent(
      plugin.manifest.id,
      () => _pluginRegistry.buildApi(
        plugin: plugin,
        server: _server,
        sshService: _sshService,
        aiSettings: _currentAiSettings,
      ),
    );
  }

  /// Total nav items shown in the sidebar / bottom bar — built-in
  /// tabs first, plugin tabs appended in registration order.
  int get _totalNavCount => _NavItems.items.length + _enabledPlugins.length;

  /// Return the icon + label pair for nav slot [i], whether it's a
  /// built-in or a plugin entry. Mirrors the `_NavItem` shape so the
  /// existing sidebar / bottom-bar widgets need no changes.
  _NavItem _navItemAt(int i) {
    if (i < _NavItems.items.length) return _NavItems.items[i];
    final plugin = _enabledPlugins[i - _NavItems.items.length];
    return _NavItem(icon: plugin.manifest.icon, label: plugin.manifest.name);
  }

  Future<void> _connect() async {
    if (!_server.isValid) {
      _showMessage('Saved server profile is incomplete');
      return;
    }

    try {
      await _sshService.connect(
        host: _server.host,
        port: _server.port,
        username: _server.username,
        password: _server.password,
        privateKey: _server.privateKey,
        privateKeyPassword: _server.privateKeyPassword,
        onTrustHostKey: _confirmHostKeyTrust,
      );
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<bool> _confirmHostKeyTrust({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text(
                'TRUST SSH HOST KEY',
                style: TextStyle(
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  letterSpacing: 1.5,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('First connection to $host:$port'),
                    const SizedBox(height: 12),
                    Text('Algorithm: $algorithm'),
                    const SizedBox(height: 8),
                    SelectableText(
                      'Fingerprint: $fingerprint',
                      style: const TextStyle(
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Only trust this key if you have verified it with '
                      'your server provider or the server itself.',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('CANCEL'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('TRUST'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _showMessage(String message) {
    if (!mounted || message.trim().isEmpty) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          initialProvider: _aiProvider,
          initialApiKey: _apiKey,
          initialOpenRouterModel: _openRouterModel,
          initialLocalEndpoint: _localEndpoint,
          initialLocalModel: _localModel,
          onSaveAiSettings: (p, k, m, le, lm) async {
            await widget.onSaveAiSettings(p, k, m, le, lm);
            setState(() {
              _aiProvider = p;
              _apiKey = k;
              _openRouterModel = m;
              _localEndpoint = le ?? _localEndpoint;
              _localModel = lm ?? _localModel;
            });
          },
          onBackupImported: widget.onBackupImported,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Wide-screen sidebar (>=700px)
  // ---------------------------------------------------------------------------
  Widget _buildSidebar(ConnectionStatus status) {
    final isConnected = status.isConnected;

    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(
          right: BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: AppColors.textPrimary,
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Back to servers',
                ),
                const SizedBox(height: 12),
                Text(
                  _server.name.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
                const SizedBox(height: 8),
                _StatusPill(status: status),
                if (status.lastSuccessfulConnection != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'LAST ${_formatTime(status.lastSuccessfulConnection)}',
                      style: const TextStyle(
                        color: AppColors.textFaint,
                        fontSize: 9,
                        letterSpacing: 1.2,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 8),
          for (var i = 0; i < _totalNavCount; i++)
            _SidebarItem(
              item: _navItemAt(i),
              isActive: _activeTabIndex == i,
              isEnabled: i == 0 || isConnected,
              onTap: () => setState(() => _activeTabIndex = i),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isConnected && !status.isConnecting)
                  OutlinedButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('RECONNECT'),
                  ),
                if (isConnected || status.isConnecting)
                  OutlinedButton.icon(
                    onPressed: () => _sshService.disconnect(),
                    icon: const Icon(Icons.link_off_rounded, size: 16),
                    label: const Text('DISCONNECT'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(
                        color: AppColors.danger,
                        width: 1,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          _SidebarItem(
            item: const _NavItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
            ),
            isActive: false,
            isEnabled: true,
            onTap: _openSettings,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Mobile shell (<700px) — bottom NavigationBar + AppBar
  // ---------------------------------------------------------------------------
  Widget _buildMobileShell(ConnectionStatus status) {
    final isConnected = status.isConnected;
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _server.name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            _StatusPill(status: status),
          ],
        ),
        actions: [
          if (!isConnected && !status.isConnecting)
            IconButton(
              tooltip: 'Reconnect',
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: _connect,
            ),
          if (isConnected || status.isConnecting)
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(
                Icons.link_off_rounded,
                size: 20,
                color: AppColors.danger,
              ),
              onPressed: () => _sshService.disconnect(),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: _openSettings,
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.border),
        ),
      ),
      body: _buildActiveContent(status),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.panel,
          border: Border(top: BorderSide(color: AppColors.border, width: 1)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            height: 64,
            labelBehavior:
                NavigationDestinationLabelBehavior.onlyShowSelected,
            selectedIndex: _activeTabIndex.clamp(0, _totalNavCount - 1),
            onDestinationSelected: (i) {
              if (i != 0 && !isConnected) return;
              setState(() => _activeTabIndex = i);
            },
            destinations: [
              for (var i = 0; i < _totalNavCount; i++)
                NavigationDestination(
                  icon: Icon(
                    _navItemAt(i).icon,
                    size: 20,
                    color: (i == 0 || isConnected)
                        ? AppColors.textMuted
                        : AppColors.textFaint,
                  ),
                  selectedIcon: Icon(
                    _navItemAt(i).icon,
                    size: 20,
                    color: AppColors.textPrimary,
                  ),
                  label: _navItemAt(i).label,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Active content area (shared)
  // ---------------------------------------------------------------------------
  Widget _buildActiveContent(ConnectionStatus status) {
    if (status.isConnecting && !status.isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              status.state == SshConnectionState.reconnecting
                  ? 'RECONNECTING (${status.reconnectAttempts}/${status.maxReconnectAttempts})'
                  : 'ESTABLISHING SSH CONNECTION',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
                fontSize: 11,
                letterSpacing: 1.4,
              ),
            ),
          ],
        ),
      );
    }

    if (!status.isConnected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: AppColors.danger,
              ),
              const SizedBox(height: 16),
              Text(
                (status.exception?.userMessage ??
                        (status.isFailed
                            ? 'CONNECTION FAILED'
                            : 'DISCONNECTED'))
                    .toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                ),
              ),
              if (status.exception?.suggestedAction != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    status.exception!.suggestedAction!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('RETRY'),
              ),
            ],
          ),
        ),
      );
    }

    switch (_activeTabIndex) {
      case 0:
        return TerminalScreen(
          sshService: _sshService,
          serverName: _server.name,
          serverId: _server.id,
          aiProvider: _aiProvider,
          apiKeyStorage: _apiKeyStorage,
          openRouterModel: _openRouterModel,
          localEndpoint: _localEndpoint,
          localModel: _localModel,
        );
      case 1:
        return FileExplorerScreen(server: _server);
      case 2:
        return DockerManagerScreen(
          sshService: _sshService,
          serverName: _server.name,
          aiSettings: _currentAiSettings,
        );
      case 3:
        return ServiceManagementScreen(
          sshService: _sshService,
          serverName: _server.name,
        );
      case 4:
        return PackageManagerScreen(
          sshService: _sshService,
          serverName: _server.name,
        );
      case 5:
        // Live observability — agentless metric tiles + AI explainer.
        return HealthTab(
          sshService: _sshService,
          serverName: _server.name,
          aiSettings: _currentAiSettings,
        );
      case 6:
        // System / auth / custom file-tail log viewer with the
        // "Watch with AI" entrypoint baked in.
        return LogViewerScreen(
          sshService: _sshService,
          serverName: _server.name,
          aiSettings: _currentAiSettings,
        );
      case 7:
        // Runbooks tab: per-server multi-step AI-assisted workflows.
        return RunbooksScreen(
          sshService: _sshService,
          serverId: _server.id,
          serverName: _server.name,
          aiSettings: _currentAiSettings,
        );
      default:
        // Plugin tabs sit after the built-in slots.
        final pluginIndex = _activeTabIndex - _NavItems.items.length;
        if (pluginIndex >= 0 && pluginIndex < _enabledPlugins.length) {
          final plugin = _enabledPlugins[pluginIndex];
          return _PluginPanelHost(
            plugin: plugin,
            apiFuture: _apiFor(plugin),
          );
        }
        return TerminalScreen(
          sshService: _sshService,
          serverName: _server.name,
          serverId: _server.id,
          aiProvider: _aiProvider,
          apiKeyStorage: _apiKeyStorage,
          openRouterModel: _openRouterModel,
          localEndpoint: _localEndpoint,
          localModel: _localModel,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: _sshService.statusNotifier,
      builder: (context, status, _) {
        if (Breakpoints.isMobile(context)) {
          return _buildMobileShell(status);
        }
        return Scaffold(
          backgroundColor: AppColors.scaffoldBackground,
          body: Row(
            children: [
              _buildSidebar(status),
              Expanded(
                child: Container(
                  color: AppColors.scaffoldBackground,
                  child: _buildActiveContent(status),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NavItem {
  const _NavItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// Hosts a plugin's [Widget] panel inside the dashboard.
///
/// Plugins receive their [HammaApi] handle asynchronously (the
/// registry resolves dynamic allow-list hosts before handing one
/// over) so we surface the wait with a brutalist spinner and any
/// build error with an inline failure card. Either way the rest of
/// the dashboard chrome — sidebar, status, disconnect button —
/// keeps working.
class _PluginPanelHost extends StatefulWidget {
  const _PluginPanelHost({required this.plugin, required this.apiFuture});

  final HammaPlugin plugin;
  final Future<HammaApi> apiFuture;

  @override
  State<_PluginPanelHost> createState() => _PluginPanelHostState();
}

class _PluginPanelHostState extends State<_PluginPanelHost> {
  /// Whether [HammaPlugin.onLoad] has fired for the current API
  /// instance. Tracked so we only call it once per panel mount even
  /// across [FutureBuilder] rebuilds.
  bool _onLoadFired = false;

  @override
  void dispose() {
    if (_onLoadFired) {
      // Best-effort by contract; we deliberately do not await — the
      // dashboard is being torn down and we don't want to block.
      // ignore: discarded_futures
      widget.plugin.onUnload();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HammaApi>(
      future: widget.apiFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'PLUGIN INIT FAILED\n${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          );
        }
        final api = snapshot.data!;
        if (!_onLoadFired) {
          _onLoadFired = true;
          // Fire-and-forget; plugins that need to surface failures
          // should do so inside [buildPanel].
          // ignore: discarded_futures
          widget.plugin.onLoad(api);
        }
        return widget.plugin.buildPanel(context, api);
      },
    );
  }
}

class _NavItems {
  static const items = <_NavItem>[
    _NavItem(icon: Icons.terminal_rounded, label: 'Terminal'),
    _NavItem(icon: Icons.folder_open_rounded, label: 'Files'),
    _NavItem(icon: Icons.directions_boat_rounded, label: 'Docker'),
    _NavItem(icon: Icons.settings_input_component_rounded, label: 'Services'),
    _NavItem(icon: Icons.system_update_alt_rounded, label: 'Packages'),
    _NavItem(icon: Icons.monitor_heart_outlined, label: 'Health'),
    _NavItem(icon: Icons.article_outlined, label: 'Logs'),
    _NavItem(icon: Icons.menu_book_outlined, label: 'Runbooks'),
  ];
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.item,
    required this.isActive,
    required this.onTap,
    this.isEnabled = true,
  });

  final _NavItem item;
  final bool isActive;
  final VoidCallback onTap;
  final bool isEnabled;

  @override
  Widget build(BuildContext context) {
    final color = !isEnabled
        ? AppColors.textFaint
        : (isActive ? AppColors.textPrimary : AppColors.textMuted);

    return InkWell(
      onTap: isEnabled ? onTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? AppColors.surface : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isActive ? AppColors.textPrimary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(item.icon, size: 18, color: color),
            const SizedBox(width: 12),
            Text(
              item.label.toUpperCase(),
              style: TextStyle(
                color: color,
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final state = status.state;
    final color = state == SshConnectionState.connected
        ? AppColors.accent
        : (state == SshConnectionState.failed ||
                  state == SshConnectionState.disconnected
              ? AppColors.danger
              : AppColors.textMuted);
    final label = state == SshConnectionState.connected
        ? 'ONLINE'
        : (status.isConnecting
              ? 'CONNECTING'
              : (state == SshConnectionState.failed ? 'FAILED' : 'OFFLINE'));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 9,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
            ),
          ),
        ],
      ),
    );
  }
}

enum ConnectionTestState { idle, connected, failed }
