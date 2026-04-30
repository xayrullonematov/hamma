import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models/server_profile.dart';
import '../../core/ssh/connection_status.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/saved_servers_storage.dart';
import '../fleet/fleet_dashboard_screen.dart';
import '../settings/settings_screen.dart';
import 'server_dashboard_screen.dart';
import 'server_form_screen.dart';
import '../../core/theme/app_colors.dart';

class ServerListScreen extends StatefulWidget {
  const ServerListScreen({
    super.key,
    required this.aiProvider,
    required this.apiKey,
    required this.openRouterModel,
    required this.onSaveAiSettings,
    this.startupWarning,
  });

  final AiProvider aiProvider;
  final String apiKey;
  final String? openRouterModel;
  final Future<void> Function(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
  )
  onSaveAiSettings;
  final String? startupWarning;

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
  static const _cardColor = AppColors.surface;
  static const _cardAccent = AppColors.textPrimary;
  static const _subtitleColor = AppColors.textMuted;
  static const _shadowColor = Color(0x33000000);

  final SavedServersStorage _savedServersStorage = const SavedServersStorage();

  bool _isLoading = true;
  String? _loadError;
  List<ServerProfile> _servers = const [];

  bool _isSearching = false;
  String _searchQuery = '';
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _loadServers();
    if (widget.startupWarning != null && widget.startupWarning!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.startupWarning!)));
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ServerProfile> get _filteredServers {
    if (_searchQuery.isEmpty) {
      return _servers;
    }
    final query = _searchQuery.toLowerCase();
    return _servers.where((server) {
      return server.name.toLowerCase().contains(query) ||
          server.host.toLowerCase().contains(query) ||
          server.username.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _loadServers() async {
    try {
      final servers = await _savedServersStorage.loadServers();
      if (!mounted) {
        return;
      }

      setState(() {
        _servers = servers;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveServers(List<ServerProfile> servers) async {
    try {
      await _savedServersStorage.saveServers(servers);
      if (!mounted) {
        return;
      }

      setState(() {
        _servers = servers;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _addServer() async {
    final server = await Navigator.of(context).push<ServerProfile>(
      MaterialPageRoute<ServerProfile>(
        builder: (_) => const ServerFormScreen(),
      ),
    );

    if (server == null) {
      return;
    }

    final updatedServers = [..._servers, server];
    await _saveServers(updatedServers);
  }

  Future<void> _editServer(ServerProfile server) async {
    final updatedServer = await Navigator.of(context).push<ServerProfile>(
      MaterialPageRoute<ServerProfile>(
        builder: (_) => ServerFormScreen(initialServer: server),
      ),
    );

    if (updatedServer == null) {
      return;
    }

    final updatedServers =
        _servers
            .map((item) => item.id == updatedServer.id ? updatedServer : item)
            .toList();
    await _saveServers(updatedServers);
  }

  Future<void> _deleteServer(ServerProfile server) async {
    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Delete Server'),
              content: Text('Remove "${server.name}" from saved hosts?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldDelete) {
      return;
    }

    final updatedServers =
        _servers.where((item) => item.id != server.id).toList();
    await _saveServers(updatedServers);
  }

  Future<void> _clearSavedHosts() async {
    final shouldClear =
        await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Clear Saved Hosts'),
              content: const Text(
                'This will remove all saved hosts from this device. Use this only if the saved host data is corrupted.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Clear'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldClear) {
      return;
    }

    try {
      await _savedServersStorage.clearServers();
      if (!mounted) {
        return;
      }

      setState(() {
        _servers = const [];
        _loadError = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _openServer(ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => ServerDashboardScreen(
              server: server,
              aiProvider: widget.aiProvider,
              apiKey: widget.apiKey,
              openRouterModel: widget.openRouterModel,
              onSaveAiSettings: widget.onSaveAiSettings,
              onBackupImported: _loadServers,
            ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => SettingsScreen(
              initialProvider: widget.aiProvider,
              initialApiKey: widget.apiKey,
              initialOpenRouterModel: widget.openRouterModel,
              onSaveAiSettings: widget.onSaveAiSettings,
              onBackupImported: _loadServers,
            ),
      ),
    );
  }

  void _openFleetCommandCenter() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const FleetDashboardScreen()),
    );
  }

  void _startSearch() {
    ModalRoute.of(context)?.addLocalHistoryEntry(
      LocalHistoryEntry(
        onRemove: () {
          setState(() {
            _isSearching = false;
            _searchQuery = '';
            _searchController.clear();
          });
        },
      ),
    );
    setState(() {
      _isSearching = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredServers = _filteredServers;

    return Scaffold(
      appBar: AppBar(
        title:
            _isSearching
                ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search servers...',
                    border: InputBorder.none,
                    hintStyle: TextStyle(color: _subtitleColor),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                )
                : const Text('Saved Servers'),
        actions: [
          if (_isSearching)
            IconButton(
              onPressed: () {
                if (_searchController.text.isEmpty) {
                  Navigator.of(context).pop();
                } else {
                  _searchController.clear();
                  setState(() {
                    _searchQuery = '';
                  });
                }
              },
              icon: const Icon(Icons.clear),
            )
          else ...[
            IconButton(
              onPressed: _startSearch,
              icon: const Icon(Icons.search),
              tooltip: 'Search',
            ),
            IconButton(
              onPressed: _openFleetCommandCenter,
              icon: const Icon(Icons.dashboard_customize_outlined),
              tooltip: 'Fleet Command Center',
            ),
            IconButton(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
            ),
          ],
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
              ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _isLoading = true;
                            _loadError = null;
                          });
                          _loadServers();
                        },
                        child: const Text('Retry'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _clearSavedHosts,
                        child: const Text('Clear Saved Hosts'),
                      ),
                    ],
                  ),
                ),
              )
              : _servers.isEmpty
              ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No saved servers yet. Add one to start managing your server.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
              : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _isSearching
                                          ? 'Search Results'
                                          : 'Server Dashboard',
                                      style: theme.textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _isSearching
                                          ? 'Showing results for "$_searchQuery"'
                                          : 'Direct SSH access to your saved infrastructure.',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.panel,
                                  borderRadius: BorderRadius.zero,
                                ),
                                child: Text(
                                  '${filteredServers.length} ${_isSearching ? 'found' : 'saved'}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (filteredServers.isEmpty && _isSearching)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              'No servers match your search.',
                              style: TextStyle(color: _subtitleColor),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 450,
                              mainAxisExtent: 180,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final server = filteredServers[index];
                                final sshService = SshService.forServer(server.id);
                                
                                return ValueListenableBuilder<ConnectionStatus>(
                                  valueListenable: sshService.statusNotifier,
                                  builder: (context, status, _) {
                                    return _ServerDashboardCard(
                                      server: server,
                                      status: status,
                                      onOpen: () => _openServer(server),
                                      onEdit: () => _editServer(server),
                                      onDelete: () => _deleteServer(server),
                                    );
                                  },
                                );
                              },
                              childCount: filteredServers.length,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addServer,
        icon: const Icon(Icons.add),
        label: const Text('Add Server'),
      ),
    );
  }
}

class _ServerDashboardCard extends StatelessWidget {
  const _ServerDashboardCard({
    required this.server,
    required this.status,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerProfile server;
  final ConnectionStatus status;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  Color _getStatusColor() {
    switch (status.state) {
      case SshConnectionState.connected:
        return AppColors.accent;
      case SshConnectionState.connecting:
      case SshConnectionState.reconnecting:
        return AppColors.textMuted;
      case SshConnectionState.failed:
        return AppColors.danger;
      case SshConnectionState.disconnected:
        return AppColors.textMuted;
    }
  }

  String _getStatusLabel() {
    switch (status.state) {
      case SshConnectionState.connected:
        return 'Connected';
      case SshConnectionState.connecting:
        return 'Connecting...';
      case SshConnectionState.reconnecting:
        return 'Reconnecting (${status.reconnectAttempts}/${status.maxReconnectAttempts})...';
      case SshConnectionState.failed:
        return status.exception?.userMessage ?? 'Failed';
      case SshConnectionState.disconnected:
        return 'Direct SSH';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _getStatusColor();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.zero,
        child: Ink(
          decoration: BoxDecoration(
            color: _ServerListScreenState._cardColor,
            borderRadius: BorderRadius.zero,
            boxShadow: const [
              BoxShadow(
                color: _ServerListScreenState._shadowColor,
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _ServerListScreenState._cardAccent.withValues(
                      alpha: 0.16,
                    ),
                    borderRadius: BorderRadius.zero,
                  ),
                  child: Icon(
                    status.isConnected ? Icons.dns : Icons.dns_outlined,
                    color: status.isConnected 
                        ? AppColors.textPrimary 
                        : _ServerListScreenState._cardAccent,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${server.username}@${server.host}:${server.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _ServerListScreenState._subtitleColor,
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _getStatusLabel(),
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  children: [
                    IconButton(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.panel,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 20),
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.panel,
                        foregroundColor: AppColors.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
