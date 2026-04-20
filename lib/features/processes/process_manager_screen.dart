import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/ssh/ssh_service.dart';

class ProcessManagerScreen extends StatefulWidget {
  const ProcessManagerScreen({
    super.key,
    required this.sshService,
    required this.serverName,
  });

  final SshService sshService;
  final String serverName;

  @override
  State<ProcessManagerScreen> createState() => _ProcessManagerScreenState();
}

class _ProcessManagerScreenState extends State<ProcessManagerScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _dangerColor = Color(0xFFEF4444);

  final TextEditingController _searchController = TextEditingController();
  List<ProcessInfo> _allProcesses = [];
  List<ProcessInfo> _filteredProcesses = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchProcesses();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && !_isLoading) {
        _fetchProcesses(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchProcesses({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final output = await widget.sshService.execute(
        'ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 50',
      );
      final processes = _parseProcesses(output);
      if (mounted) {
        setState(() {
          _allProcesses = processes;
          _applySearch();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        if (!silent) {
          _showError('Failed to fetch processes: $e');
        }
      }
    }
  }

  List<ProcessInfo> _parseProcesses(String output) {
    final lines = output.trim().split('\n');
    if (lines.isEmpty) return [];

    final processes = <ProcessInfo>[];
    // Skip header line
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 5) {
        processes.add(ProcessInfo(
          pid: parts[0],
          user: parts[1],
          cpu: double.tryParse(parts[2]) ?? 0.0,
          ram: double.tryParse(parts[3]) ?? 0.0,
          command: parts.sublist(4).join(' '),
        ));
      }
    }
    return processes;
  }

  void _applySearch() {
    if (_searchQuery.isEmpty) {
      _filteredProcesses = List.from(_allProcesses);
    } else {
      _filteredProcesses = _allProcesses
          .where((p) =>
              p.command.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              p.pid.contains(_searchQuery) ||
              p.user.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
  }

  Future<void> _killProcess(ProcessInfo process) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surfaceColor,
        title: const Text('Kill Process', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to kill process ${process.pid} (${process.command})?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: _mutedColor)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kill', style: TextStyle(color: _dangerColor)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
    });

    try {
      await widget.sshService.execute('sudo kill -9 ${process.pid}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Process ${process.pid} terminated')),
        );
        _fetchProcesses();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showError('Failed to kill process: $e');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: _dangerColor,
      ),
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
            const Text('Process Manager'),
            Text(
              widget.serverName,
              style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _fetchProcesses,
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
                hintText: 'Search PID, user, or command...',
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
          _buildHeader(),
          Expanded(
            child: _isLoading && _allProcesses.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _fetchProcesses,
                    child: ListView.builder(
                      itemCount: _filteredProcesses.length,
                      itemBuilder: (context, index) {
                        return _ProcessTile(
                          process: _filteredProcesses[index],
                          onKill: () => _killProcess(_filteredProcesses[index]),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      color: _panelColor,
      child: const Row(
        children: [
          SizedBox(width: 50, child: Text('PID', style: TextStyle(color: _mutedColor, fontWeight: FontWeight.bold))),
          Expanded(child: Text('Command', style: TextStyle(color: _mutedColor, fontWeight: FontWeight.bold))),
          SizedBox(width: 80, child: Text('Usage', textAlign: TextAlign.right, style: TextStyle(color: _mutedColor, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }
}

class ProcessInfo {
  final String pid;
  final String user;
  final double cpu;
  final double ram;
  final String command;

  ProcessInfo({
    required this.pid,
    required this.user,
    required this.cpu,
    required this.ram,
    required this.command,
  });
}

class _ProcessTile extends StatelessWidget {
  const _ProcessTile({
    required this.process,
    required this.onKill,
  });

  final ProcessInfo process;
  final VoidCallback onKill;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Row(
          children: [
            SizedBox(
              width: 50,
              child: Text(
                process.pid,
                style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            Expanded(
              child: Text(
                process.command,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('User: ${process.user}', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
              const SizedBox(height: 8),
              _UsageBar(label: 'CPU', value: process.cpu, color: const Color(0xFF3B82F6)),
              const SizedBox(height: 4),
              _UsageBar(label: 'RAM', value: process.ram, color: const Color(0xFF22C55E)),
            ],
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, color: Color(0xFFEF4444), size: 20),
          onPressed: onKill,
          tooltip: 'Kill Process',
        ),
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 35, child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (value / 100).clamp(0.0, 1.0),
              backgroundColor: const Color(0xFF0F172A),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 4,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 35,
          child: Text(
            '${value.toStringAsFixed(1)}%',
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
