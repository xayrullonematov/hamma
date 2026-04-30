import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';

void main() {
  const assessor = CommandRiskAssessor();

  // ── CommandAnalysis.fromJson ───────────────────────────────────────────────

  group('CommandAnalysis.fromJson', () {
    test('parses low risk correctly', () {
      final analysis = CommandAnalysis.fromJson({
        'command': 'ls -la',
        'risk_level': 'low',
        'explanation': 'Read-only listing',
      });
      expect(analysis.command, 'ls -la');
      expect(analysis.riskLevel, CommandRiskLevel.low);
      expect(analysis.explanation, 'Read-only listing');
    });

    test('parses moderate risk correctly', () {
      final analysis = CommandAnalysis.fromJson({
        'command': 'sudo systemctl restart nginx',
        'risk_level': 'moderate',
        'explanation': 'Restarts a service',
      });
      expect(analysis.riskLevel, CommandRiskLevel.moderate);
    });

    test('parses high risk correctly', () {
      final analysis = CommandAnalysis.fromJson({
        'command': 'chmod 777 /etc',
        'risk_level': 'high',
        'explanation': 'Broad permissions',
      });
      expect(analysis.riskLevel, CommandRiskLevel.high);
    });

    test('parses critical risk correctly', () {
      final analysis = CommandAnalysis.fromJson({
        'command': 'rm -rf /',
        'risk_level': 'critical',
        'explanation': 'Destroys system',
      });
      expect(analysis.riskLevel, CommandRiskLevel.critical);
    });

    test('defaults to low for unknown risk_level string', () {
      final analysis = CommandAnalysis.fromJson({
        'command': 'ls',
        'risk_level': 'unknown_level',
        'explanation': '',
      });
      expect(analysis.riskLevel, CommandRiskLevel.low);
    });

    test('risk_level parsing is case-insensitive', () {
      final analysis = CommandAnalysis.fromJson({
        'command': 'ls',
        'risk_level': 'CRITICAL',
        'explanation': '',
      });
      expect(analysis.riskLevel, CommandRiskLevel.critical);
    });

    test('defaults command and explanation to empty string when absent', () {
      final analysis = CommandAnalysis.fromJson({});
      expect(analysis.command, '');
      expect(analysis.explanation, '');
    });
  });

  // ── CommandRiskAssessor.assessFast ────────────────────────────────────────

  group('CommandRiskAssessor.assessFast — dangerous patterns', () {
    final dangerousCmds = [
      'rm -rf /',
      'rm -rf *',
      'mkfs.ext4 /dev/sda',
      'dd if=/dev/zero of=/dev/sda',
      'shred /dev/sda',
      'truncate -s 0 /etc/passwd',
      'passwd root',
      'userdel admin',
      'crontab -r',
      'iptables -f',
      'ufw disable',
      'systemctl disable ssh',
      'chmod -r 000 /',
      'curl | bash',
      'curl | sh',
      'wget -o- | bash',
      ':(){ :|:& };:',
    ];

    for (final cmd in dangerousCmds) {
      test('"$cmd" is classified as critical', () {
        expect(CommandRiskAssessor.assessFast(cmd), CommandRiskLevel.critical);
      });
    }

    test('returns null for a safe read-only command', () {
      expect(CommandRiskAssessor.assessFast('ls -la'), isNull);
    });

    test('returns null for a common diagnostic command', () {
      expect(CommandRiskAssessor.assessFast('df -h'), isNull);
    });

    test('pattern matching is case-insensitive', () {
      expect(CommandRiskAssessor.assessFast('RM -RF /'), CommandRiskLevel.critical);
    });
  });

  // ── CommandRiskAssessor.assess — full classification ──────────────────────

  group('CommandRiskAssessor.assess — low risk commands', () {
    final lowRiskCmds = [
      'df -h',
      'ls -la',
      'ps aux',
      'uptime',
      'who',
      'cat /etc/hostname',
      'uname -a',
      'free -m',
      'top -bn1',
      'netstat -tulpn',
    ];

    for (final cmd in lowRiskCmds) {
      test('"$cmd" is low risk', () {
        expect(assessor.assess(cmd).riskLevel, CommandRiskLevel.low);
      });
    }
  });

  group('CommandRiskAssessor.assess — moderate risk commands', () {
    final moderateCmds = [
      'sudo systemctl restart nginx',
      'sudo apt update',
      'chmod 644 /etc/config',
      'chown www-data /var/www',
      'sudo reboot',
    ];

    for (final cmd in moderateCmds) {
      test('"$cmd" is moderate risk', () {
        expect(assessor.assess(cmd).riskLevel, CommandRiskLevel.moderate);
      });
    }
  });

  group('CommandRiskAssessor.assess — critical risk commands', () {
    final criticalCmds = [
      'rm -rf /',
      'dd if=/dev/zero of=/dev/sda',
      'mkfs.ext4 /dev/sda',
      'shred /dev/sda1',
    ];

    for (final cmd in criticalCmds) {
      test('"$cmd" is critical risk', () {
        expect(assessor.assess(cmd).riskLevel, CommandRiskLevel.critical);
      });
    }
  });

  group('CommandRiskAssessor.assess — empty command', () {
    test('empty string is classified as moderate (review required)', () {
      expect(assessor.assess('').riskLevel, CommandRiskLevel.moderate);
    });

    test('whitespace-only command is classified as moderate', () {
      expect(assessor.assess('   ').riskLevel, CommandRiskLevel.moderate);
    });
  });

  group('CommandRiskAssessor.assess — explanation field', () {
    test('dangerous command explanation mentions "Dangerous pattern"', () {
      final result = assessor.assess('rm -rf /');
      expect(result.explanation.toLowerCase(), contains('dangerous'));
    });

    test('low risk command explanation is non-empty', () {
      final result = assessor.assess('df -h');
      expect(result.explanation, isNotEmpty);
    });

    test('moderate risk command explanation is non-empty', () {
      final result = assessor.assess('sudo apt update');
      expect(result.explanation, isNotEmpty);
    });
  });

  group('CommandRiskAssessor.assess — command field preserved', () {
    test('command field on result matches input', () {
      const cmd = 'cat /etc/os-release';
      final result = assessor.assess(cmd);
      expect(result.command, cmd);
    });
  });

  // ── CommandRiskLevel enum ─────────────────────────────────────────────────

  group('CommandRiskLevel enum', () {
    test('contains four levels', () {
      expect(CommandRiskLevel.values, hasLength(4));
    });

    test('natural ordering is low < moderate < high < critical', () {
      expect(
        CommandRiskLevel.values.map((e) => e.name),
        ['low', 'moderate', 'high', 'critical'],
      );
    });
  });
}
