import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/command_risk_assessor.dart';
import '../../core/runbooks/runbook.dart';
import '../../core/runbooks/runbook_runner.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/storage/custom_actions_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../features/quick_actions/quick_actions.dart';

/// Live progress view for a single runbook execution.
///
/// Step rows show green/amber/red status, collapsible stdout, AI
/// summary callouts, and a big STOP button at the bottom. The
/// post-run summary screen offers a one-tap "Save outputs as snippet"
/// that wraps the rendered commands as a [QuickAction].
class RunbookRunScreen extends StatefulWidget {
  const RunbookRunScreen({
    super.key,
    required this.runbook,
    required this.sshService,
    required this.aiSettings,
  });

  final Runbook runbook;
  final SshService sshService;
  final AiSettings aiSettings;

  @override
  State<RunbookRunScreen> createState() => _RunbookRunScreenState();
}

class _RunbookRunScreenState extends State<RunbookRunScreen> {
  RunbookRunner? _runner;
  StreamSubscription<RunbookEvent>? _eventSub;

  /// Collected param values, seeded from defaults and updated by
  /// `promptUser` steps.
  late Map<String, String> _params;

  /// Current state of each step row, by step id.
  final Map<String, _StepRow> _rows = {};

  bool _running = false;
  bool _paramsCollected = false;
  RunbookRunResult? _result;

  @override
  void initState() {
    super.initState();
    _params = {
      for (final p in widget.runbook.params) p.name: p.defaultValue ?? '',
    };
    for (final s in widget.runbook.steps) {
      _rows[s.id] = _StepRow(step: s);
    }
  }

  @override
  void dispose() {
    // Cancel any in-flight runner so leaving this screen doesn't
    // leave an SSH command stream firing into a disposed listener.
    _runner?.cancellation.cancel();
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _collectParamsAndStart() async {
    if (widget.runbook.params.isNotEmpty) {
      final ok = await _showParamsDialog();
      if (ok != true) return;
    }
    _paramsCollected = true;
    _start();
  }

  Future<bool?> _showParamsDialog() async {
    final controllers = {
      for (final p in widget.runbook.params)
        p.name: TextEditingController(text: _params[p.name] ?? ''),
    };
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('RUN PARAMETERS'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in widget.runbook.params)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: TextField(
                    controller: controllers[p.name],
                    decoration: InputDecoration(
                      labelText: p.label,
                      hintText: p.required ? 'required' : 'optional',
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () {
              for (final p in widget.runbook.params) {
                _params[p.name] = controllers[p.name]!.text;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('RUN'),
          ),
        ],
      ),
    );
  }

  void _start() {
    final runner = RunbookRunner(
      runbook: widget.runbook,
      params: _params,
      executeCommand: widget.sshService.execute,
      aiSettings: widget.aiSettings,
      confirmRiskGate: _confirmRiskGate,
      promptUser: _promptUser,
      confirmManualWait: _confirmManualWait,
    );
    _runner = runner;
    setState(() => _running = true);
    _eventSub = runner.events.listen(_onEvent, onDone: () {
      if (mounted) setState(() => _running = false);
    });
    runner.run().then((result) {
      if (!mounted) return;
      setState(() => _result = result);
    });
  }

  void _stop() {
    _runner?.cancellation.cancel();
  }

  Future<bool> _confirmRiskGate(
    RunbookStep step,
    String renderedCommand,
    CommandAnalysis analysis,
  ) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('RISK GATE — ${analysis.riskLevel.name.toUpperCase()}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.label),
              const SizedBox(height: 8),
              SelectableText(
                renderedCommand,
                style: const TextStyle(
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              Text(analysis.explanation),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ABORT'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('PROCEED'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<String?> _promptUser(RunbookStep step, String? defaultValue) async {
    final ctrl = TextEditingController(text: defaultValue ?? '');
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(step.label),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: step.question),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmManualWait(RunbookStep step) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(step.label),
        content: const Text('Manual gate — continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ABORT'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('CONTINUE'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _onEvent(RunbookEvent event) {
    if (!mounted) return;
    setState(() {
      if (event is StepStarted) {
        _rows[event.step.id]?.status = _RowStatus.running;
      } else if (event is StepStdout) {
        _rows[event.step.id]?.stdout = event.chunk;
      } else if (event is StepNotify) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(event.message)),
        );
      } else if (event is StepFinished) {
        final r = _rows[event.result.step.id];
        if (r == null) return;
        r.status = switch (event.result.status) {
          RunbookStepStatus.succeeded => _RowStatus.succeeded,
          RunbookStepStatus.skipped => _RowStatus.skipped,
          RunbookStepStatus.cancelled => _RowStatus.cancelled,
          RunbookStepStatus.failed => _RowStatus.failed,
        };
        if (event.result.stdout.isNotEmpty) r.stdout = event.result.stdout;
        if (event.result.summary.isNotEmpty) r.summary = event.result.summary;
        if (event.result.error != null) r.error = event.result.error;
      }
    });
  }

  Future<void> _saveAsSnippet() async {
    final result = _result;
    if (result == null) return;
    final name = '${result.runbook.name} (run)';
    final commandLines = result.results
        .where((r) =>
            r.step.type == RunbookStepType.command && r.stdout.isNotEmpty)
        .map((r) => '# ${r.step.label}\n${r.stdout.trim()}')
        .join('\n\n');
    if (commandLines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No command output to save.')),
      );
      return;
    }
    const storage = CustomActionsStorage();
    final existing = await storage.loadActions();
    final next = [
      ...existing,
      QuickAction(
        id: 'snip-${DateTime.now().microsecondsSinceEpoch}',
        label: name,
        command: '# saved from runbook run\n$commandLines',
        isCustom: true,
      ),
    ];
    await storage.saveActions(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved as snippet.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          widget.runbook.name.toUpperCase(),
          style: const TextStyle(
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            letterSpacing: 1.4,
            fontSize: 13,
          ),
        ),
        actions: [
          if (_result != null)
            TextButton.icon(
              onPressed: _saveAsSnippet,
              icon: const Icon(Icons.bookmark_add_outlined, size: 14),
              label: const Text('SAVE AS SNIPPET'),
            ),
        ],
      ),
      body: !_paramsCollected
          ? Center(
              child: FilledButton.icon(
                onPressed: _collectParamsAndStart,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('START RUN'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final s in widget.runbook.steps)
                  _StepTile(row: _rows[s.id]!),
              ],
            ),
      bottomNavigationBar: _running
          ? Container(
              color: AppColors.panel,
              padding: const EdgeInsets.all(12),
              child: SafeArea(
                top: false,
                child: FilledButton.icon(
                  onPressed: _stop,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('STOP'),
                ),
              ),
            )
          : null,
    );
  }
}

