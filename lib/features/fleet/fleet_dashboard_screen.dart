import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/fleet_service.dart';
import '../../core/storage/server_storage.dart';
import '../../core/theme/app_colors.dart';

class FleetDashboardScreen extends StatefulWidget {
  const FleetDashboardScreen({super.key});

  @override
  State<FleetDashboardScreen> createState() => _FleetDashboardScreenState();
}

class _FleetDashboardScreenState extends State<FleetDashboardScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _mutedColor = AppColors.textMuted;
  static const _primaryColor = AppColors.primary;
  static const _successColor = AppColors.accent;
  static const _warningColor = AppColors.danger;
  static const _dangerColor = AppColors.danger;

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
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surfaceColor,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.borderStrong, width: 1),
        ),
        title: const Text(
          'BULK COMMAND',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
          decoration: const InputDecoration(
            hintText: '\$ enter command (e.g. uptime)',
            hintStyle: TextStyle(
              color: AppColors.textFaint,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
            ),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: _mutedColor)),
          ),
          ElevatedButton(
            onPressed: () {
              final cmd = controller.text.trim();
              if (cmd.isNotEmpty) {
                Navigator.pop(context);
                _executeBulkAction(cmd);
              }
            },
            child: const Text('EXECUTE'),
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
    showModalBottomSheet<void>(
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
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.scaffoldBackground,
              borderRadius: BorderRadius.zero,
              border: Border.all(color: AppColors.borderStrong, width: 1),
            ),
            child: const Icon(
              Icons.dashboard_customize_outlined,
              color: _primaryColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FLEET COMMAND CENTER',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '[$_onlineServerCount/${_servers.length}] ONLINE  ::  LAST_REFRESH ${_formatTimestamp(_lastUpdatedAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _mutedColor,
                    height: 1.4,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontSize: 11,
                    letterSpacing: 0.4,
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: RefreshIndicator(
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
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 450,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      mainAxisExtent: 286,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              : _buildGrid(Theme.of(context)),
      floatingActionButton:
          _servers.isEmpty
              ? null
              : FloatingActionButton(
                onPressed: _showBulkActionDialog,
                backgroundColor: _primaryColor,
                foregroundColor: AppColors.onPrimary,
                elevation: 0,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
                child: const Icon(Icons.bolt),
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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) => Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.zero,
              border: Border(
                top: BorderSide(color: AppColors.borderStrong, width: 1),
                left: BorderSide(color: AppColors.borderStrong, width: 1),
                right: BorderSide(color: AppColors.borderStrong, width: 1),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 2,
                  color: AppColors.borderStrong,
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt, color: AppColors.textPrimary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'BULK_RESULTS',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.6,
                                fontFamily: AppColors.monoFamily,
                                fontFamilyFallback: AppColors.monoFallback,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '\$ ${widget.command}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.textMuted,
                                fontFamily: AppColors.monoFamily,
                                fontFamilyFallback: AppColors.monoFallback,
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
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final server = widget.servers[index];
                      final result = results[server.id] ?? 'Pending...';
                      final isError = result.startsWith('Error:');
                      final isPending =
                          result == 'Executing...' || result == 'Pending...';

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.scaffoldBackground,
                          borderRadius: BorderRadius.zero,
                          border: Border.all(
                            color: isError
                                ? AppColors.danger
                                : isPending
                                    ? AppColors.border
                                    : AppColors.borderStrong,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  server.name.toUpperCase(),
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.2,
                                    fontFamily: AppColors.monoFamily,
                                    fontFamilyFallback: AppColors.monoFallback,
                                  ),
                                ),
                                const Spacer(),
                                if (!isPending)
                                  Icon(
                                    isError
                                        ? Icons.error_outline
                                        : Icons.check_box_outline_blank,
                                    size: 16,
                                    color: isError
                                        ? AppColors.danger
                                        : AppColors.textPrimary,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              result,
                              style: TextStyle(
                                color: isError
                                    ? AppColors.danger
                                    : isPending
                                        ? AppColors.textMuted
                                        : AppColors.textPrimary,
                                fontSize: 13,
                                fontFamily: AppColors.monoFamily,
                                fontFamilyFallback: AppColors.monoFallback,
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

  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _mutedColor = AppColors.textMuted;
  static const _successColor = AppColors.accent;
  static const _dangerColor = AppColors.danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAvailable = metrics?.isAvailable ?? false;

    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.zero,
        border: Border.all(
          color: isAvailable ? AppColors.border : AppColors.danger,
          width: 1,
        ),
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
                        server.name.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${server.username}@${server.host}:${server.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _mutedColor,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isAvailable
                        ? Colors.transparent
                        : AppColors.danger,
                    borderRadius: BorderRadius.zero,
                    border: Border.all(
                      color: isAvailable ? _successColor : AppColors.danger,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    isAvailable ? 'ONLINE' : 'OFFLINE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isAvailable
                          ? _successColor
                          : AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                      fontSize: 10,
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
                borderRadius: BorderRadius.zero,
                border: Border.all(color: AppColors.border, width: 1),
              ),
              child: Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
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
            ),
            const Spacer(),
            Text(
              metrics?.errorMessage ?? '> metrics ok.',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isAvailable ? _mutedColor : _dangerColor,
                height: 1.45,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
                fontSize: 11,
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

  static const _trackColor = AppColors.border;
  static const _mutedColor = AppColors.textMuted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ((percentage ?? 0) / 100).clamp(0.0, 1.0);

    return SizedBox(
      width: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    value: 1,
                    strokeWidth: 4,
                    color: _trackColor,
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 500),
                  builder: (context, animatedValue, _) {
                    return SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(
                        value: animatedValue,
                        strokeWidth: 4,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    );
                  },
                ),
                Text(
                  percentage == null ? '--' : '${percentage!.round()}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
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
              fontWeight: FontWeight.w800,
              fontSize: 10,
              letterSpacing: 1.6,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
            ),
          ),
        ],
      ),
    );
  }
}
