import 'package:meta/meta.dart';

/// Discriminator for [RunbookStep].
enum RunbookStepType {
  command('command'),
  promptUser('prompt-user'),
  waitFor('wait-for'),
  branch('branch'),
  aiSummarize('ai-summarize'),
  notify('notify');

  const RunbookStepType(this.wireName);

  /// Hyphenated JSON discriminator (camelCase enum name also accepted
  /// for back-compat).
  final String wireName;

  static RunbookStepType? tryParse(String raw) {
    for (final v in RunbookStepType.values) {
      if (v.wireName == raw || v.name == raw) return v;
    }
    return null;
  }
}

/// A user-supplied parameter, interpolated into commands as `{{name}}`.
@immutable
class RunbookParam {
  const RunbookParam({
    required this.name,
    required this.label,
    this.defaultValue,
    this.required = false,
  });

  final String name;
  final String label;
  final String? defaultValue;
  final bool required;

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        if (defaultValue != null) 'defaultValue': defaultValue,
        'required': required,
      };

  factory RunbookParam.fromJson(Map<String, dynamic> json) => RunbookParam(
        name: (json['name'] ?? '').toString(),
        label: (json['label'] ?? json['name'] ?? '').toString(),
        defaultValue: json['defaultValue']?.toString(),
        required: json['required'] == true,
      );
}

/// One node in a runbook. Flat record keyed by [type].
@immutable
class RunbookStep {
  const RunbookStep({
    required this.id,
    required this.label,
    required this.type,
    this.command,
    this.timeoutSeconds,
    this.continueOnError = false,
    this.skipIfRegex,
    this.skipIfReferenceStepId,
    this.paramName,
    this.question,
    this.defaultValue,
    this.waitMode,
    this.waitSeconds,
    this.waitRegex,
    this.waitReferenceStepId,
    this.aiPrompt,
    this.aiReferenceStepId,
    this.notifyMessage,
    this.branchRegex,
    this.branchReferenceStepId,
    this.branchTrueGoToStepId,
    this.branchFalseGoToStepId,
  });

  final String id;
  final String label;
  final RunbookStepType type;

  // command
  final String? command;
  final int? timeoutSeconds;
  final bool continueOnError;

  // conditional skip applied to ANY step type
  final String? skipIfRegex;
  final String? skipIfReferenceStepId;

  // promptUser
  final String? paramName;
  final String? question;
  final String? defaultValue;

  // waitFor
  final String? waitMode; // 'time' | 'regex' | 'manual'
  final int? waitSeconds;
  final String? waitRegex;
  final String? waitReferenceStepId;

  // aiSummarize
  final String? aiPrompt;
  final String? aiReferenceStepId;

  // notify
  final String? notifyMessage;

  // branch — evaluates [branchRegex] (multiline) against the stdout
  // of [branchReferenceStepId] (or the previous step if unset). On
  // match the runner jumps to [branchTrueGoToStepId]; otherwise it
  // jumps to [branchFalseGoToStepId]. A null target falls through
  // to the next step in the list, so a one-armed `if` is a single
  // jump target with the other left null.
  final String? branchRegex;
  final String? branchReferenceStepId;
  final String? branchTrueGoToStepId;
  final String? branchFalseGoToStepId;

