import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models/server_profile.dart';
import '../../core/ssh/connection_status.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../docker/docker_manager_screen.dart';
import '../packages/package_manager_screen.dart';
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
    required this.onSaveAiSettings,
    this.onBackupImported,
  });

  final ServerProfile server;
  final AiProvider aiProvider;
  final String apiKey;
  final String? openRouterModel;
  final Future<void> Function(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
  )
  onSaveAiSettings;
  final Future<void> Function()? onBackupImported;

  @override
  State<ServerDashboardScreen> createState() => _ServerDashboardScreenState();
}

class _ServerDashboardScreenState extends State<ServerDashboardScreen> {
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _successColor = Color(0xFF22C55E);
  static const _dangerColor = Color(0xFFEF4444);
  static const _warningColor = Color(0xFFF59E0B);

  late final SshService _sshService;
  final ApiKeyStorage _apiKeyStorage = const ApiKeyStorage();
  late AiProvider _aiProvider;
  late String _apiKey;
  late String? _openRouterModel;

  int _activeTabIndex = 0;

  ServerProfile get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _sshService = SshService.forServer(_server.id);
    _aiProvider = widget.aiProvider;
    _apiKey = widget.apiKey;
    _openRouterModel = widget.openRouterModel;
    
    // Only auto-connect if not already connected/connecting
    if (_sshService.currentStatus.isDisconnected || _sshService.currentStatus.isFailed) {
      _connect();
    }
  }

  @override
  void dispose() {
    // We don't disconnect here because we want the connection to persist
    // when the user goes back to the server list.
    super.dispose();
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
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Trust SSH Host Key'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('First connection to $host:$port'),
                  const SizedBox(height: 12),
                  Text('Algorithm: $algorithm'),
                  const SizedBox(height: 8),
                  SelectableText('Fingerprint: $fingerprint'),
                  const SizedBox(height: 12),
                  const Text(
                    'Only trust this key if you have verified it with your server provider or the server itself.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Trust'),
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

  Widget _buildSidebar(ConnectionStatus status) {
    final isConnected = status.isConnected;
    
    return Container(
      width: 260,
      color: _panelColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Back to servers',
                ),
                const SizedBox(height: 16),
                Text(
                  _server.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusIndicator(status: status),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        status.state == SshConnectionState.connected 
                            ? 'Connected' 
                            : (status.isConnecting ? 'Connecting...' : 'Disconnected'),
                        style: TextStyle(
                          color: _getStatusColor(status),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (status.lastSuccessfulConnection != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 16),
                    child: Text(
                      'Last: ${_formatTime(status.lastSuccessfulConnection)}',
                      style: const TextStyle(color: _mutedColor, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          const SizedBox(height: 16),
          _SidebarItem(
            icon: Icons.terminal_rounded,
            label: 'Terminal',
            isActive: _activeTabIndex == 0,
            onTap: () => setState(() => _activeTabIndex = 0),
          ),
          _SidebarItem(
            icon: Icons.folder_open_rounded,
            label: 'SFTP Explorer',
            isActive: _activeTabIndex == 1,
            isEnabled: isConnected,
            onTap: () => setState(() => _activeTabIndex = 1),
          ),
          _SidebarItem(
            icon: Icons.directions_boat_rounded,
            label: 'Docker',
            isActive: _activeTabIndex == 2,
            isEnabled: isConnected,
            onTap: () => setState(() => _activeTabIndex = 2),
          ),
          _SidebarItem(
            icon: Icons.settings_input_component_rounded,
            label: 'Services',
            isActive: _activeTabIndex == 3,
            isEnabled: isConnected,
            onTap: () => setState(() => _activeTabIndex = 3),
          ),
          _SidebarItem(
            icon: Icons.system_update_alt_rounded,
            label: 'Packages',
            isActive: _activeTabIndex == 4,
            isEnabled: isConnected,
            onTap: () => setState(() => _activeTabIndex = 4),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isConnected && !status.isConnecting)
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Reconnect'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _primaryColor.withValues(alpha: 0.1),
                      foregroundColor: _primaryColor,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                if (isConnected || status.isConnecting)
                  OutlinedButton.icon(
                    onPressed: () => _sshService.disconnect(),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Disconnect'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _dangerColor,
                      side: BorderSide(color: _dangerColor.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          _SidebarItem(
            icon: Icons.settings_outlined,
            label: 'Settings',
            isActive: false,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder:
                      (_) => SettingsScreen(
                        initialProvider: _aiProvider,
                        initialApiKey: _apiKey,
                        initialOpenRouterModel: _openRouterModel,
                        onSaveAiSettings: (p, k, m) async {
                          await widget.onSaveAiSettings(p, k, m);
                          setState(() {
                            _aiProvider = p;
                            _apiKey = k;
                            _openRouterModel = m;
                          });
                        },
                        onBackupImported: widget.onBackupImported,
                      ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Color _getStatusColor(ConnectionStatus status) {
    switch (status.state) {
      case SshConnectionState.connected:
        return _successColor;
      case SshConnectionState.connecting:
      case SshConnectionState.reconnecting:
        return _warningColor;
      case SshConnectionState.failed:
      case SshConnectionState.disconnected:
        return _dangerColor;
    }
  }

  static const _primaryColor = Color(0xFF3B82F6);

  Widget _buildActiveContent(ConnectionStatus status) {
    if (status.isConnecting && !status.isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              status.state == SshConnectionState.reconnecting 
                  ? 'Reconnecting (Attempt ${status.reconnectAttempts}/${status.maxReconnectAttempts})...'
                  : 'Establishing SSH Connection...',
              style: const TextStyle(color: _mutedColor),
            ),
          ],
        ),
      );
    }

    if (!status.isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48, color: _dangerColor),
            const SizedBox(height: 16),
            Text(
              status.exception?.userMessage ?? (status.isFailed ? 'Connection Failed' : 'Disconnected'),
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            if (status.exception?.suggestedAction != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                child: Text(
                  status.exception!.suggestedAction!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _mutedColor, fontSize: 13),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry Connection'),
            ),
          ],
        ),
      );
    }

    switch (_activeTabIndex) {
      case 0:
        return TerminalScreen(
          sshService: _sshService,
          serverName: _server.name,
          aiProvider: _aiProvider,
          apiKeyStorage: _apiKeyStorage,
          openRouterModel: _openRouterModel,
        );
      case 1:
        return FileExplorerScreen(server: _server);
      case 2:
        return DockerManagerScreen(
          sshService: _sshService,
          serverName: _server.name,
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
      default:
        return const Center(child: Text('Coming Soon'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: _sshService.statusNotifier,
      builder: (context, status, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF0F172A),
          body: Row(
            children: [
              _buildSidebar(status),
              Expanded(
                child: Container(
                  color: const Color(0xFF0B1120),
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

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.isEnabled = true,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final bool isEnabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Opacity(
        opacity: isEnabled ? 1.0 : 0.4,
        child: Material(
          color: isActive ? Colors.white.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: isEnabled ? onTap : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: isActive ? Colors.white : const Color(0xFF94A3B8),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    label,
                    style: TextStyle(
                      color: isActive ? Colors.white : const Color(0xFF94A3B8),
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({required this.status});
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    if (status.isConnecting && !status.isConnected) {
      return const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFF59E0B)),
      );
    }
    
    Color color;
    switch (status.state) {
      case SshConnectionState.connected:
        color = const Color(0xFF22C55E);
        break;
      case SshConnectionState.failed:
      case SshConnectionState.disconnected:
        color = const Color(0xFFEF4444);
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

enum ConnectionTestState { idle, connected, failed }
