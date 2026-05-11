import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../../core/theme/app_colors.dart';

class _AiCli {
  const _AiCli({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.command,
    required this.installCommand,
    required this.checkCommand,
    required this.accentColor,
  });
  final String id;
  final String name;
  final String subtitle;
  final String command;
  final String installCommand;
  final String checkCommand;
  final Color accentColor;
}

class AiCliScreen extends StatefulWidget {
  const AiCliScreen({super.key});

  @override
  State<AiCliScreen> createState() => _AiCliScreenState();
}

class _AiCliScreenState extends State<AiCliScreen> {
  static const _clis = [
    _AiCli(
      id: 'claude',
      name: 'Claude Code',
      subtitle: 'Anthropic · claude',
      command: 'claude',
      installCommand: 'npm install -g @anthropic-ai/claude-code',
      checkCommand: 'claude --version',
      accentColor: Color(0xFFCC785C),
    ),
    _AiCli(
      id: 'codex',
      name: 'Codex CLI',
      subtitle: 'OpenAI · codex',
      command: 'codex',
      installCommand: 'npm install -g @openai/codex',
      checkCommand: 'codex --version',
      accentColor: Color(0xFF10A37F),
    ),
    _AiCli(
      id: 'gemini',
      name: 'Gemini CLI',
      subtitle: 'Google · gemini',
      command: 'gemini',
      installCommand: 'npm install -g @google/gemini-cli',
      checkCommand: 'gemini --version',
      accentColor: Color(0xFF4285F4),
    ),
  ];

  final Map<String, bool> _installed = {};
  bool _isChecking = true;
  String? _activeCliId;
  final TextEditingController _dirController = TextEditingController();
  late String _workingDir;

  @override
  void initState() {
    super.initState();
    _workingDir = Platform.environment['HOME'] ?? 
                 Platform.environment['USERPROFILE'] ?? 
                 'C:\\Users\\User';
    _dirController.text = _workingDir;
    _checkAllInstalled();
  }

  @override
  void dispose() {
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _checkAllInstalled() async {
    for (final cli in _clis) {
      try {
        final result = await Process.run(
          cli.checkCommand.split(' ').first,
          [cli.checkCommand.split(' ').last],
          runInShell: true,
        );
        _installed[cli.id] = result.exitCode == 0;
      } catch (_) {
        _installed[cli.id] = false;
      }
    }
    if (mounted) {
      setState(() {
        _isChecking = false;
      });
    }
  }

  Future<void> _launch(_AiCli cli) async {
    final dir = _dirController.text.trim();
    if (!Directory(dir).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('DIRECTORY DOES NOT EXIST')),
      );
      return;
    }

    if (_installed[cli.id] != true) {
      setState(() => _activeCliId = cli.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('INSTALLING ${cli.name.toUpperCase()}...')),
      );

      try {
        final installResult = await (Platform.isWindows
            ? Process.run('cmd', ['/c', cli.installCommand], runInShell: false, workingDirectory: dir)
            : Process.run('/bin/sh', ['-c', cli.installCommand], runInShell: false, workingDirectory: dir));

        if (installResult.exitCode != 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('INSTALLATION FAILED: ${installResult.stderr}')),
            );
            setState(() => _activeCliId = null);
          }
          return;
        }
        _installed[cli.id] = true;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ERROR: $e')),
          );
          setState(() => _activeCliId = null);
        }
        return;
      }
    }

    if (!mounted) return;
    setState(() => _activeCliId = null);

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AiCliTerminalScreen(
          cli: cli,
          workingDirectory: dir,
        ),
      ),
    );
  }

  void _showPathDialog() {
    final controller = TextEditingController(text: _dirController.text);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: const Text('MANUAL PATH ENTRY', style: TextStyle(fontFamily: AppColors.monoFamily, fontSize: 14)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontFamily: AppColors.monoFamily, color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: AppColors.accent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _dirController.text = controller.text;
              });
              Navigator.pop(context);
            },
            child: const Text('SET', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'AI CLI LAUNCHER',
          style: TextStyle(
            fontFamily: AppColors.monoFamily,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WORKING DIRECTORY',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 11,
                    color: AppColors.textMuted,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _dirController,
                        style: const TextStyle(fontFamily: AppColors.monoFamily, color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          hintText: 'Enter directory path...',
                          hintStyle: TextStyle(color: AppColors.textFaint),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.zero,
                            borderSide: BorderSide(color: AppColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.zero,
                            borderSide: BorderSide(color: AppColors.accent),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.border),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.folder_open, color: AppColors.textMuted),
                        onPressed: _showPathDialog,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 16),
          if (_isChecking)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.textPrimary),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _clis.length,
                itemBuilder: (context, index) => _buildCliCard(_clis[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCliCard(_AiCli cli) {
    final isActive = _activeCliId == cli.id;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: isActive ? cli.accentColor : AppColors.border,
          width: isActive ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: isActive ? null : () => _launch(cli),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: cli.accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.zero,
                ),
                child: Icon(Icons.terminal_rounded, color: cli.accentColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          cli.name.toUpperCase(),
                          style: const TextStyle(
                            fontFamily: AppColors.monoFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        _buildStatusBadge(cli),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      cli.subtitle,
                      style: const TextStyle(
                        fontFamily: AppColors.sansFamily,
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _installed[cli.id] == true
                          ? 'TAP TO LAUNCH IN SELECTED DIRECTORY'
                          : 'TAP TO INSTALL & LAUNCH',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                        fontFamily: AppColors.monoFamily,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(_AiCli cli) {
    final isInstalled = _installed[cli.id] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (isInstalled ? AppColors.accent : AppColors.textMuted).withValues(alpha: 0.15),
        border: Border.all(color: isInstalled ? AppColors.accent : AppColors.border, width: 1),
      ),
      child: Text(
        isInstalled ? 'INSTALLED' : 'NOT INSTALLED',
        style: TextStyle(
          fontFamily: AppColors.monoFamily,
          fontSize: 9,
          color: isInstalled ? AppColors.accent : AppColors.textMuted,
          letterSpacing: 1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AiCliTerminalScreen extends StatefulWidget {
  const _AiCliTerminalScreen({
    required this.cli,
    required this.workingDirectory,
  });

  final _AiCli cli;
  final String workingDirectory;

  @override
  State<_AiCliTerminalScreen> createState() => _AiCliTerminalScreenState();
}

class _AiCliTerminalScreenState extends State<_AiCliTerminalScreen> {
  late final Terminal _terminal;
  final FocusNode _focusNode = FocusNode();
  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) {
      _process?.stdin.write(utf8.encode(data));
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startProcess();
    });
  }

  Future<void> _startProcess() async {
    try {
      _process = await Process.start(
        widget.cli.command,
        [],
        workingDirectory: widget.workingDirectory,
        runInShell: true,
        environment: Platform.environment,
      );

      _stdoutSub = _process!.stdout.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });
      _stderrSub = _process!.stderr.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });

      _process!.exitCode.then((code) {
        if (mounted) {
          setState(() {
            _terminal.write('\r\n[PROCESS EXITED WITH CODE $code]\r\n');
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _terminal.write('\r\n[ERROR STARTING PROCESS: $e]\r\n');
        });
      }
    }
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _process?.kill();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        title: Text(
          '${widget.cli.name.toUpperCase()} — ${widget.workingDirectory}',
          style: const TextStyle(fontFamily: AppColors.monoFamily, fontSize: 13),
        ),
      ),
      body: TerminalView(
        _terminal,
        focusNode: _focusNode,
        autofocus: true,
        hardwareKeyboardOnly: false,
      ),
    );
  }
}
