import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';
import 'package:hamma/core/audit/execution_audit_entry.dart';
import 'package:hamma/core/audit/execution_audit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExecutionAuditEntry', () {
    test('toJson and fromJson round-trip', () {
      final now = DateTime.now();
      final entry = ExecutionAuditEntry(
        id: 'test-1',
        naturalLanguageIntent: 'list files in home directory',
        proposedCommand: 'ls -la ~/',
        riskLevel: CommandRiskLevel.low,
        approvedAt: now,
        serverId: 'server-1',
        serverName: 'My Server',
        stdout: 'total 0\ndrwxr-xr-x  2 user user 4096 Jan 1 00:00 .',
        stderr: null,
        executionDurationMs: 150,
        status: ExecutionStatus.executed,
        approvedBy: 'local_user',
      );

      final json = entry.toJson();
      final restored = ExecutionAuditEntry.fromJson(json);

      expect(restored.id, entry.id);
      expect(restored.naturalLanguageIntent, entry.naturalLanguageIntent);
      expect(restored.proposedCommand, entry.proposedCommand);
      expect(restored.riskLevel, entry.riskLevel);
      expect(
        restored.approvedAt.millisecondsSinceEpoch,
        entry.approvedAt.millisecondsSinceEpoch,
      );
      expect(restored.serverId, entry.serverId);
      expect(restored.serverName, entry.serverName);
      expect(restored.stdout, entry.stdout);
      expect(restored.stderr, entry.stderr);
      expect(restored.executionDurationMs, entry.executionDurationMs);
      expect(restored.status, entry.status);
      expect(restored.approvedBy, entry.approvedBy);
    });

    test('fromJson handles nullable fields', () {
      final json = <String, dynamic>{
        'id': 'test-2',
        'naturalLanguageIntent': 'check disk usage',
        'proposedCommand': 'df -h',
        'riskLevel': 'moderate',
        'approvedAt': DateTime.now().toUtc().toIso8601String(),
        'serverId': 'server-2',
        'serverName': 'Prod Server',
        'stdout': null,
        'stderr': null,
        'executionDurationMs': null,
        'status': 'approved',
        'approvedBy': 'local_user',
      };

      final entry = ExecutionAuditEntry.fromJson(json);
      expect(entry.stdout, isNull);
      expect(entry.stderr, isNull);
      expect(entry.executionDurationMs, isNull);
      expect(entry.status, ExecutionStatus.approved);
      expect(entry.riskLevel, CommandRiskLevel.moderate);
    });
  });

  group('ExecutionAuditService', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    ExecutionAuditEntry createEntry({
      required String id,
      String serverId = 'server-1',
      String serverName = 'Test Server',
      String command = 'ls -la',
      String intent = 'list files',
      ExecutionStatus status = ExecutionStatus.executed,
      CommandRiskLevel riskLevel = CommandRiskLevel.low,
    }) {
      return ExecutionAuditEntry(
        id: id,
        naturalLanguageIntent: intent,
        proposedCommand: command,
        riskLevel: riskLevel,
        approvedAt: DateTime.now(),
        serverId: serverId,
        serverName: serverName,
        status: status,
      );
    }

    test('logExecution stores entry and loadAll retrieves it', () async {
      final service = ExecutionAuditService();
      final entry = createEntry(id: 'entry-1');

      await service.logExecution(entry);
      final entries = await service.loadAll();

      expect(entries.length, 1);
      expect(entries.first.id, 'entry-1');
      expect(entries.first.proposedCommand, 'ls -la');
    });

    test('loadAll returns entries in reverse chronological order', () async {
      final service = ExecutionAuditService();

      await service.logExecution(createEntry(id: 'first'));
      await service.logExecution(createEntry(id: 'second'));
      await service.logExecution(createEntry(id: 'third'));

      final entries = await service.loadAll();
      expect(entries.length, 3);
      expect(entries[0].id, 'third');
      expect(entries[1].id, 'second');
      expect(entries[2].id, 'first');
    });

    test('loadByServer filters entries by serverId', () async {
      final service = ExecutionAuditService();

      await service.logExecution(
        createEntry(id: 'a', serverId: 'server-1'),
      );
      await service.logExecution(
        createEntry(id: 'b', serverId: 'server-2'),
      );
      await service.logExecution(
        createEntry(id: 'c', serverId: 'server-1'),
      );

      final results = await service.loadByServer('server-1');
      expect(results.length, 2);
      expect(results.every((e) => e.serverId == 'server-1'), isTrue);
    });

    test('search finds entries by command text', () async {
      final service = ExecutionAuditService();

      await service.logExecution(
        createEntry(id: 'x', command: 'docker ps -a'),
      );
      await service.logExecution(
        createEntry(id: 'y', command: 'ls -la'),
      );

      final results = await service.search('docker');
      expect(results.length, 1);
      expect(results.first.id, 'x');
    });

    test('search finds entries by intent text', () async {
      final service = ExecutionAuditService();

      await service.logExecution(
        createEntry(id: 'x', intent: 'restart the nginx service'),
      );
      await service.logExecution(
        createEntry(id: 'y', intent: 'list files'),
      );

      final results = await service.search('nginx');
      expect(results.length, 1);
      expect(results.first.id, 'x');
    });

    test('search is case-insensitive', () async {
      final service = ExecutionAuditService();

      await service.logExecution(
        createEntry(id: 'x', command: 'Docker Compose Up'),
      );

      final results = await service.search('docker compose');
      expect(results.length, 1);
    });

    test('trimming at 1000 entries works', () async {
      final service = ExecutionAuditService();

      for (int i = 0; i < 1050; i++) {
        await service.logExecution(createEntry(id: 'entry-$i'));
      }

      final entries = await service.loadAll();
      expect(entries.length, 1000);
      // The most recently logged entry should be first
      expect(entries.first.id, 'entry-1049');
    });

    test('deleteEntry removes specific entry', () async {
      final service = ExecutionAuditService();

      await service.logExecution(createEntry(id: 'keep-1'));
      await service.logExecution(createEntry(id: 'remove-me'));
      await service.logExecution(createEntry(id: 'keep-2'));

      await service.deleteEntry('remove-me');

      final entries = await service.loadAll();
      expect(entries.length, 2);
      expect(entries.any((e) => e.id == 'remove-me'), isFalse);
      expect(entries.any((e) => e.id == 'keep-1'), isTrue);
      expect(entries.any((e) => e.id == 'keep-2'), isTrue);
    });

    test('clearAll empties the log', () async {
      final service = ExecutionAuditService();

      await service.logExecution(createEntry(id: 'a'));
      await service.logExecution(createEntry(id: 'b'));

      await service.clearAll();

      final entries = await service.loadAll();
      expect(entries.length, 0);
    });

    test('recentEntries returns limited list', () async {
      final service = ExecutionAuditService();

      for (int i = 0; i < 100; i++) {
        await service.logExecution(createEntry(id: 'entry-$i'));
      }

      final recent = await service.recentEntries(limit: 10);
      expect(recent.length, 10);
      expect(recent.first.id, 'entry-99');
    });
  });
}
