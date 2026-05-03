import 'package:flutter/material.dart';

import '../../core/runbooks/runbook.dart';
import '../../core/runbooks/runbook_runner.dart';
import '../../core/runbooks/runbook_storage.dart';
import '../../core/theme/app_colors.dart';

/// Form-driven editor for a single [Runbook]. Brutalist UI: every
/// step is its own panel; reordering uses the long-press handle on a
/// [ReorderableListView]; the dry-run button shows the would-be SSH
/// commands without sending them.
class RunbookEditorScreen extends StatefulWidget {
  const RunbookEditorScreen({
    super.key,
    required this.initial,
    required this.serverId,
  });

  final Runbook initial;
  final String serverId;

  @override
  State<RunbookEditorScreen> createState() => _RunbookEditorScreenState();
}

class _RunbookEditorScreenState extends State<RunbookEditorScreen> {
  final RunbookStorage _storage = const RunbookStorage();
  late TextEditingController _nameCtrl;
  late TextEditingController _descCtrl;
  late List<RunbookStep> _steps;
  late List<RunbookParam> _params;
  late bool _team;
  late bool _globalScope;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initial.name);
    _descCtrl = TextEditingController(text: widget.initial.description);
    _steps = List.of(widget.initial.steps);
    _params = List.of(widget.initial.params);
    _team = widget.initial.team;
    _globalScope = widget.initial.serverId == null;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Runbook _build() {
    return widget.initial.copyWith(
      name: _nameCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      steps: _steps,
      params: _params,
      team: _team,
      serverId: _globalScope ? null : widget.serverId,
      clearServerId: _globalScope,
    );
  }

  Future<void> _save() async {
    final rb = _build();
    final problems = rb.validate();
    if (problems.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('FIX VALIDATION ERRORS'),
          content: Text(problems.map((p) => '• $p').join('\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await _storage.upsert(rb);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _addStep(RunbookStepType type) {
    setState(() {
      _steps.add(RunbookStep(
        id: 's${_steps.length + 1}-${DateTime.now().millisecondsSinceEpoch % 100000}',
        label: 'New ${type.name}',
        type: type,
      ));
    });
  }

  void _addParam() {
    setState(() {
      _params.add(RunbookParam(
        name: 'param${_params.length + 1}',
        label: 'New parameter',
      ));
    });
  }

  Future<void> _dryRun() async {
    final rb = _build();
    final initialParams = <String, String>{
      for (final p in rb.params) p.name: p.defaultValue ?? '',
    };
    final cmds = dryRunCommands(rb, initialParams);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('DRY RUN — COMMANDS THAT WOULD RUN'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              cmds.isEmpty
                  ? '(no command steps in this runbook)'
                  : cmds.asMap().entries
                      .map((e) => '${e.key + 1}. ${e.value}')
                      .join('\n\n'),
              style: const TextStyle(
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
                fontSize: 12,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text(
          'EDIT RUNBOOK',
          style: TextStyle(
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            letterSpacing: 1.4,
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: _dryRun,
            icon: const Icon(Icons.science_outlined, size: 14),
            label: const Text('DRY RUN'),
          ),
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined, size: 14),
            label: const Text('SAVE'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _globalScope,
                  onChanged: (v) => setState(() => _globalScope = v),
                  title: const Text('Global (visible on every server)'),
                ),
              ),
              Expanded(
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _team,
                  onChanged: (v) => setState(() => _team = v),
                  title: const Text('Team (sync via cloud destination)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionHeader(
            label: 'PARAMETERS',
            actionLabel: 'ADD PARAM',
            onAction: _addParam,
          ),
          for (var i = 0; i < _params.length; i++)
            _ParamCard(
              key: ValueKey('param-$i'),
              param: _params[i],
              onChanged: (p) => setState(() => _params[i] = p),
              onDelete: () => setState(() => _params.removeAt(i)),
            ),
          const SizedBox(height: 16),
          const _SectionHeader(label: 'STEPS', actionLabel: '', onAction: null),
          Wrap(
            spacing: 8,
            children: [
              for (final t in RunbookStepType.values)
                OutlinedButton.icon(
                  onPressed: () => _addStep(t),
                  icon: const Icon(Icons.add_rounded, size: 14),
                  label: Text('ADD ${t.wireName.toUpperCase()}'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _steps.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _steps.removeAt(oldIndex);
                _steps.insert(newIndex, item);
              });
            },
            itemBuilder: (context, i) {
              return _StepCard(
                key: ValueKey('step-${_steps[i].id}-$i'),
                index: i,
                step: _steps[i],
                onChanged: (s) => setState(() => _steps[i] = s),
                onDelete: () => setState(() => _steps.removeAt(i)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.actionLabel,
    required this.onAction,
  });

  final String label;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontSize: 11,
              letterSpacing: 1.4,
            ),
          ),
        ),
        if (onAction != null)
          OutlinedButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add_rounded, size: 14),
            label: Text(actionLabel),
          ),
      ],
    );
  }
}

