import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/runbooks/runbook.dart';
import '../../core/runbooks/runbook_ai_drafter.dart';
import '../../core/runbooks/runbook_change_bus.dart';
import '../../core/runbooks/runbook_storage.dart';
import '../../core/runbooks/starter_pack.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/theme/app_colors.dart';
import 'runbook_editor_screen.dart';
import 'runbook_run_screen.dart';

/// Per-server Runbooks tab.
class RunbooksScreen extends StatefulWidget {
  const RunbooksScreen({
    super.key,
    required this.sshService,
    required this.serverId,
    required this.serverName,
    required this.aiSettings,
  });

  final SshService sshService;
  final String serverId;
  final String serverName;
  final AiSettings aiSettings;

  @override
  State<RunbooksScreen> createState() => _RunbooksScreenState();
}

class _RunbooksScreenState extends State<RunbooksScreen> {
  final RunbookStorage _storage = const RunbookStorage();
  StreamSubscription<void>? _changeSub;
  List<Runbook> _userRunbooks = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _changeSub = RunbookChangeBus.instance.changes.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final list = await _storage.loadForServer(widget.serverId);
      if (!mounted) return;
      setState(() {
        _userRunbooks = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load runbooks: $e')),
      );
    }
  }

  Future<void> _openEditor({Runbook? runbook}) async {
    final fresh = runbook ??
        Runbook(
          id: RunbookStorage.generateId(),
          name: 'Untitled runbook',
          serverId: widget.serverId,
        );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RunbookEditorScreen(
          initial: fresh,
          serverId: widget.serverId,
        ),
      ),
    );
  }

  Future<void> _runRunbook(Runbook runbook) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RunbookRunScreen(
          runbook: runbook,
          sshService: widget.sshService,
          aiSettings: widget.aiSettings,
        ),
      ),
    );
  }

  Future<void> _draftWithAi() async {
    final controller = TextEditingController();
    final goal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'ASK AI TO DRAFT A RUNBOOK',
          style: TextStyle(
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            letterSpacing: 1.2,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'e.g. rotate the letsencrypt cert on this host',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('DRAFT'),
          ),
        ],
      ),
    );
    if (goal == null || goal.isEmpty || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );

    try {
      final drafter = RunbookAiDrafter(aiSettings: widget.aiSettings);
      final draft = await drafter.draftFromGoal(
        goal,
        serverContext: widget.serverName,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // close spinner
      await _openEditor(
        runbook: draft.copyWith(serverId: widget.serverId),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // close spinner
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Draft failed: $e')),
      );
    }
  }

  Future<void> _confirmDelete(Runbook runbook) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('DELETE RUNBOOK'),
        content: Text('Delete "${runbook.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _storage.delete(runbook.id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final personalRows = _userRunbooks
        .where((r) => !r.starter)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'RUNBOOKS',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _draftWithAi,
                icon: const Icon(Icons.auto_awesome_rounded, size: 14),
                label: const Text('ASK AI'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add_rounded, size: 14),
                label: const Text('NEW'),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: ListView(
            children: [
              if (personalRows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'NO PERSONAL RUNBOOKS YET — TRY THE STARTER PACK BELOW '
                    'OR ASK AI.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                      fontSize: 11,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              for (final r in personalRows)
                _RunbookRow(
                  runbook: r,
                  onTap: () => _runRunbook(r),
                  onEdit: () => _openEditor(runbook: r),
                  onDelete: () => _confirmDelete(r),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'STARTER PACK',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontSize: 11,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              for (final r in starterPackRunbooks)
                _RunbookRow(
                  runbook: r,
                  onTap: () => _runRunbook(r),
                  onEdit: () => _openEditor(
                    runbook: r.copyWith(
                      id: RunbookStorage.generateId(),
                      starter: false,
                      serverId: widget.serverId,
                      name: '${r.name} (copy)',
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }
}

class _RunbookRow extends StatelessWidget {
  const _RunbookRow({
    required this.runbook,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  final Runbook runbook;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppColors.border, width: 1),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(
                  color: runbook.starter
                      ? AppColors.accent
                      : AppColors.border,
                  width: 1,
                ),
              ),
              child: Icon(
                runbook.team
                    ? Icons.group_rounded
                    : Icons.play_arrow_rounded,
                size: 18,
                color: runbook.starter
                    ? AppColors.accent
                    : AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    runbook.name.toUpperCase(),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (runbook.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        runbook.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${runbook.steps.length} STEP'
                      '${runbook.steps.length == 1 ? "" : "S"}'
                      '${runbook.starter ? " · STARTER" : ""}'
                      '${runbook.team ? " · TEAM" : ""}',
                      style: const TextStyle(
                        color: AppColors.textFaint,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 9,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (onEdit != null)
              IconButton(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_rounded, size: 16),
                tooltip: runbook.starter ? 'Edit a copy' : 'Edit',
                color: AppColors.textMuted,
              ),
            if (onDelete != null)
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                tooltip: 'Delete',
                color: AppColors.textFaint,
              ),
          ],
        ),
      ),
    );
  }
}
