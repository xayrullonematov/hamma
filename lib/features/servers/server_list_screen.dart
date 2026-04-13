import 'package:flutter/material.dart';

import '../../core/models/server_profile.dart';
import '../../core/storage/saved_servers_storage.dart';
import '../settings/settings_screen.dart';
import 'server_dashboard_screen.dart';
import 'server_form_screen.dart';

class ServerListScreen extends StatefulWidget {
  const ServerListScreen({
    super.key,
    required this.apiKey,
    required this.onSaveApiKey,
    this.startupWarning,
  });

  final String apiKey;
  final Future<void> Function(String apiKey) onSaveApiKey;
  final String? startupWarning;

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
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
          apiKey: widget.apiKey,
          onSaveApiKey: widget.onSaveApiKey,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          initialApiKey: widget.apiKey,
          onSaveApiKey: widget.onSaveApiKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _servers.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final server = _servers[index];
                    return Card(
                      child: ListTile(
                        onTap: () => _openServer(server),
                        title: Text(server.name),
                        subtitle: Text(
                          '${server.username}@${server.host}:${server.port}',
                        ),
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            IconButton(
                              onPressed: () => _editServer(server),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              onPressed: () => _deleteServer(server),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addServer,
        icon: const Icon(Icons.add),
        label: const Text('Add Server'),
      ),
    );
  }
}
