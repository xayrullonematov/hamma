import 'package:flutter/material.dart';

import '../../core/ssh/ssh_service.dart';
import '../../core/theme/app_colors.dart';

class PortForwardingSheet extends StatefulWidget {
  const PortForwardingSheet({super.key, required this.sshService});

  final SshService sshService;

  @override
  State<PortForwardingSheet> createState() => _PortForwardingSheetState();
}

class _PortForwardingSheetState extends State<PortForwardingSheet> {
  static const _sheetBackground = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _primaryColor = AppColors.textPrimary;
  static const _mutedColor = AppColors.textMuted;
  static const _shadowColor = Color(0x22000000);

  late final TextEditingController _localPortController;
  late final TextEditingController _targetHostController;
  late final TextEditingController _targetPortController;

  bool _isStarting = false;
  int? _stoppingPort;

  List<int> get _activePorts {
    final ports = widget.sshService.activeForwardedPorts.toList()..sort();
    return ports;
  }

  @override
  void initState() {
    super.initState();
    _localPortController = TextEditingController();
    _targetHostController = TextEditingController(text: 'localhost');
    _targetPortController = TextEditingController();
  }

  @override
  void dispose() {
    _localPortController.dispose();
    _targetHostController.dispose();
    _targetPortController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  BoxDecoration _surfaceDecoration() {
    return BoxDecoration(
      color: _surfaceColor,
      borderRadius: BorderRadius.zero,
      boxShadow: const [
        BoxShadow(color: _shadowColor, blurRadius: 20, offset: Offset(0, 10)),
      ],
    );
  }

  Future<void> _startForwarding() async {
    final localPort = int.tryParse(_localPortController.text.trim());
    final targetHost = _targetHostController.text.trim();
    final targetPort = int.tryParse(_targetPortController.text.trim());

    if (localPort == null || localPort <= 0 || localPort > 65535) {
      _showMessage('Enter a valid local port between 1 and 65535.');
      return;
    }
    if (targetHost.isEmpty) {
      _showMessage('Enter a target host.');
      return;
    }
    if (targetPort == null || targetPort <= 0 || targetPort > 65535) {
      _showMessage('Enter a valid target port between 1 and 65535.');
      return;
    }

    setState(() {
      _isStarting = true;
    });

    try {
      await widget.sshService.startLocalForwarding(
        localPort: localPort,
        remoteHost: targetHost,
        remotePort: targetPort,
      );
      if (!mounted) {
        return;
      }

      setState(() {});
      _showMessage('Forwarding started on 127.0.0.1:$localPort.');
    } catch (error) {
      if (!mounted) {
        return;
      }

      _showMessage(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isStarting = false;
        });
      }
    }
  }

  Future<void> _stopForwarding(int localPort) async {
    setState(() {
      _stoppingPort = localPort;
    });

    try {
      await widget.sshService.stopLocalForwarding(localPort);
      if (!mounted) {
        return;
      }

      setState(() {});
      _showMessage('Forwarding stopped on 127.0.0.1:$localPort.');
    } catch (error) {
      if (!mounted) {
        return;
      }

      _showMessage(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _stoppingPort = null;
        });
      }
    }
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      decoration: _surfaceDecoration(),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Port Forwarding',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tunnel remote ports to this device through the active SSH session.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _mutedColor,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _panelColor,
                  borderRadius: BorderRadius.zero,
                ),
                child: Text(
                  widget.sshService.isConnected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    color:
                        widget.sshService.isConnected
                            ? AppColors.textPrimary
                            : _mutedColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _localPortController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Local Port',
              hintText: '8080',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetHostController,
            decoration: const InputDecoration(
              labelText: 'Target Host',
              hintText: 'localhost',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetPortController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Target Port',
              hintText: '5432',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  _isStarting || !widget.sshService.isConnected
                      ? null
                      : _startForwarding,
              icon:
                  _isStarting
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.router_outlined),
              label: Text(
                _isStarting ? 'Starting Forwarding' : 'Start Forwarding',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveForwards(ThemeData theme) {
    final activePorts = _activePorts;
    if (activePorts.isEmpty) {
      return Container(
        decoration: _surfaceDecoration(),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.router_outlined, size: 36, color: _mutedColor),
            const SizedBox(height: 14),
            Text(
              'No active forwarded ports',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start a new tunnel above to expose a remote service on this device\'s localhost.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _mutedColor,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: _surfaceDecoration(),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: activePorts.length,
        itemBuilder: (context, index) {
          final port = activePorts[index];
          final isStopping = _stoppingPort == port;

          return ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _primaryColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.zero,
              ),
              child: const Icon(Icons.router_outlined, color: _primaryColor),
            ),
            title: Text(
              '127.0.0.1:$port',
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              'Listening locally on port $port',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _mutedColor,
                height: 1.4,
              ),
            ),
            trailing: TextButton(
              onPressed: isStopping ? null : () => _stopForwarding(port),
              child:
                  isStopping
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Text('Stop'),
            ),
          );
        },
        separatorBuilder: (context, _) {
          return Divider(
            color: Colors.white.withValues(alpha: 0.06),
            height: 1,
            indent: 20,
            endIndent: 20,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: _sheetBackground,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _mutedColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.zero,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildHeader(theme),
              const SizedBox(height: 16),
              Text(
                'Active Tunnels',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildActiveForwards(theme)),
            ],
          ),
        ),
      ),
    );
  }
}
