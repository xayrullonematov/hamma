import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/theme/app_colors.dart';

class DockerManagerScreen extends StatefulWidget {
  const DockerManagerScreen({
    super.key,
    required this.sshService,
    required this.serverName,
  });

  final SshService sshService;
  final String serverName;

  @override
  State<DockerManagerScreen> createState() => _DockerManagerScreenState();
}

class _DockerManagerScreenState extends State<DockerManagerScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _mutedColor = AppColors.textMuted;
  static const _dangerColor = AppColors.danger;

  List<DockerContainer> _containers = [];
  bool _isLoading = true;
  bool _dockerMissing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchContainers();
  }

  Future<void> _fetchContainers() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _dockerMissing = false;
    });

    try {
      final output = await widget.sshService.execute(
        "docker ps -a --format '{{json .}}'",
      );
      
      final lines = output.trim().split('\n').where((l) => l.isNotEmpty);
      final containers = lines.map((line) {
        final map = jsonDecode(line) as Map<String, dynamic>;
        return DockerContainer.fromJson(map);
      }).toList();

      if (mounted) {
        setState(() {
          _containers = containers;
          _isLoading = false;
        });
      }
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (errorStr.contains('command not found') || errorStr.contains('no such file')) {
            _dockerMissing = true;
          } else {
            _error = e.toString();
          }
        });
      }
    }
  }

  Future<void> _runAction(String containerId, String action) async {
    setState(() => _isLoading = true);
    try {
      await widget.sshService.execute('docker $action $containerId');
      await _fetchContainers();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError('Failed to $action: $e');
      }
    }
  }

  Future<void> _showLogs(DockerContainer container) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: _backgroundColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _DockerLogsView(
        sshService: widget.sshService,
        container: container,
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: _dangerColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Docker Manager'),
            Text(
              widget.serverName,
              style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _fetchContainers,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading && _containers.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _dockerMissing
              ? _buildEmptyState(
                  Icons.layers_clear_outlined,
                  'Docker not found',
                  'It looks like Docker is not installed or the user does not have permission to run it.',
                )
              : _error != null && _containers.isEmpty
                  ? _buildEmptyState(Icons.error_outline, 'Error', _error!)
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1400),
                        child: RefreshIndicator(
                          onRefresh: _fetchContainers,
                          child: GridView.builder(
                            padding: const EdgeInsets.all(16),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 400,
                              mainAxisExtent: 180,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                            ),
                            itemCount: _containers.length,
                            itemBuilder: (context, index) {
                              return _ContainerCard(
                                container: _containers[index],
                                onAction: (action) => _runAction(_containers[index].id, action),
                                onShowLogs: () => _showLogs(_containers[index]),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
    );
  }

  Widget _buildEmptyState(IconData icon, String title, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: _mutedColor),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _mutedColor),
            ),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _fetchContainers, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class DockerContainer {
  final String id;
  final String name;
  final String image;
  final String status;
  final String state;
  final String ports;

  DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.state,
    required this.ports,
  });

  factory DockerContainer.fromJson(Map<String, dynamic> json) {
    return DockerContainer(
      id: json['ID'] ?? '',
      name: json['Names'] ?? '',
      image: json['Image'] ?? '',
      status: json['Status'] ?? '',
      state: json['State'] ?? '',
      ports: json['Ports'] ?? '',
    );
  }
}

class _ContainerCard extends StatelessWidget {
  const _ContainerCard({
    required this.container,
    required this.onAction,
    required this.onShowLogs,
  });

  final DockerContainer container;
  final Function(String) onAction;
  final VoidCallback onShowLogs;

  Color _getStateColor() {
    switch (container.state.toLowerCase()) {
      case 'running':
        return AppColors.textPrimary;
      case 'exited':
      case 'dead':
        return AppColors.danger;
      case 'restarting':
      case 'paused':
      case 'created':
        return AppColors.textMuted;
      default:
        return AppColors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final stateColor = _getStateColor();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            title: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    container.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  container.image,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  container.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: stateColor.withValues(alpha: 0.8), fontSize: 12),
                ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
              onSelected: onAction,
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'start', child: Text('Start')),
                const PopupMenuItem(value: 'stop', child: Text('Stop')),
                const PopupMenuItem(value: 'restart', child: Text('Restart')),
                const PopupMenuItem(value: 'rm -f', child: Text('Remove', style: TextStyle(color: AppColors.danger))),
              ],
            ),
          ),
          const Spacer(),
          const Divider(color: Colors.white10, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onShowLogs,
                  icon: const Icon(Icons.article_outlined, size: 18),
                  label: const Text('Logs'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DockerLogsView extends StatefulWidget {
  const _DockerLogsView({
    required this.sshService,
    required this.container,
  });

  final SshService sshService;
  final DockerContainer container;

  @override
  State<_DockerLogsView> createState() => _DockerLogsViewState();
}

class _DockerLogsViewState extends State<_DockerLogsView> {
  String _logs = 'Loading logs...';

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  Future<void> _fetchLogs() async {
    try {
      final output = await widget.sshService.execute(
        'docker logs --tail 100 ${widget.container.id}',
      );
      if (mounted) {
        setState(() => _logs = output.isEmpty ? '(no logs found)' : output);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _logs = 'Error fetching logs: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Logs: ${widget.container.name}',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _logs,
                  style: const TextStyle(color: AppColors.textPrimary, fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
