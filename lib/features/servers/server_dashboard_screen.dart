import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models/server_profile.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/custom_actions_storage.dart';
import '../ai_assistant/ai_copilot_sheet.dart';
import '../quick_actions/custom_actions_screen.dart';
import '../quick_actions/quick_actions.dart';
import '../sftp/file_explorer_screen.dart';
import '../settings/settings_screen.dart';
import '../terminal/terminal_screen.dart';

class ServerDashboardScreen extends StatefulWidget {
  const ServerDashboardScreen({
    super.key,
    required this.server,
    required this.aiProvider,
    required this.apiKey,
    required this.openRouterModel,
    required this.onSaveAiSettings,
    this.onBackupImported,
  });

  final ServerProfile server;
  final AiProvider aiProvider;
  final String apiKey;
  final String? openRouterModel;
  final Future<void> Function(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
  )
  onSaveAiSettings;
  final Future<void> Function()? onBackupImported;

  @override
  State<ServerDashboardScreen> createState() => _ServerDashboardScreenState();
}

class _ServerDashboardScreenState extends State<ServerDashboardScreen> {
  static const _connectionTestCommand = 'uname -a';
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _terminalColor = Color(0xFF0B1120);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _slateColor = Color(0xFF64748B);
  static const _successColor = Color(0xFF22C55E);
  static const _dangerColor = Color(0xFFEF4444);
  static const _shadowColor = Color(0x22000000);

  final SshService _sshService = SshService();
  final CustomActionsStorage _customActionsStorage =
      const CustomActionsStorage();
  late AiProvider _aiProvider;
  late String _apiKey;
  late String? _openRouterModel;

  bool _isBusy = false;
  bool _isShowingMessage = false;
  String? _activeQuickActionId;
  String? _status;
  String _quickActionOutput = 'Quick action results will appear here.';
  ConnectionTestState _connectionTestState = ConnectionTestState.idle;
  List<QuickAction> _customQuickActions = const [];

  ServerProfile get _server => widget.server;
  List<QuickAction> get _allQuickActions => [
    ...kQuickActions,
    ..._customQuickActions,
  ];

  @override
  void initState() {
    super.initState();
    _aiProvider = widget.aiProvider;
    _apiKey = widget.apiKey;
    _openRouterModel = widget.openRouterModel;
    _loadCustomQuickActions();
  }

