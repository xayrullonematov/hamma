import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/storage/custom_actions_storage.dart';
import 'quick_actions.dart';

class CustomActionsScreen extends StatefulWidget {
  const CustomActionsScreen({
    super.key,
  });

  @override
  State<CustomActionsScreen> createState() => _CustomActionsScreenState();
}

class _CustomActionsScreenState extends State<CustomActionsScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);

  final CustomActionsStorage _customActionsStorage = const CustomActionsStorage();

  bool _isLoading = true;
  bool _isSaving = false;
  String? _loadError;
  List<QuickAction> _actions = const [];

  @override
  void initState() {
    super.initState();
    _loadActions();
  }

  Future<void> _loadActions() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final actions = await _customActionsStorage.loadActions();
      if (!mounted) {
        return;
      }

      setState(() {
        _actions = actions;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveActions(List<QuickAction> actions) async {
    setState(() {
      _isSaving = true;
    });

    try {
      await _customActionsStorage.saveActions(actions);
      if (!mounted) {
        return;
      }

      setState(() {
        _actions = actions;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _addAction() async {
    final action = await Navigator.of(context).push<QuickAction>(
      MaterialPageRoute<QuickAction>(
        builder: (_) => const _CustomActionFormScreen(),
      ),
    );

    if (action == null) {
      return;
    }

    await _saveActions([..._actions, action]);
  }

  Future<void> _editAction(QuickAction action) async {
    final updatedAction = await Navigator.of(context).push<QuickAction>(
      MaterialPageRoute<QuickAction>(
        builder: (_) => _CustomActionFormScreen(initialAction: action),
      ),
    );

    if (updatedAction == null) {
      return;
    }

    final updatedActions = _actions
        .map((item) => item.id == updatedAction.id ? updatedAction : item)
        .toList();
    await _saveActions(updatedActions);
  }

  Future<void> _deleteAction(QuickAction action) async {
    final shouldDelete = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Delete Custom Action'),
              content: Text('Remove "${action.label}" from saved custom actions?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldDelete) {
      return;
    }

    final updatedActions =
        _actions.where((item) => item.id != action.id).toList();
    await _saveActions(updatedActions);
  }

  BoxDecoration _sectionDecoration() {
    return BoxDecoration(
      color: _surfaceColor,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: _shadowColor,
          blurRadius: 20,
          offset: Offset(0, 10),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: const Text('Custom Quick Actions'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isLoading || _isSaving ? null : _addAction,
        icon: const Icon(Icons.add),
        label: const Text('Add Action'),
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _loadError!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _loadActions,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      Container(
                        decoration: _sectionDecoration(),
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.14,
                                ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.terminal_rounded,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Reusable Commands',
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Create reusable bash commands that appear on each server dashboard.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: _mutedColor,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_actions.isEmpty)
                        Container(
                          decoration: _sectionDecoration(),
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.edit_note_rounded,
                                size: 36,
                                color: _mutedColor,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No custom actions yet',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Add a reusable command to keep common maintenance tasks one tap away.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _mutedColor,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: _isSaving ? null : _addAction,
                                icon: const Icon(Icons.add),
                                label: const Text('Add Action'),
                              ),
                            ],
                          ),
                        )
                      else
                        ...List.generate(_actions.length, (index) {
                          final action = _actions[index];

                          return Padding(
                            padding: EdgeInsets.only(
                              bottom: index == _actions.length - 1 ? 0 : 12,
                            ),
                            child: Container(
                              decoration: _sectionDecoration(),
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              action.label,
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: _panelColor,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Text(
                                                'Custom',
                                                style: TextStyle(
                                                  color: _mutedColor,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Column(
                                        children: [
                                          IconButton(
                                            onPressed: _isSaving
                                                ? null
                                                : () => _editAction(action),
                                            icon: const Icon(Icons.edit_outlined),
                                            style: IconButton.styleFrom(
                                              backgroundColor: _panelColor,
                                              foregroundColor: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          IconButton(
                                            onPressed: _isSaving
                                                ? null
                                                : () => _deleteAction(action),
                                            icon:
                                                const Icon(Icons.delete_outline),
                                            style: IconButton.styleFrom(
                                              backgroundColor: _panelColor,
                                              foregroundColor:
                                                  const Color(0xFFFCA5A5),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: _panelColor,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: SelectableText(
                                      action.command,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
      ),
    );
  }
}

class _CustomActionFormScreen extends StatefulWidget {
  const _CustomActionFormScreen({
    this.initialAction,
  });

  final QuickAction? initialAction;

  @override
  State<_CustomActionFormScreen> createState() => _CustomActionFormScreenState();
}

class _CustomActionFormScreenState extends State<_CustomActionFormScreen> {
  static const _surfaceColor = Color(0xFF1E293B);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);

  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _labelController;
  late final TextEditingController _commandController;

  bool get _isEditing => widget.initialAction != null;

  @override
  void initState() {
    super.initState();
    final action = widget.initialAction;
    _labelController = TextEditingController(text: action?.label ?? '');
    _commandController = TextEditingController(text: action?.command ?? '');
  }

  @override
  void dispose() {
    _labelController.dispose();
    _commandController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final action = QuickAction(
      id: widget.initialAction?.id ?? _generateActionId(),
      label: _labelController.text.trim(),
      command: _commandController.text.trim(),
      isCustom: true,
    );

    Navigator.of(context).pop(action);
  }

  String _generateActionId() {
    final random = Random.secure().nextInt(1 << 32);
    return 'custom-${DateTime.now().microsecondsSinceEpoch}-$random';
  }

  InputDecoration _fieldDecoration(String label, {String? helperText}) {
    return InputDecoration(
      labelText: label,
      helperText: helperText,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Action' : 'Add Action'),
      ),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 24),
            children: [
              _ActionFormSectionCard(
                title: 'Action Details',
                subtitle:
                    'Save a reusable bash command for quick access on every server dashboard.',
                icon: Icons.terminal_rounded,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _labelController,
                      decoration: _fieldDecoration('Action Name'),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Enter an action name.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _commandController,
                      minLines: 3,
                      maxLines: 6,
                      decoration: _fieldDecoration(
                        'Command',
                        helperText: 'This command will run directly over SSH.',
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        fontFamily: 'monospace',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Enter a bash command.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(_isEditing ? 'Save Changes' : 'Save Action'),
              ),
              const SizedBox(height: 8),
              Text(
                'Custom actions stay on this device and appear in the dashboard quick actions grid.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _mutedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionFormSectionCard extends StatelessWidget {
  const _ActionFormSectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _CustomActionFormScreenState._surfaceColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: _CustomActionFormScreenState._shadowColor,
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _CustomActionFormScreenState._mutedColor,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}
