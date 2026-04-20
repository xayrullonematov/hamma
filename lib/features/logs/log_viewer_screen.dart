import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import '../../core/ssh/ssh_service.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({
    super.key,
    required this.sshService,
    required this.serverName,
  });

  final SshService sshService;
  final String serverName;

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _primaryColor = Color(0xFF3B82F6);
  static const _dangerColor = Color(0xFFEF4444);

  final List<String> _logLines = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterController = TextEditingController();
  final TextEditingController _customPathController = TextEditingController();

  SSHSession? _session;
  StreamSubscription? _stdoutSubscription;
  bool _isPaused = false;
  bool _autoScroll = true;
  String _filter = '';
  
  LogSource _selectedSource = LogSource.system;

  @override
  void initState() {
    super.initState();
    _startStreaming();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _stopStreaming();
    _scrollController.dispose();
    _filterController.dispose();
    _customPathController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      
      // If user scrolls up, disable auto-scroll. If they are at the bottom, enable it.
      if (maxScroll - currentScroll > 50) {
        if (_autoScroll) setState(() => _autoScroll = false);
      } else {
        if (!_autoScroll) setState(() => _autoScroll = true);
      }
    }
  }

  Future<void> _startStreaming() async {
    await _stopStreaming();
    
    setState(() {
      _logLines.clear();
      _logLines.add('--- Starting stream for ${_selectedSource.label} ---');
    });

    String command = '';
    switch (_selectedSource) {
      case LogSource.system:
        command = 'sudo journalctl -f -n 100';
        break;
      case LogSource.auth:
        command = 'sudo tail -f -n 100 /var/log/auth.log';
        break;
      case LogSource.custom:
        final path = _customPathController.text.trim();
        if (path.isEmpty) {
          setState(() => _logLines.add('Error: No custom path provided.'));
          return;
        }
        command = 'sudo tail -f -n 100 $path';
        break;
    }

    try {
      final session = await widget.sshService.streamCommand(command);
      _session = session;
      
      _stdoutSubscription = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (!_isPaused && mounted) {
              setState(() {
                _logLines.add(line);
                if (_logLines.length > 2000) _logLines.removeAt(0);
              });
              if (_autoScroll) {
                _scrollToBottom();
              }
            }
          });
          
      session.done.then((_) {
        if (mounted) {
          setState(() => _logLines.add('--- Stream closed by server ---'));
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _logLines.add('Error: $e'));
      }
    }
  }

  Future<void> _stopStreaming() async {
    await _stdoutSubscription?.cancel();
    _session?.close();
    _session = null;
    _stdoutSubscription = null;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _autoScroll) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  List<String> get _filteredLines {
    if (_filter.isEmpty) return _logLines;
    return _logLines.where((l) => l.toLowerCase().contains(_filter.toLowerCase())).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: const Text('Real-time Logs'),
        actions: [
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() => _isPaused = !_isPaused),
            tooltip: _isPaused ? 'Resume' : 'Pause',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => setState(() => _logLines.clear()),
            tooltip: 'Clear view',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSourceSelector(),
          _buildFilterBar(),
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _filteredLines.length,
                itemBuilder: (context, index) {
                  final line = _filteredLines[index];
                  return Text(
                    line,
                    style: TextStyle(
                      color: _getLineColor(line),
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  );
                },
              ),
            ),
          ),
          if (!_autoScroll)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: ActionChip(
                label: const Text('Back to bottom'),
                onPressed: () {
                  setState(() => _autoScroll = true);
                  _scrollToBottom();
                },
                backgroundColor: _primaryColor,
                labelStyle: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: _surfaceColor,
      child: Column(
        children: [
          Row(
            children: [
              const Text('Source:', style: TextStyle(color: _mutedColor)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<LogSource>(
                  value: _selectedSource,
                  isExpanded: true,
                  dropdownColor: _surfaceColor,
                  underline: const SizedBox(),
                  style: const TextStyle(color: Colors.white),
                  items: LogSource.values.map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(s.label),
                  )).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedSource = val);
                      if (val != LogSource.custom) _startStreaming();
                    }
                  },
                ),
              ),
            ],
          ),
          if (_selectedSource == LogSource.custom)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customPathController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '/var/log/syslog',
                        hintStyle: const TextStyle(color: _mutedColor),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _startStreaming,
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: TextField(
        controller: _filterController,
        onChanged: (val) => setState(() => _filter = val),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Filter logs...',
          hintStyle: const TextStyle(color: _mutedColor),
          prefixIcon: const Icon(Icons.filter_list, color: _mutedColor),
          filled: true,
          fillColor: _surfaceColor,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Color _getLineColor(String line) {
    final l = line.toLowerCase();
    if (l.contains('error') || l.contains('failed') || l.contains('critical') || l.contains('404')) {
      return _dangerColor;
    }
    if (l.contains('warn')) {
      return Colors.orange;
    }
    if (l.contains('success') || l.contains('connected')) {
      return Colors.green;
    }
    return const Color(0xFFE2E8F0);
  }
}

enum LogSource {
  system('System (journalctl)'),
  auth('Auth logs (/var/log/auth.log)'),
  custom('Custom Path');

  final String label;
  const LogSource(this.label);
}