  @override
  void didUpdateWidget(covariant ServerDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aiProvider != widget.aiProvider) {
      _aiProvider = widget.aiProvider;
    }
    if (oldWidget.apiKey != widget.apiKey) {
      _apiKey = widget.apiKey;
    }
    if (oldWidget.openRouterModel != widget.openRouterModel) {
      _openRouterModel = widget.openRouterModel;
    }
  }

  @override
  void dispose() {
    _sshService.disconnect();
    super.dispose();
  }

  Future<void> _saveAiSettings(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
  ) async {
    await widget.onSaveAiSettings(provider, apiKey, openRouterModel);
    if (!mounted) {
      return;
    }

    setState(() {
      _aiProvider = provider;
      _apiKey = apiKey;
      _openRouterModel = openRouterModel;
    });
  }

  Future<void> _connect() async {
    if (!_server.isValid) {
      _showMessage('Saved server profile is incomplete');
      setState(() {
        _status = null;
        _connectionTestState = ConnectionTestState.failed;
      });
      return;
    }

    final buttonLabel = _sshService.isConnected ? 'Reconnecting' : 'Connecting';

    setState(() {
      _isBusy = true;
      _status = '$buttonLabel to ${_server.host}:${_server.port}';
      _connectionTestState = ConnectionTestState.idle;
    });

    try {
      await _sshService.connect(
        host: _server.host,
        port: _server.port,
        username: _server.username,
        password: _server.password,
        privateKey: _server.privateKey,
        onTrustHostKey: _confirmHostKeyTrust,
      );

      setState(() {
        _status = null;
        _connectionTestState = ConnectionTestState.idle;
      });
    } catch (error) {
      _showMessage(error.toString());
      setState(() {
        _status = null;
        _connectionTestState = ConnectionTestState.failed;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _runConnectionTest() async {
    setState(() {
      _isBusy = true;
      _status = 'Running connection test';
    });

    try {
      await _sshService.execute(_connectionTestCommand);
      setState(() {
        _status = null;
        _connectionTestState = ConnectionTestState.connected;
      });
    } catch (error) {
      final message = error.toString();
      if (_looksLikeDisconnect(message)) {
        await _sshService.disconnect();
      }
      _showMessage(message);

      if (!mounted) {
        return;
      }

      setState(() {
        _status = null;
        _connectionTestState = ConnectionTestState.failed;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _runQuickAction(QuickAction action) async {
    if (_isDestructiveQuickAction(action)) {
      final confirmed = await _confirmDestructiveQuickAction(action);
      if (!confirmed) {
        return;
      }
    }

    setState(() {
      _isBusy = true;
      _activeQuickActionId = action.id;
      _status = 'Running "${action.label}"';
    });

    try {
      final output = await _sshService.execute(action.command);
      setState(() {
        _status = null;
        _quickActionOutput = output.isEmpty ? '(no output)' : output;
      });
    } catch (error) {
      await _handleQuickActionError(error: error);
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _activeQuickActionId = null;
        });
      }
    }
  }

  Future<void> _loadCustomQuickActions() async {
    try {
      final actions = await _customActionsStorage.loadActions();
      if (!mounted) {
        return;
      }

      setState(() {
        _customQuickActions = actions;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showMessage(error.toString());
        }
      });
    }
  }

  Future<bool> _confirmHostKeyTrust({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Trust SSH Host Key'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('First connection to $host:$port'),
                  const SizedBox(height: 12),
                  Text('Algorithm: $algorithm'),
                  const SizedBox(height: 8),
                  SelectableText('Fingerprint: $fingerprint'),
                  const SizedBox(height: 12),
                  const Text(
                    'Only trust this key if you have verified it with your server provider or the server itself.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Trust'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  bool _isDestructiveQuickAction(QuickAction action) {
    return action.id == 'restart-server';
  }

  Future<bool> _confirmDestructiveQuickAction(QuickAction action) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(action.label),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Command: ${action.command}'),
                  const SizedBox(height: 12),
                  const Text(
                    'This will restart the server and may disconnect your session immediately.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Run'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> _handleQuickActionError({required Object error}) async {
    final message = error.toString();
    if (_looksLikeDisconnect(message)) {
      await _sshService.disconnect();
      if (!mounted) {
        return;
      }

      setState(() {
        _status = null;
        _connectionTestState = ConnectionTestState.failed;
        _quickActionOutput = message;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _status = null;
      _quickActionOutput = message;
    });
  }

  bool _looksLikeDisconnect(String message) {
    final normalized = message.toLowerCase();
    const patterns = [
      'not connected',
      'connection reset',
      'broken pipe',
      'socketexception',
      'connection closed',
      'channel is not open',
      'failed host handshake',
    ];

    return patterns.any(normalized.contains);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => SettingsScreen(
              initialProvider: _aiProvider,
              initialApiKey: _apiKey,
              initialOpenRouterModel: _openRouterModel,
              onSaveAiSettings: _saveAiSettings,
              onBackupImported: widget.onBackupImported,
            ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted || message.trim().isEmpty || _isShowingMessage) {
      return;
    }

    _isShowingMessage = true;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message))).closed.then((_) {
      _isShowingMessage = false;
    });
  }

  String _getDashboardCopilotContext() {
    final parts = <String>[
      'Server: ${_server.name}',
      'Host: ${_server.host}:${_server.port}',
      'User: ${_server.username}',
      'Connection state: ${_sshService.isConnected ? 'connected' : 'disconnected'}',
    ];

    if (_status != null && _status!.trim().isNotEmpty) {
      parts.add('Dashboard status: ${_status!.trim()}');
    }

    final quickActionOutput = _quickActionOutput.trim();
    if (quickActionOutput.isNotEmpty &&
        quickActionOutput != 'Quick action results will appear here.') {
      parts.add('Last quick action output:\n$quickActionOutput');
    }

    return parts.join('\n\n');
  }

  Future<String?> _runCopilotCommand(String command) async {
    if (!_sshService.isConnected) {
      throw StateError(
        'SSH is disconnected. Reconnect before running commands.',
      );
    }

    try {
      final output = await _sshService.execute(command);
      if (!mounted) {
        return output;
      }

      setState(() {
        _status = null;
        _quickActionOutput = output.isEmpty ? '(no output)' : output;
      });

      return output;
    } catch (error) {
      final message = error.toString();
      if (_looksLikeDisconnect(message)) {
        await _sshService.disconnect();
        if (mounted) {
          setState(() {
            _status = null;
            _connectionTestState = ConnectionTestState.failed;
          });
        }
      }
      rethrow;
    }
  }

  Future<void> _openCopilot() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) {
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: AiCopilotSheet(
            serverId: _server.id,
            provider: _aiProvider,
            apiKey: _apiKey,
            openRouterModel: _openRouterModel,
            executionTarget: AiCopilotExecutionTarget.dashboard,
            canRunCommands: () => _sshService.isConnected,
            getContext: _getDashboardCopilotContext,
            onRunCommand: _runCopilotCommand,
            executionUnavailableMessage:
                'SSH is disconnected. Reconnect before running commands.',
          ),
        );
      },
    );
  }

  String _displayStatus() {
    if (_status != null && _status!.isNotEmpty) {
      return _status!;
    }

    switch (_connectionTestState) {
      case ConnectionTestState.idle:
        return _sshService.isConnected
            ? 'SSH session is open. Run a connection test to verify the session.'
            : 'Connect to enable terminal, AI, and quick actions.';
      case ConnectionTestState.connected:
        return 'SSH verified and ready for server actions.';
      case ConnectionTestState.failed:
        return 'Connection failed. Reconnect and try again.';
    }
  }

  Color _connectionBadgeColor() {
    if (_connectionTestState == ConnectionTestState.failed) {
      return _dangerColor;
    }
    if (_sshService.isConnected) {
      return _successColor;
    }
    return _slateColor;
  }

  String _connectionBadgeLabel() {
    if (_connectionTestState == ConnectionTestState.failed) {
      return 'Failed';
    }
    if (_sshService.isConnected) {
      return 'Connected';
    }
    return 'Untested';
  }

  IconData _connectionBadgeIcon() {
    if (_connectionTestState == ConnectionTestState.failed) {
      return Icons.error_outline_rounded;
    }
    if (_sshService.isConnected) {
      return Icons.cloud_done_outlined;
    }
    return Icons.shield_outlined;
  }

  IconData _quickActionIcon(String actionId) {
    final customAction = _allQuickActions.where(
      (action) => action.id == actionId,
    );
    if (customAction.isNotEmpty && customAction.first.isCustom) {
      return Icons.terminal_rounded;
    }

    switch (actionId) {
      case 'restart-server':
        return Icons.restart_alt_rounded;
      case 'system-info':
        return Icons.memory_rounded;
      case 'disk-usage':
        return Icons.storage_rounded;
      case 'running-processes':
        return Icons.view_list_rounded;
      default:
        return Icons.terminal_rounded;
    }
  }

  Future<void> _openCustomActions() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CustomActionsScreen()),
    );

    if (!mounted) {
      return;
    }

    await _loadCustomQuickActions();
  }

  void _openTerminal() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => TerminalScreen(
              sshService: _sshService,
              serverName: _server.name,
              aiProvider: _aiProvider,
              apiKey: _apiKey,
              openRouterModel: _openRouterModel,
            ),
      ),
    );
  }

  void _openFileExplorer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileExplorerScreen(server: _server),
      ),
    );
  }

  BoxDecoration _sectionDecoration() {
    return BoxDecoration(
      color: _surfaceColor,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(color: _shadowColor, blurRadius: 18, offset: Offset(0, 10)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connectButtonLabel =
        _sshService.isConnected ? 'Reconnect' : 'Connect';

    return Scaffold(
      appBar: AppBar(
        title: Text(_server.name),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: _sectionDecoration(),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: _connectionBadgeColor().withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(
                          _connectionBadgeIcon(),
                          color: _connectionBadgeColor(),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _server.name,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${_server.username}@${_server.host}:${_server.port}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _mutedColor,
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _connectionBadgeColor().withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _connectionBadgeColor(),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _connectionBadgeLabel(),
                              style: TextStyle(
                                color: _connectionBadgeColor(),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _panelColor,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      _displayStatus(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed:
                          _isBusy || !_sshService.isConnected
                              ? null
                              : _runConnectionTest,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('Connection Test'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: _sectionDecoration(),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Main Actions', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isBusy ? null : _connect,
                          icon: const Icon(Icons.power_settings_new_rounded),
                          label: Text(connectButtonLabel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              _isBusy || !_sshService.isConnected
                                  ? null
                                  : _openTerminal,
                          icon: const Icon(Icons.terminal_rounded),
                          label: const Text('Open Terminal'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isBusy ? null : _openCopilot,
                          icon: const Icon(Icons.smart_toy_outlined),
                          label: const Text('AI Assistant'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isBusy ? null : _openFileExplorer,
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('File Explorer'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isBusy ? null : _openSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Settings'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: _sectionDecoration(),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Quick Actions', style: theme.textTheme.titleMedium),
                      const Spacer(),
                      IconButton(
                        onPressed: _isBusy ? null : _openCustomActions,
                        icon: const Icon(Icons.edit_note_rounded),
                        tooltip: 'Manage custom actions',
                      ),
                      Text(
                        _sshService.isConnected ? 'Live SSH' : 'Disconnected',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _mutedColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _allQuickActions.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.24,
                        ),
                    itemBuilder: (context, index) {
                      final action = _allQuickActions[index];
                      final isRunning = _activeQuickActionId == action.id;
                      final isEnabled = !_isBusy && _sshService.isConnected;

                      return _QuickActionTile(
                        label: action.label,
                        command: action.command,
                        icon: _quickActionIcon(action.id),
                        isRunning: isRunning,
                        isEnabled: isEnabled,
                        onTap: isEnabled ? () => _runQuickAction(action) : null,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: _sectionDecoration(),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick Action Output',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: _terminalColor,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            color: Color(0xFF020617),
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          child: Row(
                            children: [
                              const _TerminalDot(color: Color(0xFFEF4444)),
                              const SizedBox(width: 8),
                              const _TerminalDot(color: Color(0xFFF59E0B)),
                              const SizedBox(width: 8),
                              const _TerminalDot(color: Color(0xFF22C55E)),
                              const SizedBox(width: 12),
                              Text(
                                'terminal-output',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _mutedColor,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 280,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                _quickActionOutput,
                                style: const TextStyle(
                                  color: Color(0xFFE2E8F0),
                                  fontFamily: 'monospace',
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.label,
    required this.command,
    required this.icon,
    required this.isRunning,
    required this.isEnabled,
    required this.onTap,
  });

  final String label;
  final String command;
  final IconData icon;
  final bool isRunning;
  final bool isEnabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: isEnabled || isRunning ? 1 : 0.58,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            decoration: BoxDecoration(
              color: _ServerDashboardScreenState._panelColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child:
                        isRunning
                            ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : Icon(icon, color: const Color(0xFF3B82F6)),
                  ),
                  const Spacer(),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    command,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _ServerDashboardScreenState._mutedColor,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalDot extends StatelessWidget {
  const _TerminalDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

enum ConnectionTestState { idle, connected, failed }
