import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/shell/shell_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/theme/app_colors.dart';
import 'widgets/watch_with_ai_screen.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({
    super.key,
    required this.sshService,
    required this.serverName,
    this.aiSettings,
  });

  final ShellService sshService;
  final String serverName;

  /// When supplied, an extra AppBar action opens the same stream in
  /// the "Watch with AI" split-pane view. The triage screen itself
  /// will refuse non-local providers, so this button can be shown
  /// regardless of the active provider.
  final AiSettings? aiSettings;

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> with AutomaticKeepAliveClientMixin<LogViewerScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _mutedColor = AppColors.textMuted;
  static const _dangerColor = AppColors.danger;

  static const int _maxLogLines = 500;

  @override
  bool get wantKeepAlive => true;

  final List<_LogEntry> _logEntries = [];
  final List<_LogEntry> _pendingEntries = [];
  Timer? _batchTimer;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterController = TextEditingController();
  final TextEditingController _customPathController = TextEditingController();

  dynamic _session;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
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
    _batchTimer?.cancel();
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
      
      if (maxScroll - currentScroll > 50) {
        if (_autoScroll) setState(() => _autoScroll = false);
      } else {
        if (!_autoScroll) setState(() => _autoScroll = true);
      }
    }
  }

  void _openWatchWithAi() {
    final settings = widget.aiSettings;
    if (settings == null) return;
    final command = _buildStreamCommand();
    if (command == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a log source first.')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchWithAiScreen(
          sshService: widget.sshService,
          command: command,
          title: _selectedSource.label,
          aiSettings: settings,
        ),
      ),
    );
  }

  /// Builds the streaming shell command for the currently-selected
  /// source, or `null` if the source isn't fully configured (e.g.
  /// custom path with empty input).
  String? _buildStreamCommand() {
    final isWindows = Platform.isWindows;

    switch (_selectedSource) {
      case LogSource.system:
        if (isWindows) {
          return r'powershell.exe -Command "Get-WinEvent -LogName System -MaxEvents 100 | Sort-Object TimeCreated | ForEach-Object { \"$($_.TimeCreated) [$($_.LevelDisplayName)] $($_.Message)\" }"';
        }
        return 'sudo journalctl -f -n 100';
      case LogSource.auth:
        if (isWindows) {
          // Security event log on Windows
          return r'powershell.exe -Command "Get-WinEvent -LogName Security -MaxEvents 100 | Sort-Object TimeCreated | ForEach-Object { \"$($_.TimeCreated) [$($_.LevelDisplayName)] $($_.Message)\" }"';
        }
        return 'sudo tail -f -n 100 /var/log/auth.log';
      case LogSource.custom:
        final path = _customPathController.text.trim();
        if (path.isEmpty) return null;

        if (isWindows) {
          return "powershell.exe -Command \"Get-Content -Wait -Tail 100 '$path'\"";
        }

        // Shell-quote the user-supplied path
        final quoted = "'${path.replaceAll("'", r"'\''")}'";
        return 'sudo tail -f -n 100 $quoted';
    }
  }

  Future<void> _startStreaming() async {
    await _stopStreaming();
    
    setState(() {
      _logEntries.clear();
      _pendingEntries.clear();
      _logEntries.add(_LogEntry('--- Starting stream for ${_selectedSource.label} ---', isError: false));
    });

    final command = _buildStreamCommand();
    if (command == null) {
      setState(() => _logEntries.add(_LogEntry('Error: No custom path provided.', isError: true)));
      return;
    }

    try {
      final dynamic session = await widget.sshService.streamCommand(command);
      _session = session;
      
      _stdoutSubscription = (session.stdout as Stream<Uint8List>)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _handleIncomingLine(line, isError: false));

      _stderrSubscription = (session.stderr as Stream<Uint8List>)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _handleIncomingLine(line, isError: true));
          
      (session.done as Future).then((_) {
        if (mounted) {
          _handleIncomingLine('--- Stream closed by server ---', isError: false);
        }
      });
    } catch (e) {
      if (mounted) {
        _handleIncomingLine('Error: $e', isError: true);
      }
    }
  }

  void _handleIncomingLine(String line, {required bool isError}) {
    if (_isPaused || !mounted) return;

    _pendingEntries.add(_LogEntry(line, isError: isError));
    _batchTimer ??= Timer(const Duration(milliseconds: 100), _flushBatch);
  }

  void _flushBatch() {
    _batchTimer = null;
    if (!mounted || _pendingEntries.isEmpty) return;

    setState(() {
      _logEntries.addAll(_pendingEntries);
      _pendingEntries.clear();
      
      if (_logEntries.length > _maxLogLines) {
        _logEntries.removeRange(0, _logEntries.length - _maxLogLines);
      }
    });

    if (_autoScroll) {
      _scrollToBottom();
    }
  }

  Future<void> _stopStreaming() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _session?.close();
    _session = null;
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _autoScroll) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  List<_LogEntry> get _filteredEntries {
    if (_filter.isEmpty) return _logEntries;
    return _logEntries.where((e) => e.text.toLowerCase().contains(_filter.toLowerCase())).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: const Text('Real-time Logs'),
        actions: [
          if (widget.aiSettings != null)
            IconButton(
              icon: const Icon(Icons.auto_awesome, color: AppColors.accent),
              tooltip: 'Watch with AI',
              onPressed: _openWatchWithAi,
            ),
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() => _isPaused = !_isPaused),
            tooltip: _isPaused ? 'Resume' : 'Pause',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => setState(() => _logEntries.clear()),
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
                borderRadius: BorderRadius.zero,
              ),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _filteredEntries.length,
                itemBuilder: (context, index) {
                  final entry = _filteredEntries[index];
                  return Text(
                    entry.text,
                    style: TextStyle(
                      color: entry.isError ? _dangerColor : _getLineColor(entry.text),
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
                label: Text('Back to bottom', style: TextStyle(color: AppColors.scaffoldBackground)),
                onPressed: () {
                  setState(() => _autoScroll = true);
                  _scrollToBottom();
                },
                backgroundColor: AppColors.textPrimary,
                labelStyle: TextStyle(color: AppColors.scaffoldBackground),
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
                        hintText: Platform.isWindows ? 'C:\\Logs\\app.log' : '/var/log/syslog',
                        hintStyle: const TextStyle(color: _mutedColor),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.zero),
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
          border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: const BorderSide(color: AppColors.border, width: 1)),
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
      return AppColors.textMuted;
    }
    if (l.contains('success') || l.contains('connected')) {
      return AppColors.textPrimary;
    }
    return AppColors.textPrimary;
  }
}

class _LogEntry {
  final String text;
  final bool isError;

  _LogEntry(this.text, {this.isError = false});
}

enum LogSource {
  system('System (journalctl / WinEvent)'),
  auth('Auth logs (/var/log/auth / Security)'),
  custom('Custom Path');

  final String label;
  const LogSource(this.label);
}