class _ParamCard extends StatelessWidget {
  const _ParamCard({
    super.key,
    required this.param,
    required this.onChanged,
    required this.onDelete,
  });

  final RunbookParam param;
  final ValueChanged<RunbookParam> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border)),
      child: Row(
        children: [
          Expanded(
            child: TextFormField(
              initialValue: param.name,
              decoration: const InputDecoration(labelText: 'name'),
              onChanged: (v) => onChanged(RunbookParam(
                name: v,
                label: param.label,
                defaultValue: param.defaultValue,
                required: param.required,
              )),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              initialValue: param.label,
              decoration: const InputDecoration(labelText: 'label'),
              onChanged: (v) => onChanged(RunbookParam(
                name: param.name,
                label: v,
                defaultValue: param.defaultValue,
                required: param.required,
              )),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              initialValue: param.defaultValue,
              decoration: const InputDecoration(labelText: 'default'),
              onChanged: (v) => onChanged(RunbookParam(
                name: param.name,
                label: param.label,
                defaultValue: v,
                required: param.required,
              )),
            ),
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            color: AppColors.textFaint,
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    super.key,
    required this.index,
    required this.step,
    required this.onChanged,
    required this.onDelete,
  });

  final int index;
  final RunbookStep step;
  final ValueChanged<RunbookStep> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: key,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Icon(Icons.drag_indicator, size: 16),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.accent),
                ),
                child: Text(
                  step.type.wireName.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontSize: 9,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: step.label,
                  decoration: const InputDecoration(labelText: 'label'),
                  onChanged: (v) => onChanged(step.copyWith(label: v)),
                ),
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                color: AppColors.textFaint,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._fieldsFor(step, onChanged),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: step.skipIfRegex,
            decoration: const InputDecoration(
              labelText: 'skipIf regex (optional)',
              hintText: 'skip this step when the referenced output matches',
            ),
            onChanged: (v) => onChanged(step.copyWith(skipIfRegex: v)),
          ),
          TextFormField(
            initialValue: step.skipIfReferenceStepId,
            decoration: const InputDecoration(
              labelText: 'skipIf reference stepId (optional)',
            ),
            onChanged: (v) => onChanged(step.copyWith(skipIfReferenceStepId: v)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: step.continueOnError,
            onChanged: (v) => onChanged(step.copyWith(continueOnError: v)),
            title: const Text('Continue on error'),
          ),
        ],
      ),
    );
  }

  List<Widget> _fieldsFor(RunbookStep s, ValueChanged<RunbookStep> on) {
    switch (s.type) {
      case RunbookStepType.command:
        return [
          TextFormField(
            initialValue: s.command,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'command',
              hintText: 'use {{paramName}} or {{step.<id>.stdout}}',
            ),
            onChanged: (v) => on(s.copyWith(command: v)),
          ),
          TextFormField(
            initialValue: s.timeoutSeconds?.toString(),
            decoration: const InputDecoration(
              labelText: 'timeoutSeconds (optional)',
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) =>
                on(s.copyWith(timeoutSeconds: int.tryParse(v))),
          ),
        ];
      case RunbookStepType.promptUser:
        return [
          TextFormField(
            initialValue: s.paramName,
            decoration: const InputDecoration(labelText: 'paramName'),
            onChanged: (v) => on(s.copyWith(paramName: v)),
          ),
          TextFormField(
            initialValue: s.question,
            decoration: const InputDecoration(labelText: 'question'),
            onChanged: (v) => on(s.copyWith(question: v)),
          ),
          TextFormField(
            initialValue: s.defaultValue,
            decoration: const InputDecoration(labelText: 'defaultValue'),
            onChanged: (v) => on(s.copyWith(defaultValue: v)),
          ),
        ];
      case RunbookStepType.waitFor:
        return [
          DropdownButtonFormField<String>(
            value: s.waitMode,
            decoration: const InputDecoration(labelText: 'waitMode'),
            items: const [
              DropdownMenuItem(value: 'time', child: Text('time')),
              DropdownMenuItem(value: 'regex', child: Text('regex')),
              DropdownMenuItem(value: 'manual', child: Text('manual')),
            ],
            onChanged: (v) => on(s.copyWith(waitMode: v)),
          ),
          TextFormField(
            initialValue: s.waitSeconds?.toString(),
            decoration: const InputDecoration(labelText: 'waitSeconds'),
            keyboardType: TextInputType.number,
            onChanged: (v) => on(s.copyWith(waitSeconds: int.tryParse(v))),
          ),
          TextFormField(
            initialValue: s.waitRegex,
            decoration: const InputDecoration(labelText: 'waitRegex'),
            onChanged: (v) => on(s.copyWith(waitRegex: v)),
          ),
          TextFormField(
            initialValue: s.waitReferenceStepId,
            decoration: const InputDecoration(
              labelText: 'waitReferenceStepId',
            ),
            onChanged: (v) => on(s.copyWith(waitReferenceStepId: v)),
          ),
        ];
      case RunbookStepType.aiSummarize:
        return [
          TextFormField(
            initialValue: s.aiPrompt,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'aiPrompt'),
            onChanged: (v) => on(s.copyWith(aiPrompt: v)),
          ),
          TextFormField(
            initialValue: s.aiReferenceStepId,
            decoration: const InputDecoration(
              labelText: 'aiReferenceStepId (default: previous step)',
            ),
            onChanged: (v) => on(s.copyWith(aiReferenceStepId: v)),
          ),
        ];
      case RunbookStepType.notify:
        return [
          TextFormField(
            initialValue: s.notifyMessage,
            minLines: 1,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'notifyMessage'),
            onChanged: (v) => on(s.copyWith(notifyMessage: v)),
          ),
        ];
      case RunbookStepType.branch:
        return [
          TextFormField(
            initialValue: s.branchRegex,
            decoration: const InputDecoration(
              labelText: 'branchRegex',
              hintText: 'regex evaluated against the referenced step output',
            ),
            onChanged: (v) => on(s.copyWith(branchRegex: v)),
          ),
          TextFormField(
            initialValue: s.branchReferenceStepId,
            decoration: const InputDecoration(
              labelText: 'branchReferenceStepId (default: previous step)',
            ),
            onChanged: (v) => on(s.copyWith(branchReferenceStepId: v)),
          ),
          TextFormField(
            initialValue: s.branchTrueGoToStepId,
            decoration: const InputDecoration(
              labelText: 'branchTrueGoToStepId (jump on match)',
            ),
            onChanged: (v) => on(s.copyWith(branchTrueGoToStepId: v)),
          ),
          TextFormField(
            initialValue: s.branchFalseGoToStepId,
            decoration: const InputDecoration(
              labelText: 'branchFalseGoToStepId (jump on no match)',
            ),
            onChanged: (v) => on(s.copyWith(branchFalseGoToStepId: v)),
          ),
        ];
    }
  }
}
