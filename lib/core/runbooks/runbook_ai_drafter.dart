import 'dart:convert';

import '../ai/ai_command_service.dart';
import '../ai/ai_provider.dart';
import '../storage/api_key_storage.dart';
import 'runbook.dart';
import 'runbook_storage.dart';

/// Translates a free-text goal into a draft [Runbook] for review.
class RunbookAiDrafter {
  RunbookAiDrafter({
    required this.aiSettings,
    Future<String> Function(String prompt)? overrideCall,
  }) : _overrideCall = overrideCall;

  final AiSettings aiSettings;
  final Future<String> Function(String prompt)? _overrideCall;

  /// Returns a fresh-id, team:false draft. Throws
  /// [RunbookDrafterException] on non-JSON / schema-invalid output.
  Future<Runbook> draftFromGoal(String goal, {String? serverContext}) async {
    final raw = await _call(_buildPrompt(goal, serverContext));
    final json = _extractJsonObject(raw);
    if (json == null) {
      throw RunbookDrafterException(
        'Model did not return a JSON object. Got: $raw',
      );
    }
    // Force a fresh id so we never collide with an existing runbook
    // and reset team/starter regardless of what the model emitted.
    json['id'] = RunbookStorage.generateId();
    json['team'] = false;
    json['starter'] = false;
    final runbook = Runbook.fromJson(json);
    final problems = runbook.validate();
    if (problems.isNotEmpty) {
      throw RunbookDrafterException(
        'Draft failed schema validation:\n  - ${problems.join("\n  - ")}',
      );
    }
    return runbook;
  }

  Future<String> _call(String prompt) async {
    if (_overrideCall != null) return _overrideCall(prompt);
    if (!aiSettings.provider.isLocal) {
      throw const RunbookDrafterException(
        'Runbook drafting requires a local AI provider. Switch AI to '
        'Local in Settings — goals and server context are never sent '
        'to hosted providers.',
      );
    }
    final apiKey = aiSettings.apiKeys[aiSettings.provider] ?? '';
    final svc = AiCommandService.forProvider(
      provider: aiSettings.provider,
      apiKey: apiKey,
      openRouterModel: aiSettings.openRouterModel,
      localEndpoint: aiSettings.localEndpoint,
      localModel: aiSettings.localModel,
    );
    return svc.generateChatResponse(prompt);
  }

  static String _buildPrompt(String goal, String? serverContext) {
    final ctx = serverContext == null || serverContext.isEmpty
        ? ''
        : '\nTarget server context: $serverContext\n';
    return '''
You draft Hamma Runbooks. A runbook is a JSON document with this shape:

{
  "id": "rb-...",
  "name": "Short title",
  "description": "One sentence on what this does and when to use it.",
  "params": [{"name":"...", "label":"...", "defaultValue":"...", "required":true}],
  "steps": [
    {"id":"s1","label":"...","type":"command","command":"<bash>","timeoutSeconds":60,"continueOnError":false},
    {"id":"s2","label":"...","type":"promptUser","paramName":"...","question":"...","defaultValue":"..."},
    {"id":"s3","label":"...","type":"waitFor","waitMode":"time","waitSeconds":5},
    {"id":"s4","label":"...","type":"aiSummarize","aiPrompt":"Look for errors","aiReferenceStepId":"s1"},
    {"id":"s5","label":"...","type":"notify","notifyMessage":"Done"}
  ],
  "team": false
}

Rules:
- Output ONLY the JSON object, no prose, no markdown fences.
- Every step must have a unique "id" and a non-empty "label".
- Prefer LOW-risk shell commands. Avoid rm -rf, dd, mkfs, format, fdisk.
- Reference earlier output via {{step.<stepId>.stdout}} inside command strings.
- Reference user params via {{paramName}} inside command strings.
- Keep the runbook to <= 8 steps.
$ctx
Goal: $goal
''';
  }

  /// Strips ```json fences and trims to the outermost `{...}`.
  static Map<String, dynamic>? _extractJsonObject(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'^```(?:json)?', multiLine: true), '');
    s = s.replaceAll(RegExp(r'```$', multiLine: true), '');
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final candidate = s.substring(start, end + 1);
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

class RunbookDrafterException implements Exception {
  const RunbookDrafterException(this.message);
  final String message;

  @override
  String toString() => 'RunbookDrafterException: $message';
}
