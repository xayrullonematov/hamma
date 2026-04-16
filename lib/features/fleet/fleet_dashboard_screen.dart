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

  @override
  void initState() {
    super.initState();
    _loadFleet();
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
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final server = _servers[index];
                    final metrics = _metricsByServerId[server.id];
                    return _FleetMetricsCard(
                      server: server,
                      metrics: metrics,
                      metricColorBuilder: _metricColor,
                    );
                  }, childCount: _servers.length),
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
        title: const Text('Fleet Metrics'),
        actions: [
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
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null && _servers.isEmpty
              ? _buildErrorState()
              : _servers.isEmpty
              ? _buildEmptyState()
              : _buildGrid(theme),
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
