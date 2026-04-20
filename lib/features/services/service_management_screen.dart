import 'package:flutter/material.dart';
import '../../core/ssh/ssh_service.dart';

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
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _dangerColor = Color(0xFFEF4444);

  final TextEditingController _searchController = TextEditingController();
  List<LinuxService> _allServices = [];
  List<LinuxService> _filteredServices = [];
  bool _isLoading = true;
  String _searchQuery = '';

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

    // Find the header line to determine column positions if needed, 
    // or just look for the units.
    // systemctl output typically looks like:
    //   UNIT             LOAD   ACTIVE SUB     DESCRIPTION
    //   atd.service      loaded active running Deferred execution scheduler
    
    bool startParsing = false;
    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('UNIT') && trimmed.contains('LOAD')) {
        startParsing = true;
        continue;
      }
      if (startParsing) {
        if (trimmed.isEmpty || trimmed.startsWith('LOAD')) break;
        if (trimmed.contains('loaded units listed')) break;

        // Split by multiple spaces
        final parts = trimmed.split(RegExp(r'\s{2,}'));
        if (parts.length >= 4) {
          final unit = parts[0];
          final load = parts[1];
          final active = parts[2];
          final sub = parts[3];
          final description = parts.length > 4 ? parts[4] : '';

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
    
    // Show a loading indicator for the specific action if possible, 
    // but for simplicity we'll just show the global busy state.
    setState(() {
      _isLoading = true;
    });

    try {
      await widget.sshService.execute(command);
      await _fetchServices(); // Refresh after action
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showError(e.toString());
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    final isPermissionDenied = message.toLowerCase().contains('permission denied') || 
                               message.toLowerCase().contains('interactive authentication required');
    
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
      body: Column(
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
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading && _allServices.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _fetchServices,
                    child: ListView.builder(
                      itemCount: _filteredServices.length,
                      itemBuilder: (context, index) {
                        final service = _filteredServices[index];
                        return _ServiceTile(
                          service: service,
                          onAction: (action) => _runAction(service, action),
                        );
                      },
                    ),
                  ),
          ),
        ],
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

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.service,
    required this.onAction,
  });

  final LinuxService service;
  final Function(String) onAction;

  @override
  Widget build(BuildContext context) {
    final isActive = service.isActive;
    final color = isActive ? const Color(0xFF22C55E) : const Color(0xFF94A3B8);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: ListTile(
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        title: Text(
          service.name,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          service.description,
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Color(0xFF94A3B8)),
          onSelected: onAction,
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'start', child: Text('Start')),
            const PopupMenuItem(value: 'stop', child: Text('Stop')),
            const PopupMenuItem(value: 'restart', child: Text('Restart')),
          ],
        ),
      ),
    );
  }
}