  RunbookStep copyWith({
    String? id,
    String? label,
    RunbookStepType? type,
    String? command,
    int? timeoutSeconds,
    bool? continueOnError,
    String? skipIfRegex,
    String? skipIfReferenceStepId,
    String? paramName,
    String? question,
    String? defaultValue,
    String? waitMode,
    int? waitSeconds,
    String? waitRegex,
    String? waitReferenceStepId,
    String? aiPrompt,
    String? aiReferenceStepId,
    String? notifyMessage,
    String? branchRegex,
    String? branchReferenceStepId,
    String? branchTrueGoToStepId,
    String? branchFalseGoToStepId,
  }) {
    return RunbookStep(
      id: id ?? this.id,
      label: label ?? this.label,
      type: type ?? this.type,
      command: command ?? this.command,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      continueOnError: continueOnError ?? this.continueOnError,
      skipIfRegex: skipIfRegex ?? this.skipIfRegex,
      skipIfReferenceStepId:
          skipIfReferenceStepId ?? this.skipIfReferenceStepId,
      paramName: paramName ?? this.paramName,
      question: question ?? this.question,
      defaultValue: defaultValue ?? this.defaultValue,
      waitMode: waitMode ?? this.waitMode,
      waitSeconds: waitSeconds ?? this.waitSeconds,
      waitRegex: waitRegex ?? this.waitRegex,
      waitReferenceStepId: waitReferenceStepId ?? this.waitReferenceStepId,
      aiPrompt: aiPrompt ?? this.aiPrompt,
      aiReferenceStepId: aiReferenceStepId ?? this.aiReferenceStepId,
      notifyMessage: notifyMessage ?? this.notifyMessage,
      branchRegex: branchRegex ?? this.branchRegex,
      branchReferenceStepId:
          branchReferenceStepId ?? this.branchReferenceStepId,
      branchTrueGoToStepId:
          branchTrueGoToStepId ?? this.branchTrueGoToStepId,
      branchFalseGoToStepId:
          branchFalseGoToStepId ?? this.branchFalseGoToStepId,
    );
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'label': label,
      'type': type.wireName,
      'continueOnError': continueOnError,
    };
    void put(String k, Object? v) {
      if (v == null) return;
      out[k] = v;
    }

    put('command', command);
    put('timeoutSeconds', timeoutSeconds);
    put('skipIfRegex', skipIfRegex);
    put('skipIfReferenceStepId', skipIfReferenceStepId);
    put('paramName', paramName);
    put('question', question);
    put('defaultValue', defaultValue);
    put('waitMode', waitMode);
    put('waitSeconds', waitSeconds);
    put('waitRegex', waitRegex);
    put('waitReferenceStepId', waitReferenceStepId);
    put('aiPrompt', aiPrompt);
    put('aiReferenceStepId', aiReferenceStepId);
    put('notifyMessage', notifyMessage);
    put('branchRegex', branchRegex);
    put('branchReferenceStepId', branchReferenceStepId);
    put('branchTrueGoToStepId', branchTrueGoToStepId);
    put('branchFalseGoToStepId', branchFalseGoToStepId);
    return out;
  }

  factory RunbookStep.fromJson(Map<String, dynamic> json) {
    final typeRaw = (json['type'] ?? '').toString();
    final type = RunbookStepType.tryParse(typeRaw);
    if (type == null) {
      throw RunbookSchemaException(
        'Unknown step type "$typeRaw" (allowed: '
        '${RunbookStepType.values.map((e) => e.name).join(", ")}).',
      );
    }
    return RunbookStep(
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      type: type,
      command: json['command']?.toString(),
      timeoutSeconds: _toInt(json['timeoutSeconds']),
      continueOnError: json['continueOnError'] == true,
      skipIfRegex: json['skipIfRegex']?.toString(),
      skipIfReferenceStepId: json['skipIfReferenceStepId']?.toString(),
      paramName: json['paramName']?.toString(),
      question: json['question']?.toString(),
      defaultValue: json['defaultValue']?.toString(),
      waitMode: json['waitMode']?.toString(),
      waitSeconds: _toInt(json['waitSeconds']),
      waitRegex: json['waitRegex']?.toString(),
      waitReferenceStepId: json['waitReferenceStepId']?.toString(),
      aiPrompt: json['aiPrompt']?.toString(),
      aiReferenceStepId: json['aiReferenceStepId']?.toString(),
      notifyMessage: json['notifyMessage']?.toString(),
      branchRegex: json['branchRegex']?.toString(),
      branchReferenceStepId: json['branchReferenceStepId']?.toString(),
      branchTrueGoToStepId: json['branchTrueGoToStepId']?.toString(),
      branchFalseGoToStepId: json['branchFalseGoToStepId']?.toString(),
    );
  }

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }
}

