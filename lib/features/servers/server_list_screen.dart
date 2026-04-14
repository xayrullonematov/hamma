import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models/server_profile.dart';
import '../../core/storage/saved_servers_storage.dart';
import '../settings/settings_screen.dart';
import 'server_dashboard_screen.dart';
import 'server_form_screen.dart';

class ServerListScreen extends StatefulWidget {
  const ServerListScreen({
    super.key,
    required this.aiProvider,
    required this.apiKey,
    required this.onSaveAiSettings,
    this.startupWarning,
  });

  final AiProvider aiProvider;
  final String apiKey;
  final Future<void> Function(AiProvider provider, String apiKey)
      onSaveAiSettings;
  final String? startupWarning;

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
  static const _cardColor = Color(0xFF1E293B);
  static const _cardAccent = Color(0xFF3B82F6);
  static const _subtitleColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x33000000);

  final SavedServersStorage _savedServersStorage = const SavedServersStorage();

  bool _isLoading = true;
  String? _loadError;
  List<ServerProfile> _servers = const [];

  @override
  void initState() {
    super.initState();
    _loadServers();
    if (widget.startupWarning != null && widget.startupWarning!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.startupWarning!)),
        );
      });
    }
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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
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

    final updatedServers = _servers
        .map((item) => item.id == updatedServer.id ? updatedServer : item)
        .toList();
    await _saveServers(updatedServers);
  }

  Future<void> _deleteServer(ServerProfile server) async {
    final shouldDelete = await showDialog<bool>(
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
    final shouldClear = await showDialog<bool>(
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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  void _openServer(ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServerDashboardScreen(
          server: server,
          aiProvider: widget.aiProvider,
          apiKey: widget.apiKey,
          onSaveAiSettings: widget.onSaveAiSettings,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          initialProvider: widget.aiProvider,
          initialApiKey: widget.apiKey,
          onSaveAiSettings: widget.onSaveAiSettings,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Servers'),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                        ),
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
              : CustomScrollView(
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
                                    'Server Dashboard',
                                    style: theme.textTheme.headlineSmall,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Direct SSH access to your saved infrastructure.',
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
                                color: const Color(0xFF162033),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                '${_servers.length} saved',
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
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverList.separated(
                        itemCount: _servers.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 14),
                        itemBuilder: (context, index) {
                          final server = _servers[index];
                          return _ServerDashboardCard(
                            server: server,
                            onOpen: () => _openServer(server),
                            onEdit: () => _editServer(server),
                            onDelete: () => _deleteServer(server),
                          );
                        },
                      ),
                    ),
                  ],
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
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerProfile server;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          decoration: BoxDecoration(
            color: _ServerListScreenState._cardColor,
            borderRadius: BorderRadius.circular(24),
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
                    color: _ServerListScreenState._cardAccent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.dns_outlined,
                    color: _ServerListScreenState._cardAccent,
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
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF162033),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Direct SSH',
                          style: TextStyle(
                            color: _ServerListScreenState._subtitleColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  children: [
                    IconButton(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF162033),
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF162033),
                        foregroundColor: const Color(0xFFFCA5A5),
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
