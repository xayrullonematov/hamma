import 'package:flutter/material.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/theme/app_colors.dart';

class ServiceManagementScreen extends StatefulWidget {
  const ServiceManagementScreen({
    super.key,
    required this.sshService,
    required this.serverName,
  });

  final SshService sshService;
  final String serverName;

  @override
  State<ServiceManagementScreen> createState() => _ServiceManagementScreenState();
}

class _ServiceManagementScreenState extends State<ServiceManagementScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _mutedColor = AppColors.textMuted;
  static const _dangerColor = AppColors.danger;

  final TextEditingController _searchController = TextEditingController();
  List<LinuxService> _allServices = [];
  List<LinuxService> _filteredServices = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _transitioningServiceName;

  @override
  void initState() {
    super.initState();
    _fetchServices();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchServices() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final output = await widget.sshService.execute(
        'systemctl list-units --type=service --all --no-pager',
      );
      final services = _parseServices(output);
      if (mounted) {
        setState(() {
          _allServices = services;
          _applySearch();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showError(e.toString());
      }
    }
  }

  List<LinuxService> _parseServices(String output) {
    final lines = output.split('\n');
    final services = <LinuxService>[];

    bool startParsing = false;
    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('UNIT') && trimmed.contains('LOAD')) {
        startParsing = true;
        continue;
      }

      if (startParsing) {
        if (trimmed.startsWith('LOAD')) break;
        if (trimmed.contains('loaded units listed')) break;
        // Handle footer or summary lines that start with a digit or have "listed"
        if (RegExp(r'^\d+').hasMatch(trimmed) && trimmed.contains('listed')) break;

        // Split by whitespace
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length >= 4) {
          final unit = parts[0];
          final load = parts[1];
          final active = parts[2];
          final sub = parts[3];
          final description = parts.length > 4 ? parts.sublist(4).join(' ') : '';

          services.add(LinuxService(
            name: unit,
            load: load,
            active: active,
            sub: sub,
            description: description,
          ));
        }
      }
    }
    return services;
  }

  void _applySearch() {
    if (_searchQuery.isEmpty) {
      _filteredServices = List.from(_allServices);
    } else {
      _filteredServices = _allServices
          .where((s) =>
              s.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              s.description.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
  }

  Future<void> _runAction(LinuxService service, String action) async {
    final command = 'sudo systemctl $action ${service.name}';
    
    setState(() {
      _transitioningServiceName = service.name;
    });

    try {
      final result = await widget.sshService.execute(command);
      
      final lowerResult = result.toLowerCase();
      if (lowerResult.contains('password is required') || lowerResult.contains('failed')) {
        throw Exception(result.trim());
      }

      // Wait for systemd to finish transition
      await Future.delayed(const Duration(milliseconds: 800));
      
      await _fetchServices();
    } catch (e) {
      if (mounted) {
        _showError(e.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _transitioningServiceName = null;
        });
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    final isPermissionDenied = message.toLowerCase().contains('permission denied') || 
                               message.toLowerCase().contains('interactive authentication required') ||
                               message.toLowerCase().contains('password is required');
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isPermissionDenied ? 'Permission Denied: Sudo required' : message),
        backgroundColor: _dangerColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Service Management'),
            Text(
              widget.serverName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: _mutedColor),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _fetchServices,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                      _applySearch();
                    });
                  },
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search services...',
                    hintStyle: const TextStyle(color: _mutedColor),
                    prefixIcon: const Icon(Icons.search, color: _mutedColor),
                    filled: true,
                    fillColor: _surfaceColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                      borderSide: const BorderSide(color: AppColors.border, width: 1),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _isLoading && _allServices.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _fetchServices,
                        child: GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 450,
                            mainAxisExtent: 100,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                          itemCount: _filteredServices.length,
                          itemBuilder: (context, index) {
                            final service = _filteredServices[index];
                            return _ServiceCard(
                              service: service,
                              isTransitioning: _transitioningServiceName == service.name,
                              onAction: (action) => _runAction(service, action),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LinuxService {
  final String name;
  final String load;
  final String active;
  final String sub;
  final String description;

  LinuxService({
    required this.name,
    required this.load,
    required this.active,
    required this.sub,
    required this.description,
  });

  bool get isActive => active == 'active';
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.isTransitioning,
    required this.onAction,
  });

  final LinuxService service;
  final bool isTransitioning;
  final Function(String) onAction;

  @override
  Widget build(BuildContext context) {
    final isActive = service.isActive;
    final color = isActive ? AppColors.accent : AppColors.textMuted;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.zero,
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Center(
        child: ListTile(
          leading: isTransitioning
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
          title: Text(
            service.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            service.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          trailing: IgnorePointer(
            ignoring: isTransitioning,
            child: Opacity(
              opacity: isTransitioning ? 0.5 : 1.0,
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
                onSelected: onAction,
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'start', child: Text('Start')),
                  const PopupMenuItem(value: 'stop', child: Text('Stop')),
                  const PopupMenuItem(value: 'restart', child: Text('Restart')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
