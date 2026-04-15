class QuickAction {
  const QuickAction({
    required this.id,
    required this.label,
    required this.command,
    this.isCustom = false,
  });

  final String id;
  final String label;
  final String command;
  final bool isCustom;

  factory QuickAction.fromJson(Map<String, dynamic> json) {
    final rawIsCustom = json['isCustom'];

    return QuickAction(
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      command: (json['command'] ?? '').toString(),
      isCustom: rawIsCustom is bool
          ? rawIsCustom
          : rawIsCustom?.toString().toLowerCase() == 'true',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'label': label,
      'command': command,
      'isCustom': isCustom,
    };
  }
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
