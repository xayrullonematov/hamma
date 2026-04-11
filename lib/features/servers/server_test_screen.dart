import 'package:flutter/material.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/ssh_service.dart';
import '../ai_assistant/ai_assistant_screen.dart';
import '../quick_actions/quick_actions.dart';
import '../settings/settings_screen.dart';
import '../terminal/terminal_test_command.dart';
import '../terminal/terminal_screen.dart';

class ServerTestScreen extends StatefulWidget {
  const ServerTestScreen({
    super.key,
    required this.server,
    required this.apiKey,
    required this.onSaveApiKey,
  });

  final ServerProfile server;
  final String apiKey;
  final Future<void> Function(String apiKey) onSaveApiKey;

  @override
  State<ServerTestScreen> createState() => _ServerTestScreenState();
}

class _ServerTestScreenState extends State<ServerTestScreen> {
  final SshService _sshService = SshService();
  late String _apiKey;

  bool _isBusy = false;
  String? _activeQuickActionId;
  String _status = 'Not connected';
  String _output = 'Press Connect to start managing this server.';

  ServerProfile get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _apiKey = widget.apiKey;
  }

  @override
  void didUpdateWidget(covariant ServerTestScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey) {
      _apiKey = widget.apiKey;
    }
  }

  @override
  void dispose() {
    _sshService.disconnect();
    super.dispose();
  }

  Future<void> _saveApiKey(String apiKey) async {
    await widget.onSaveApiKey(apiKey);
    if (!mounted) {
      return;
    }

    setState(() {
      _apiKey = apiKey;
    });
  }

  Future<void> _connect() async {
    if (!_server.isValid) {
      setState(() {
        _status = 'Saved server profile is incomplete';
        _output = 'Edit this server from the saved servers list and try again.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _status = 'Connecting to ${_server.host}:${_server.port}';
      _output = '';
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
        _status = 'Connected to ${_server.name}';
        _output = 'Connection established. Press "Run Test Command" to execute '
            '`$kTerminalTestCommand`.';
      });
    } catch (error) {
      setState(() {
        _status = 'Connection failed';
        _output = error.toString();
      });
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  Future<void> _runTestCommand() async {
    setState(() {
      _isBusy = true;
      _status = 'Running `$kTerminalTestCommand`';
    });

    try {
      final output = await _sshService.execute(kTerminalTestCommand);
      setState(() {
        _status = 'Command finished';
        _output = output.isEmpty ? '(no output)' : output;
      });
    } catch (error) {
      await _handleExecutionError(
        failureStatus: 'Command failed',
        error: error,
      );
    } finally {
      setState(() {
        _isBusy = false;
      });
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
        _status = '"${action.label}" finished';
        _output = output.isEmpty ? '(no output)' : output;
      });
    } catch (error) {
      await _handleExecutionError(
        failureStatus: '"${action.label}" failed',
        error: error,
      );
    } finally {
      setState(() {
        _isBusy = false;
        _activeQuickActionId = null;
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

  Future<void> _handleExecutionError({
    required String failureStatus,
    required Object error,
  }) async {
    final message = error.toString();
    if (_looksLikeDisconnect(message)) {
      await _sshService.disconnect();
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'SSH connection lost. Reconnect to continue.';
        _output = message;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _status = failureStatus;
      _output = message;
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
          initialApiKey: _apiKey,
          onSaveApiKey: _saveApiKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            Text(_status, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _isBusy ? null : _connect,
              child: const Text('Connect'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed:
                  _isBusy || !_sshService.isConnected ? null : _runTestCommand,
              child: const Text('Run Test Command'),
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
                      _output,
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