enum _RowStatus { pending, running, succeeded, skipped, cancelled, failed }

class _StepRow {
  _StepRow({required this.step});
  final RunbookStep step;
  _RowStatus status = _RowStatus.pending;
  String stdout = '';
  String summary = '';
  String? error;
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.row});
  final _StepRow row;

  Color _colorForStatus() {
    switch (row.status) {
      case _RowStatus.succeeded:
        return AppColors.accent;
      case _RowStatus.failed:
        return AppColors.danger;
      case _RowStatus.cancelled:
        return AppColors.danger;
      case _RowStatus.skipped:
        return AppColors.textMuted;
      case _RowStatus.running:
        return AppColors.textPrimary;
      case _RowStatus.pending:
        return AppColors.textFaint;
    }
  }

  String _labelForStatus() => switch (row.status) {
        _RowStatus.pending => 'PENDING',
        _RowStatus.running => 'RUNNING',
        _RowStatus.succeeded => 'OK',
        _RowStatus.skipped => 'SKIPPED',
        _RowStatus.cancelled => 'CANCELLED',
        _RowStatus.failed => 'FAILED',
      };

  @override
  Widget build(BuildContext context) {
    final color = _colorForStatus();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border)),
      child: ExpansionTile(
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                row.step.label.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: color)),
              child: Text(
                _labelForStatus(),
                style: TextStyle(
                  color: color,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  fontSize: 9,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          ],
        ),
        children: [
          if (row.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                row.summary,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
          if (row.stdout.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: AppColors.panel,
              child: SelectableText(
                row.stdout,
                style: const TextStyle(
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  fontSize: 11,
                ),
              ),
            ),
          if (row.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                row.error!,
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
        ],
      ),
    );
  }
}
