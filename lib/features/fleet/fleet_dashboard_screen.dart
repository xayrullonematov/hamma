import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/fleet_service.dart';
import '../../core/storage/server_storage.dart';

class FleetDashboardScreen extends StatefulWidget {
  const FleetDashboardScreen({super.key});

  @override
  State<FleetDashboardScreen> createState() => _FleetDashboardScreenState();
}

class _FleetDashboardScreenState extends State<FleetDashboardScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _primaryColor = Color(0xFF3B82F6);
  static const _successColor = Color(0xFF22C55E);
  static const _warningColor = Color(0xFFF59E0B);
  static const _dangerColor = Color(0xFFEF4444);
  static const _shadowColor = Color(0x22000000);

  final ServerStorage _serverStorage = const ServerStorage();
  final FleetService _fleetService = const FleetService();

  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _loadError;
  List<ServerProfile> _servers = const [];
  Map<String, ServerMetrics> _metricsByServerId = const {};

  bool _isExecutingBulkCommand = false;
  Map<String, String> _bulkCommandResults = {};

  bool _isSearching = false;
  String _searchQuery = '';
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _loadFleet();
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

  void _showBulkActionDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surfaceColor,
        title: const Text('Bulk Command', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter command (e.g. uptime)',
            hintStyle: TextStyle(color: _mutedColor),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: _mutedColor)),
          ),
          ElevatedButton(
            onPressed: () {
              final cmd = controller.text.trim();
              if (cmd.isNotEmpty) {
                Navigator.pop(context);
                _executeBulkAction(cmd);
              }
            },
            child: const Text('Execute'),
          ),
        ],
      ),
    );
  }

  void _executeBulkAction(String command) {
    if (_servers.isEmpty) {
      return;
    }

    setState(() {
      _isExecutingBulkCommand = true;
      _bulkCommandResults = {for (var s in _servers) s.id: 'Executing...'};
    });

    _showBulkResultsSheet(command);

    _fleetService.executeBulkCommand(
      _servers,
      command,
      onServerResult: (serverId, result) {
        if (mounted) {
          setState(() {
            _bulkCommandResults[serverId] = result;
          });
        }
      },
    ).then((_) {
      if (mounted) {
        setState(() {
          _isExecutingBulkCommand = false;
        });
      }
    });
  }

  void _showBulkResultsSheet(String command) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _BulkResultsOverlay(
        command: command,
        servers: _servers,
        resultsProvider: () => _bulkCommandResults,
        isExecutingProvider: () => _isExecutingBulkCommand,
      ),
    );
  }

  Future<void> _loadFleet({bool manualRefresh = false}) async {
    if (manualRefresh) {
      if (_isRefreshing) {
        return;
      }

      setState(() {
        _isRefreshing = true;
      });
    } else {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final servers = await _serverStorage.loadServers();
      final metricsByServerId =
          servers.isEmpty
              ? <String, ServerMetrics>{}
              : await _fleetService.pollFleet(servers);
      if (!mounted) {
        return;
      }

      setState(() {
        _servers = servers;
        _metricsByServerId = metricsByServerId;
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
          _isRefreshing = false;
        });
      }
    }
  }

  int _crossAxisCount(double width) {
    if (width >= 1360) {
      return 4;
    }
    if (width >= 1024) {
      return 3;
    }
    if (width >= 720) {
      return 2;
    }
    return 1;
  }

  int get _onlineServerCount {
    return _metricsByServerId.values
        .where((metrics) => metrics.isAvailable)
        .length;
  }

  DateTime? get _lastUpdatedAt {
    final timestamps = _metricsByServerId.values
        .map((metrics) => metrics.collectedAt)
        .toList(growable: false);
    if (timestamps.isEmpty) {
      return null;
    }

    timestamps.sort();
    return timestamps.last;
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) {
      return 'Not updated yet';
    }

    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  Future<void> _refreshFleet() async {
    await _loadFleet(manualRefresh: true);
  }

  Color _metricColor(double? percentage) {
    if (percentage == null) {
      return _mutedColor;
    }
    if (percentage < 50) {
      return _successColor;
    }
    if (percentage <= 80) {
      return _warningColor;
    }
    return _dangerColor;
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

  Widget _buildSummaryCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: _shadowColor, blurRadius: 20, offset: Offset(0, 10)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _primaryColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.dashboard_customize_outlined,
              color: _primaryColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fleet Command Center',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_onlineServerCount of ${_servers.length} servers responded • Last refresh ${_formatTimestamp(_lastUpdatedAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _mutedColor,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 42, color: _mutedColor),
            const SizedBox(height: 12),
            Text(
              _loadError ?? 'Failed to load fleet metrics.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: _loadFleet, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No saved servers yet. Add a server first to populate the fleet dashboard.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildGrid(ThemeData theme) {
    final filteredServers = _filteredServers;
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _crossAxisCount(constraints.maxWidth);

        return RefreshIndicator(
          onRefresh: _refreshFleet,
          color: _primaryColor,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _buildSummaryCard(theme),
                ),
              ),
              if (filteredServers.isEmpty && _isSearching)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      'No servers match your search.',
                      style: TextStyle(color: _mutedColor),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final server = filteredServers[index];
                      final metrics = _metricsByServerId[server.id];
                      return _FleetMetricsCard(
                        server: server,
                        metrics: metrics,
                        metricColorBuilder: _metricColor,
                      );
                    }, childCount: filteredServers.length),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      mainAxisExtent: 286,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title:
            _isSearching
                ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search fleet...',
                    border: InputBorder.none,
                    hintStyle: TextStyle(color: _mutedColor),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                )
                : const Text('Fleet Metrics'),
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
              onPressed: _isRefreshing ? null : _refreshFleet,
              icon:
                  _isRefreshing
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh',
            ),
          ],
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null && _servers.isEmpty
              ? _buildErrorState()
              : _servers.isEmpty
              ? _buildEmptyState()
              : _buildGrid(theme),
      floatingActionButton:
          _servers.isEmpty
              ? null
              : FloatingActionButton(
                onPressed: _showBulkActionDialog,
                backgroundColor: _primaryColor,
                child: const Icon(Icons.bolt, color: Colors.white),
              ),
    );
  }
}

