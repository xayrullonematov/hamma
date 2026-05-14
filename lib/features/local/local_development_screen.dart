import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import '../../core/local/local_shell_service.dart';
import '../../core/shell/shell_service.dart';
import '../../core/theme/app_colors.dart';
import '../processes/process_manager_screen.dart';
import '../observability/health_tab.dart';
import '../logs/log_viewer_screen.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/storage/api_key_storage.dart';

class LocalDevelopmentScreen extends StatefulWidget {
  const LocalDevelopmentScreen({super.key});

  @override
  State<LocalDevelopmentScreen> createState() => _LocalDevelopmentScreenState();
}

class _LocalDevelopmentScreenState extends State<LocalDevelopmentScreen> {
  final LocalShellService _shell = LocalShellService.local;
  int _selectedIndex = 0;
  bool _isConnecting = false;
  AiSettings? _aiSettings;

  @override
  void initState() {
    super.initState();
    _loadAiSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connect();
    });
  }

  Future<void> _loadAiSettings() async {
    final settings = await const ApiKeyStorage().loadSettings();
    if (mounted) {
      setState(() => _aiSettings = settings);
    }
  }

  Future<void> _connect() async {
    setState(() => _isConnecting = true);
    try {
      await _shell.connect();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString()),
          duration: const Duration(seconds: 10),
        ));
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: AppColors.monoFamily, fontSize: 11, color: AppColors.textMuted);

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        elevation: 0,
        leading: const BackButton(color: AppColors.textPrimary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('LOCAL DEVELOPMENT',
              style: TextStyle(fontFamily: AppColors.monoFamily, fontWeight: FontWeight.w800,
                fontSize: 14, letterSpacing: 1.5, color: AppColors.textPrimary)),
            Text(Platform.operatingSystem.toUpperCase(),
              style: const TextStyle(fontSize: 11, color: AppColors.accent,
                fontFamily: AppColors.monoFamily, letterSpacing: 1)),
          ],
        ),
      ),
      body: _isConnecting
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(color: AppColors.textPrimary),
              const SizedBox(height: 16),
              Text('STARTING LOCAL SESSION...', style: mono),
            ]))
          : Column(
              children: [
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: [
                      _LocalTerminalTab(shell: _shell),
                      HealthTab(
                        sshService: _shell,
                        serverName: 'localhost',
                        aiSettings: _aiSettings ?? const AiSettings(provider: AiProvider.openAi),
                      ),
                      LogViewerScreen(
                        sshService: _shell,
                        serverName: 'localhost',
                        aiSettings: _aiSettings,
                      ),
                      ProcessManagerScreen(
                        sshService: _shell,
                        serverName: 'localhost',
                      ),
                    ],
                  ),
                ),
                _buildBottomNav(),
              ],
            ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        backgroundColor: AppColors.scaffoldBackground,
        indicatorColor: AppColors.accent.withValues(alpha: 0.1),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.terminal_rounded),
            label: 'TERMINAL',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            label: 'HEALTH',
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            label: 'LOGS',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_rounded),
            label: 'PROCESSES',
          ),
        ],
      ),
    );
  }
}

class _LocalTerminalTab extends StatefulWidget {
  const _LocalTerminalTab({required this.shell});
  final ShellService shell;

  @override
  State<_LocalTerminalTab> createState() => _LocalTerminalTabState();
}

class _LocalTerminalTabState extends State<_LocalTerminalTab> {
  late final Terminal _terminal;
  final FocusNode _focusNode = FocusNode();
  dynamic _session;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) {
      _session?.write(utf8.encode(data));
    };
    _terminal.onResize = (w, h, pw, ph) {
      _session?.resizeTerminal(w, h);
    };

    widget.shell.statusNotifier.addListener(_onStatusChanged);
    if (widget.shell.isConnected) {
      _openShell();
    }
  }

  void _onStatusChanged() {
    if (widget.shell.isConnected && _session == null) {
      _openShell();
    }
  }

  Future<void> _openShell() async {
    try {
      final dynamic session = await widget.shell.startShell(
        width: _terminal.viewWidth > 0 ? _terminal.viewWidth : 80,
        height: _terminal.viewHeight > 0 ? _terminal.viewHeight : 24,
      );

      _stdoutSub = (session.stdout as Stream<Uint8List>).listen((Uint8List data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });

      if (session is LocalShellSession) {
        _stderrSub = session.stderr.listen((Uint8List data) {
          _terminal.write(utf8.decode(data, allowMalformed: true));
        });
      }

      (session.done as Future<int>).then((int code) {
        if (mounted) {
          setState(() {
            _session = null;
          });
          _terminal.write('\r\n[PROCESS EXITED WITH CODE $code]\r\n');
        }
      });

      setState(() {
        _session = session;
      });
    } catch (e) {
      if (mounted) {
        _terminal.write('FAILED TO OPEN LOCAL SHELL: $e\r\n');
      }
    }
  }

  @override
  void dispose() {
    widget.shell.statusNotifier.removeListener(_onStatusChanged);
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _session?.close();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: TerminalView(
        _terminal,
        focusNode: _focusNode,
        autofocus: true,
        hardwareKeyboardOnly: false,
      ),
    );
  }
}
