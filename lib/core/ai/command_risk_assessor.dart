enum CommandRiskLevel {
  safe,
  warning,
  dangerous,
}

class CommandRiskAssessment {
  const CommandRiskAssessment({
    required this.level,
    required this.explanation,
  });

  final CommandRiskLevel level;
  final String explanation;
}

class CommandRiskAssessor {
  const CommandRiskAssessor();

  CommandRiskAssessment assess(String command) {
    final normalized = command.trim().toLowerCase();

    if (normalized.isEmpty) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.warning,
        explanation: 'Empty command. Review it before running anything.',
      );
    }

    if (_matchesAny(normalized, const ['rm -rf', ' rm -rf '])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        explanation: 'Deletes files or directories recursively and forcefully.',
      );
    }

    if (_matchesRecursivePermissionChange(normalized)) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        explanation:
            'Changes permissions or ownership recursively across many files.',
      );
    }

    if (_matchesAny(normalized, const ['reboot', 'shutdown', 'poweroff'])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        explanation: 'Restarts or powers off the server.',
      );
    }

    if (_matchesAny(normalized, const ['systemctl stop', 'service stop'])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        explanation: 'Stops a system service and may cause downtime.',
      );
    }

    if (_matchesAny(normalized, const ['docker system prune'])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        explanation: 'Removes Docker data and may delete images, caches, or containers.',
      );
    }

    if (_matchesDatabaseDestructiveCommand(normalized)) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        explanation: 'May delete, reset, or drop database data.',
      );
    }

    if (_matchesAny(normalized, const ['systemctl restart', 'service restart'])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.warning,
        explanation: 'Restarts a system service and may briefly interrupt traffic.',
      );
    }

    if (_matchesAny(normalized, const ['iptables', 'ufw', 'firewall-cmd'])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.warning,
        explanation: 'Changes firewall behavior and may affect remote access.',
      );
    }

    if (_matchesAny(normalized, const ['apt ', 'apt-get ', 'yum ', 'dnf '])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.warning,
        explanation: 'Changes installed packages or system software.',
      );
    }

    if (_matchesAny(normalized, const ['nginx -t'])) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.safe,
        explanation: 'Checks service configuration without changing server state.',
      );
    }

    if (_looksReadOnly(normalized)) {
      return const CommandRiskAssessment(
        level: CommandRiskLevel.safe,
        explanation: 'Reads system information without changing server state.',
      );
    }

    return const CommandRiskAssessment(
      level: CommandRiskLevel.warning,
      explanation: 'This command may change server state. Review it carefully.',
    );
  }

  bool _matchesAny(String command, List<String> patterns) {
    return patterns.any(command.contains);
  }

  bool _matchesRecursivePermissionChange(String command) {
    final hasRecursiveFlag = command.contains('-r') || command.contains('-R');
    final touchesPermissions =
        command.contains('chmod') || command.contains('chown');

    return hasRecursiveFlag && touchesPermissions;
  }

  bool _matchesDatabaseDestructiveCommand(String command) {
    const patterns = [
      'drop database',
      'drop table',
      'truncate table',
      'delete from',
      'mysqladmin drop',
      'mongosh --eval',
      'dropdatabase(',
      'db.dropdatabase',
      'psql -c "drop',
      "psql -c 'drop",
    ];

    return patterns.any(command.contains);
  }

  bool _looksReadOnly(String command) {
    const prefixes = [
      'top',
      'free',
      'df',
      'du',
      'uname',
      'ps',
      'cat',
      'less',
      'more',
      'tail',
      'head',
      'journalctl',
      'systemctl status',
      'docker ps',
      'docker logs',
      'ls',
      'pwd',
      'whoami',
      'uptime',
    ];

    return prefixes.any((prefix) => command.startsWith(prefix));
  }
}