/// A persisted runbook.
@immutable
class Runbook {
  const Runbook({
    required this.id,
    required this.name,
    this.description = '',
    this.params = const [],
    this.steps = const [],
    this.serverId,
    this.team = false,
    this.starter = false,
  });

  /// Stable id; sync uses it as the merge key.
  final String id;

  final String name;
  final String description;
  final List<RunbookParam> params;
  final List<RunbookStep> steps;

  /// `null` = global; otherwise pinned to a server profile.
  final String? serverId;

  /// Eligible for cross-device sync. Opt-in.
  final bool team;

  /// Read-only entries from the starter pack.
  final bool starter;

  Runbook copyWith({
    String? id,
    String? name,
    String? description,
    List<RunbookParam>? params,
    List<RunbookStep>? steps,
    String? serverId,
    bool? team,
    bool? starter,
    bool clearServerId = false,
  }) {
    return Runbook(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      params: params ?? this.params,
      steps: steps ?? this.steps,
      serverId: clearServerId ? null : (serverId ?? this.serverId),
      team: team ?? this.team,
      starter: starter ?? this.starter,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'params': params.map((p) => p.toJson()).toList(),
        'steps': steps.map((s) => s.toJson()).toList(),
        if (serverId != null) 'serverId': serverId,
        'team': team,
        'starter': starter,
      };

  factory Runbook.fromJson(Map<String, dynamic> json) {
    final paramsRaw = json['params'];
    final stepsRaw = json['steps'];
    if (stepsRaw is! List) {
      throw const RunbookSchemaException(
        'Runbook is missing a "steps" array.',
      );
    }
    final steps = <RunbookStep>[];
    for (final raw in stepsRaw) {
      if (raw is! Map) {
        throw const RunbookSchemaException(
          'Each step must be a JSON object.',
        );
      }
      steps.add(RunbookStep.fromJson(Map<String, dynamic>.from(raw)));
    }
    final params = <RunbookParam>[];
    if (paramsRaw is List) {
      for (final raw in paramsRaw) {
        if (raw is Map) {
          params.add(RunbookParam.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }
    return Runbook(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      params: params,
      steps: steps,
      serverId: json['serverId']?.toString(),
      team: json['team'] == true,
      starter: json['starter'] == true,
    );
  }

  /// Returns validation problems; empty list = safe to run.
  List<String> validate() {
    final problems = <String>[];
    if (id.trim().isEmpty) problems.add('id is required.');
    if (name.trim().isEmpty) problems.add('name is required.');
    if (steps.isEmpty) problems.add('runbook must have at least one step.');

    final seenStepIds = <String>{};
    final seenParamNames = <String>{};
    for (final p in params) {
      if (p.name.trim().isEmpty) {
        problems.add('parameter is missing "name".');
        continue;
      }
      if (!seenParamNames.add(p.name)) {
        problems.add('duplicate parameter "${p.name}".');
      }
    }

    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final tag = 'step #${i + 1} (${s.id})';
      if (s.id.trim().isEmpty) {
        problems.add('step #${i + 1}: id is required.');
      } else if (!seenStepIds.add(s.id)) {
        problems.add('$tag: duplicate step id.');
      }
      if (s.label.trim().isEmpty) problems.add('$tag: label is required.');

      switch (s.type) {
        case RunbookStepType.command:
          if ((s.command ?? '').trim().isEmpty) {
            problems.add('$tag: command step needs a non-empty "command".');
          }
          if (s.timeoutSeconds != null && s.timeoutSeconds! <= 0) {
            problems.add('$tag: timeoutSeconds must be > 0 when set.');
          }
          break;
        case RunbookStepType.promptUser:
          if ((s.paramName ?? '').trim().isEmpty) {
            problems.add('$tag: promptUser step needs "paramName".');
          }
          if ((s.question ?? '').trim().isEmpty) {
            problems.add('$tag: promptUser step needs "question".');
          }
          break;
        case RunbookStepType.waitFor:
          final mode = s.waitMode ?? '';
          if (!_validWaitModes.contains(mode)) {
            problems.add(
              '$tag: waitFor step needs waitMode in '
              '${_validWaitModes.join(", ")}.',
            );
          }
          if (mode == 'time' &&
              (s.waitSeconds == null || s.waitSeconds! <= 0)) {
            problems.add('$tag: waitFor time mode needs waitSeconds > 0.');
          }
          if (mode == 'regex') {
            if ((s.waitRegex ?? '').isEmpty) {
              problems.add('$tag: waitFor regex mode needs waitRegex.');
            } else {
              try {
                RegExp(s.waitRegex!);
              } catch (_) {
                problems.add('$tag: waitRegex is not a valid regex.');
              }
            }
          }
          break;
        case RunbookStepType.aiSummarize:
          // Both fields are optional — defaults to the previous step.
          break;
        case RunbookStepType.notify:
          if ((s.notifyMessage ?? '').trim().isEmpty) {
            problems.add('$tag: notify step needs notifyMessage.');
          }
          break;
        case RunbookStepType.branch:
          final bre = s.branchRegex ?? '';
          if (bre.isEmpty) {
            problems.add('$tag: branch step needs branchRegex.');
          } else {
            try {
              RegExp(bre);
            } catch (_) {
              problems.add('$tag: branchRegex is not a valid regex.');
            }
          }
          if ((s.branchTrueGoToStepId ?? '').isEmpty &&
              (s.branchFalseGoToStepId ?? '').isEmpty) {
            problems.add(
              '$tag: branch needs branchTrueGoToStepId or '
              'branchFalseGoToStepId (otherwise the branch is a no-op).',
            );
          }
          break;
      }

      if (s.skipIfRegex != null) {
        try {
          RegExp(s.skipIfRegex!);
        } catch (_) {
          problems.add('$tag: skipIfRegex is not a valid regex.');
        }
      }

      // Cross-step references must point to an EARLIER step that
      // actually exists. The runner is linear, so a forward
      // reference can never resolve. Catching this at validation
      // time means AI-drafted runbooks fail loudly at the editor
      // gate rather than silently degrading at runtime.
      final earlierIds =
          steps.take(i).map((e) => e.id).toSet();
      void checkRef(String? refId, String fieldName) {
        if (refId == null || refId.isEmpty) return;
        if (!earlierIds.contains(refId)) {
          problems.add(
            '$tag: $fieldName "$refId" does not match any earlier step id.',
          );
        }
      }

      checkRef(s.skipIfReferenceStepId, 'skipIfReferenceStepId');
      checkRef(s.waitReferenceStepId, 'waitReferenceStepId');
      checkRef(s.aiReferenceStepId, 'aiReferenceStepId');
      checkRef(s.branchReferenceStepId, 'branchReferenceStepId');

      // Branch jump targets may point FORWARD as well as backward
      // (an if/else can skip ahead) so they only need to refer to
      // some real step id anywhere in the runbook.
      final allIds = steps.map((e) => e.id).toSet();
      void checkJump(String? id, String fieldName) {
        if (id == null || id.isEmpty) return;
        if (!allIds.contains(id)) {
          problems.add(
            '$tag: $fieldName "$id" does not match any step id in this runbook.',
          );
        }
      }

      checkJump(s.branchTrueGoToStepId, 'branchTrueGoToStepId');
      checkJump(s.branchFalseGoToStepId, 'branchFalseGoToStepId');
    }

    return problems;
  }

  static const _validWaitModes = {'time', 'regex', 'manual'};
}

class RunbookSchemaException implements Exception {
  const RunbookSchemaException(this.message);
  final String message;

  @override
  String toString() => 'RunbookSchemaException: $message';
}