class _BulkResultsOverlay extends StatefulWidget {
  const _BulkResultsOverlay({
    required this.command,
    required this.servers,
    required this.resultsProvider,
    required this.isExecutingProvider,
  });

  final String command;
  final List<ServerProfile> servers;
  final Map<String, String> Function() resultsProvider;
  final bool Function() isExecutingProvider;

  @override
  State<_BulkResultsOverlay> createState() => _BulkResultsOverlayState();
}

class _BulkResultsOverlayState extends State<_BulkResultsOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
      if (!widget.isExecutingProvider()) {
        _timer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = widget.resultsProvider();
    final isExecuting = widget.isExecutingProvider();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E293B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  const Icon(Icons.bolt, color: Color(0xFF3B82F6)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bulk Command Results',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.command,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF94A3B8),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isExecuting)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                itemCount: widget.servers.length,
                separatorBuilder: (_, _) => const SizedBox(height: 16),
                itemBuilder: (context, index) {
                  final server = widget.servers[index];
                  final result = results[server.id] ?? 'Pending...';
                  final isError = result.startsWith('Error:');
                  final isPending =
                      result == 'Executing...' || result == 'Pending...';

                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color:
                            isError
                                ? const Color(0xFFEF4444).withValues(alpha: 0.3)
                                : isPending
                                ? Colors.transparent
                                : const Color(0xFF22C55E).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              server.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            if (!isPending)
                              Icon(
                                isError
                                    ? Icons.error_outline
                                    : Icons.check_circle_outline,
                                size: 16,
                                color:
                                    isError
                                        ? const Color(0xFFEF4444)
                                        : const Color(0xFF22C55E),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          result,
                          style: TextStyle(
                            color:
                                isPending ? const Color(0xFF94A3B8) : Colors.white,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _FleetMetricsCard extends StatelessWidget {
  const _FleetMetricsCard({
    required this.server,
    required this.metrics,
    required this.metricColorBuilder,
  });

  final ServerProfile server;
  final ServerMetrics? metrics;
  final Color Function(double? percentage) metricColorBuilder;

  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);
  static const _successColor = Color(0xFF22C55E);
  static const _dangerColor = Color(0xFFEF4444);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAvailable = metrics?.isAvailable ?? false;

    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(color: _shadowColor, blurRadius: 20, offset: Offset(0, 10)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${server.username}@${server.host}:${server.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _mutedColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: (isAvailable ? _successColor : _dangerColor)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isAvailable ? 'Online' : 'Unavailable',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isAvailable ? _successColor : _dangerColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _panelColor,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                runAlignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  _MetricDial(
                    label: 'CPU',
                    percentage: metrics?.cpuPercentage,
                    color: metricColorBuilder(metrics?.cpuPercentage),
                  ),
                  _MetricDial(
                    label: 'RAM',
                    percentage: metrics?.ramPercentage,
                    color: metricColorBuilder(metrics?.ramPercentage),
                  ),
                  _MetricDial(
                    label: 'Disk',
                    percentage: metrics?.diskPercentage,
                    color: metricColorBuilder(metrics?.diskPercentage),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Text(
              metrics?.errorMessage ?? 'Metrics refreshed successfully.',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isAvailable ? _mutedColor : _dangerColor,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricDial extends StatelessWidget {
  const _MetricDial({
    required this.label,
    required this.percentage,
    required this.color,
  });

  final String label;
  final double? percentage;
  final Color color;

  static const _trackColor = Color(0xFF0F172A);
  static const _mutedColor = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ((percentage ?? 0) / 100).clamp(0.0, 1.0);

    return SizedBox(
      width: 88,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(
                    value: 1,
                    strokeWidth: 8,
                    color: _trackColor,
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 500),
                  builder: (context, animatedValue, _) {
                    return SizedBox(
                      width: 72,
                      height: 72,
                      child: CircularProgressIndicator(
                        value: animatedValue,
                        strokeWidth: 8,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    );
                  },
                ),
                Text(
                  percentage == null ? '--' : '${percentage!.round()}%',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _mutedColor,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
