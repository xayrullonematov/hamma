import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';
import 'package:hamma/core/audit/execution_audit_entry.dart';
import 'package:hamma/core/audit/execution_audit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Execution Audit Integration', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('logging an execution persists all fields correctly', () async {
      final service = ExecutionAuditService();
      final now = DateTime.now();

      final entry = ExecutionAuditEntry(
        id: 'test_001',
        naturalLanguageIntent: 'Check disk usage',
        proposedCommand: 'df -h',
        riskLevel: CommandRiskLevel.low,
        approvedAt: now,
        serverId: 'server_abc',
        serverName: 'My Server',
        stdout: '/dev/sda1  50G  20G  30G  40%',
        stderr: null,
        executionDurationMs: 150,
        status: ExecutionStatus.executed,
      );

      await service.logExecution(entry);

      final entries = await service.loadAll();
      expect(entries, hasLength(1));
      expect(entries.first.id, 'test_001');
      expect(entries.first.naturalLanguageIntent, 'Check disk usage');
      expect(entries.first.proposedCommand, 'df -h');
      expect(entries.first.riskLevel, CommandRiskLevel.low);
      expect(entries.first.serverId, 'server_abc');
      expect(entries.first.serverName, 'My Server');
      expect(entries.first.stdout, '/dev/sda1  50G  20G  30G  40%');
      expect(entries.first.stderr, isNull);
      expect(entries.first.executionDurationMs, 150);
      expect(entries.first.status, ExecutionStatus.executed);
    });

    test('failed execution is logged with stderr and failed status', () async {
      final service = ExecutionAuditService();
      final now = DateTime.now();

      final entry = ExecutionAuditEntry(
        id: 'test_fail_001',
        naturalLanguageIntent: 'Restart nginx',
        proposedCommand: 'systemctl restart nginx',
        riskLevel: CommandRiskLevel.high,
        approvedAt: now,
        serverId: 'server_xyz',
        serverName: 'Production',
        stdout: null,
        stderr: 'Permission denied',
        executionDurationMs: 42,
        status: ExecutionStatus.failed,
      );

      await service.logExecution(entry);

      final entries = await service.loadAll();
      expect(entries, hasLength(1));
      expect(entries.first.status, ExecutionStatus.failed);
      expect(entries.first.stderr, 'Permission denied');
      expect(entries.first.riskLevel, CommandRiskLevel.high);
    });

    test('multiple executions are stored in reverse chronological order', () async {
      final service = ExecutionAuditService();

      for (int i = 0; i < 5; i++) {
        await service.logExecution(ExecutionAuditEntry(
          id: 'cmd_$i',
          naturalLanguageIntent: 'Task $i',
          proposedCommand: 'echo $i',
          riskLevel: CommandRiskLevel.low,
          approvedAt: DateTime.now().add(Duration(seconds: i)),
          serverId: 'server_1',
          serverName: 'TestServer',
          stdout: '$i',
          executionDurationMs: 10 + i,
          status: ExecutionStatus.executed,
        ));
      }

      final entries = await service.loadAll();
      expect(entries, hasLength(5));
      // newest first (last inserted is at index 0)
      expect(entries.first.id, 'cmd_4');
      expect(entries.last.id, 'cmd_0');
    });

    test('loadByServer filters entries by serverId', () async {
      final service = ExecutionAuditService();
      final now = DateTime.now();

      await service.logExecution(ExecutionAuditEntry(
        id: 'entry_a',
        naturalLanguageIntent: 'Task A',
        proposedCommand: 'ls',
        riskLevel: CommandRiskLevel.low,
        approvedAt: now,
        serverId: 'server_alpha',
        serverName: 'Alpha',
        status: ExecutionStatus.executed,
      ));

      await service.logExecution(ExecutionAuditEntry(
        id: 'entry_b',
        naturalLanguageIntent: 'Task B',
        proposedCommand: 'pwd',
        riskLevel: CommandRiskLevel.low,
        approvedAt: now,
        serverId: 'server_beta',
        serverName: 'Beta',
        status: ExecutionStatus.executed,
      ));

      await service.logExecution(ExecutionAuditEntry(
        id: 'entry_c',
        naturalLanguageIntent: 'Task C',
        proposedCommand: 'uptime',
        riskLevel: CommandRiskLevel.moderate,
        approvedAt: now,
        serverId: 'server_alpha',
        serverName: 'Alpha',
        status: ExecutionStatus.executed,
      ));

      final alphaEntries = await service.loadByServer('server_alpha');
      expect(alphaEntries, hasLength(2));
      expect(alphaEntries.every((e) => e.serverId == 'server_alpha'), isTrue);

      final betaEntries = await service.loadByServer('server_beta');
      expect(betaEntries, hasLength(1));
      expect(betaEntries.first.id, 'entry_b');
    });

    test('search finds entries by command text and intent', () async {
      final service = ExecutionAuditService();
      final now = DateTime.now();

      await service.logExecution(ExecutionAuditEntry(
        id: 'search_1',
        naturalLanguageIntent: 'Check disk space',
        proposedCommand: 'df -h',
        riskLevel: CommandRiskLevel.low,
        approvedAt: now,
        serverId: 'srv1',
        serverName: 'Srv',
        status: ExecutionStatus.executed,
      ));

      await service.logExecution(ExecutionAuditEntry(
        id: 'search_2',
        naturalLanguageIntent: 'List Docker containers',
        proposedCommand: 'docker ps -a',
        riskLevel: CommandRiskLevel.moderate,
        approvedAt: now,
        serverId: 'srv1',
        serverName: 'Srv',
        status: ExecutionStatus.executed,
      ));

      // Search by command
      final dockerResults = await service.search('docker');
      expect(dockerResults, hasLength(1));
      expect(dockerResults.first.id, 'search_2');

      // Search by intent
      final diskResults = await service.search('disk');
      expect(diskResults, hasLength(1));
      expect(diskResults.first.id, 'search_1');

      // Case-insensitive search
      final upperResults = await service.search('DOCKER');
      expect(upperResults, hasLength(1));
    });

    test('execution entry includes timing data for duration measurement', () async {
      final service = ExecutionAuditService();
      final startTime = DateTime.now();

      // Simulate a command that takes some time
      final entry = ExecutionAuditEntry(
        id: 'timed_cmd',
        naturalLanguageIntent: 'Monitor CPU usage',
        proposedCommand: 'top -bn1',
        riskLevel: CommandRiskLevel.low,
        approvedAt: startTime,
        serverId: 'server_1',
        serverName: 'Server 1',
        stdout: 'CPU: 45%',
        executionDurationMs: 2500,
        status: ExecutionStatus.executed,
      );

      await service.logExecution(entry);

      final entries = await service.loadAll();
      expect(entries.first.executionDurationMs, 2500);
      expect(entries.first.approvedAt.millisecondsSinceEpoch,
          startTime.millisecondsSinceEpoch);
    });

    test('risk level is correctly persisted through audit flow', () async {
      final service = ExecutionAuditService();
      final now = DateTime.now();

      final levels = CommandRiskLevel.values;
      for (final level in levels) {
        await service.logExecution(ExecutionAuditEntry(
          id: 'risk_${level.name}',
          naturalLanguageIntent: 'Command at ${level.name} risk',
          proposedCommand: 'cmd_${level.name}',
          riskLevel: level,
          approvedAt: now,
          serverId: 'srv',
          serverName: 'Srv',
          status: ExecutionStatus.executed,
        ));
      }

      final entries = await service.loadAll();
      expect(entries, hasLength(levels.length));

      for (final level in levels) {
        final matching = entries.where((e) => e.id == 'risk_${level.name}');
        expect(matching, hasLength(1));
        expect(matching.first.riskLevel, level);
      }
    });
  });
}
