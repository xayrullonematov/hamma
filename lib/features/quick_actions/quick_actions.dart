class QuickAction {
  const QuickAction({
    required this.id,
    required this.label,
    required this.command,
  });

  final String id;
  final String label;
  final String command;
}

const List<QuickAction> kQuickActions = [
  QuickAction(
    id: 'restart-server',
    label: 'Restart Server',
    command: 'sudo reboot',
  ),
  QuickAction(
    id: 'system-info',
    label: 'Check System Info',
    command: 'uname -a',
  ),
  QuickAction(
    id: 'disk-usage',
    label: 'Check Disk Usage',
    command: 'df -h',
  ),
  QuickAction(
    id: 'running-processes',
    label: 'Check Running Processes',
    command: 'ps aux | head -20',
  ),
];
