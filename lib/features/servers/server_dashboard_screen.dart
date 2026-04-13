import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models/server_profile.dart';
import '../../core/ssh/ssh_service.dart';
import '../ai_assistant/ai_assistant_screen.dart';
import '../quick_actions/quick_actions.dart';
import '../settings/settings_screen.dart';
import '../terminal/terminal_screen.dart';

class ServerDashboardScreen extends StatefulWidget {
  const ServerDashboardScreen({
    super.key,
    required this.server,
    required this.aiProvider,
    required this.apiKey,
    required this.onSaveAiSettings,
  });

  final ServerProfile server;
  final AiProvider aiProvider;
  final String apiKey;
  final Future<void> Function(AiProvider provider, String apiKey)
      onSaveAiSettings;

  @override
  State<ServerDashboardScreen> createState() => _ServerDashboardScreenState();
}

class _ServerDashboardScreenState extends State<ServerDashboardScreen> {
  static const _connectionTestCommand = 'uname -a';

  final SshService _sshService = SshService();
  late AiProvider _aiProvider;
  late String _apiKey;

  bool _isBusy = false;
  bool _isShowingMessage = false; // Fix 2: snackbar spam guard
  String? _activeQuickActionId;
  String? _status;
  String _quickActionOutput = 'Quick action results will appear here.';
  ConnectionTestState _connectionTestState = ConnectionTestState.idle;

  ServerProfile get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _aiProvider = widget.aiProvider;
    _apiKey = widget.apiKey;
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
  }

  @override
  void dispose() {
    _sshService.disconnect();
    super.dispose();
  }

  Future<void> _saveAiSettings(AiProvider provider, String apiKey) async {
    await widget.onSaveAiSettings(provider, apiKey);
    if (!mounted) {
      return;
    }

    setState(() {
      _aiProvider = provider;
      _apiKey = apiKey;
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

  Future<void> _handleQuickActionError({
    required Object error,
  }) async {
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
        builder: (_) => SettingsScreen(
          initialProvider: _aiProvider,
          initialApiKey: _apiKey,
          onSaveAiSettings: _saveAiSettings,
        ),
      ),
    );
  }

  // Fix 2: debounced snackbar — no spam on repeated failures
  void _showMessage(String message) {
    if (!mounted || message.trim().isEmpty || _isShowingMessage) {
      return;
    }

    _isShowingMessage = true;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)))
        .closed
        .then((_) {
      _isShowingMessage = false;
    });
  }

  // Fix 1: reflect connected state even before a test is run
  String _displayStatus() {
    if (_status != null && _status!.isNotEmpty) {
      return _status!;
    }

    switch (_connectionTestState) {
      case ConnectionTestState.idle:
        return _sshService.isConnected
            ? 'Connected (not verified)'
            : 'Connection not tested';
      case ConnectionTestState.connected:
        return 'Connection verified';
      case ConnectionTestState.failed:
        return 'Connection failed';
    }
  }

  Color _connectionBadgeColor(BuildContext context) {
    switch (_connectionTestState) {
      case ConnectionTestState.idle:
        return Theme.of(context).colorScheme.secondary;
      case ConnectionTestState.connected:
        return Colors.green.shade700;
      case ConnectionTestState.failed:
        return Colors.red.shade700;
    }
  }

  String _connectionBadgeLabel() {
    switch (_connectionTestState) {
      case ConnectionTestState.idle:
        return 'Not Tested';
      case ConnectionTestState.connected:
        return 'Connected';
      case ConnectionTestState.failed:
        return 'Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connectButtonLabel = _sshService.isConnected ? 'Reconnect' : 'Connect';

    return Scaffold(
      appBar: AppBar(
        title: Text(_server.name),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_server.username}@${_server.host}:${_server.port}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(_displayStatus(), style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _isBusy ? null : _connect,
              child: Text(connectButtonLabel),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _isBusy || !_sshService.isConnected ? null : _runConnectionTest,
                    child: const Text('Connection Test'),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _connectionBadgeColor(context).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _connectionBadgeLabel(),
                    style: TextStyle(
                      color: _connectionBadgeColor(context),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _isBusy || !_sshService.isConnected
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => TerminalScreen(
                            sshService: _sshService,
                            serverName: _server.name,
                            aiProvider: _aiProvider,
                            apiKey: _apiKey,
                          ),
                        ),
                      );
                    },
              child: const Text('Open Terminal'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _isBusy
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AiAssistantScreen(
                            sshService: _sshService,
                            provider: _aiProvider,
                            apiKey: _apiKey,
                          ),
                        ),
                      );
                    },
              child: const Text('AI Assistant'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _isBusy ? null : _openSettings,
              child: const Text('Settings'),
            ),
            const SizedBox(height: 20),
            Text('Quick Actions', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: kQuickActions.map((action) {
                final isRunning = _activeQuickActionId == action.id;

                return SizedBox(
                  width: 180,
                  child: OutlinedButton(
                    onPressed: _isBusy || !_sshService.isConnected
                        ? null
                        : () => _runQuickAction(action),
                    child: isRunning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(action.label),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Text('Quick Action Output', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _quickActionOutput,
                      style: const TextStyle(
                        color: Color(0xFFE2E8F0),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum ConnectionTestState {
  idle,
  connected,
  failed,
}
