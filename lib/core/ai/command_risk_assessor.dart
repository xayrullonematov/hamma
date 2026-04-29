enum CommandRiskLevel { low, moderate, high, critical }

class CommandAnalysis {
  const CommandAnalysis({
    required this.command,
    required this.riskLevel,
    required this.explanation,
  });

  final String command;
  final CommandRiskLevel riskLevel;
  final String explanation;

  factory CommandAnalysis.fromJson(Map<String, dynamic> json) {
    return CommandAnalysis(
      command: json['command'] as String? ?? '',
      riskLevel: _parseRiskLevel(json['risk_level'] as String? ?? 'low'),
      explanation: json['explanation'] as String? ?? '',
    );
  }

  static CommandRiskLevel _parseRiskLevel(String level) {
    switch (level.toLowerCase()) {
      case 'moderate':
        return CommandRiskLevel.moderate;
      case 'high':
        return CommandRiskLevel.high;
      case 'critical':
        return CommandRiskLevel.critical;
      case 'low':
      default:
        return CommandRiskLevel.low;
    }
  }
}

class CommandRiskAssessor {
  const CommandRiskAssessor();

  static CommandRiskLevel? assessFast(String command) {
    final normalized = command.toLowerCase();
    final dangerousPatterns = [
      'rm -rf',
      'mkfs',
      'dd if=',
      'chmod -r 777',
      '> /dev/sda',
      'wget -o- | bash',
      'wget -o- | sh',
      'curl | bash',
      'curl | sh',
      ':(){ :|:& };:',
      'shred',
      'truncate',
      'passwd',
      'userdel',
      'crontab -r',
      'iptables -f',
      'ufw disable',
      'systemctl disable',
      'chmod -r 000',
    ];

    for (final pattern in dangerousPatterns) {
      if (normalized.contains(pattern)) {
        return CommandRiskLevel.critical;
      }
    }

    return null;
  }

  CommandAnalysis assess(String command) {
    final fast = assessFast(command);
    if (fast != null) {
      return CommandAnalysis(
        command: command,
        riskLevel: fast,
        explanation: 'Dangerous pattern detected in the command.',
      );
    }

    final normalized = command.trim().toLowerCase();
    if (normalized.isEmpty) {
      return CommandAnalysis(
        command: command,
        riskLevel: CommandRiskLevel.moderate,
        explanation: 'Empty command. Review it before running anything.',
      );
    }

    if (normalized.contains('sudo') || 
        normalized.contains('systemctl') || 
        normalized.contains('apt') ||
        normalized.contains('chmod') ||
        normalized.contains('chown')) {
      return CommandAnalysis(
        command: command,
        riskLevel: CommandRiskLevel.moderate,
        explanation: 'Command requires elevated privileges or changes system state.',
      );
    }

    return CommandAnalysis(
      command: command,
      riskLevel: CommandRiskLevel.low,
      explanation: 'Command appears to be low risk.',
    );
  }
}
