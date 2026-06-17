import '../ai/command_risk_assessor.dart';

enum ExecutionStatus { approved, executed, failed }

class ExecutionAuditEntry {
  final String id;
  final String naturalLanguageIntent;
  final String proposedCommand;
  final CommandRiskLevel riskLevel;
  final DateTime approvedAt;
  final String serverId;
  final String serverName;
  final String? stdout;
  final String? stderr;
  final int? executionDurationMs;
  final ExecutionStatus status;
  final String approvedBy;

  const ExecutionAuditEntry({
    required this.id,
    required this.naturalLanguageIntent,
    required this.proposedCommand,
    required this.riskLevel,
    required this.approvedAt,
    required this.serverId,
    required this.serverName,
    this.stdout,
    this.stderr,
    this.executionDurationMs,
    required this.status,
    this.approvedBy = 'local_user',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'naturalLanguageIntent': naturalLanguageIntent,
        'proposedCommand': proposedCommand,
        'riskLevel': riskLevel.name,
        'approvedAt': approvedAt.toUtc().toIso8601String(),
        'serverId': serverId,
        'serverName': serverName,
        'stdout': stdout,
        'stderr': stderr,
        'executionDurationMs': executionDurationMs,
        'status': status.name,
        'approvedBy': approvedBy,
      };

  factory ExecutionAuditEntry.fromJson(Map<String, dynamic> json) {
    return ExecutionAuditEntry(
      id: (json['id'] ?? '').toString(),
      naturalLanguageIntent:
          (json['naturalLanguageIntent'] ?? '').toString(),
      proposedCommand: (json['proposedCommand'] ?? '').toString(),
      riskLevel: CommandRiskLevel.values.firstWhere(
        (e) => e.name == json['riskLevel'],
        orElse: () => CommandRiskLevel.low,
      ),
      approvedAt:
          DateTime.tryParse((json['approvedAt'] ?? '').toString())?.toLocal() ??
              DateTime.now(),
      serverId: (json['serverId'] ?? '').toString(),
      serverName: (json['serverName'] ?? '').toString(),
      stdout: json['stdout']?.toString(),
      stderr: json['stderr']?.toString(),
      executionDurationMs: json['executionDurationMs'] as int?,
      status: ExecutionStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ExecutionStatus.approved,
      ),
      approvedBy: (json['approvedBy'] ?? 'local_user').toString(),
    );
  }
}
