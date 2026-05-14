import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/vault/credential_template.dart';
import '../../core/vault/vault_group.dart';
import '../../core/vault/vault_secret.dart';
import '../../core/vault/vault_storage.dart';

class VaultGroupEditScreen extends StatefulWidget {
  const VaultGroupEditScreen({
    super.key,
    this.group,
    this.type,
    this.storage,
  }) : assert(group != null || type != null);

  final VaultGroup? group;
  final CredentialType? type;
  final VaultStorage? storage;

  @override
  State<VaultGroupEditScreen> createState() => _VaultGroupEditScreenState();
}

class _VaultGroupEditScreenState extends State<VaultGroupEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _tagsController;
  late TextEditingController _notesController;
  late final VaultStorage _storage;
  final List<_FieldEditor> _fields = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? VaultStorage();
    _nameController = TextEditingController(text: widget.group?.name ?? '');
    _tagsController = TextEditingController(text: widget.group?.tags.join(', ') ?? '');
    _notesController = TextEditingController(text: widget.group?.notes ?? '');
    _initializeFields();
  }

  Future<void> _initializeFields() async {
    if (widget.group != null) {
      final secrets = await _storage.loadByGroup(widget.group!.id);
      for (final s in secrets) {
        _fields.add(_FieldEditor(name: s.name, value: s.value, secretId: s.id));
      }
    } else if (widget.type != null) {
      final template = CredentialTemplate.registry[widget.type!] ?? [];
      for (final name in template) {
        _fields.add(_FieldEditor(name: name, value: ''));
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _tagsController.dispose();
    _notesController.dispose();
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _addField() {
    setState(() {
      _fields.add(_FieldEditor(name: '', value: ''));
    });
  }

  void _removeField(int index) {
    setState(() {
      _fields.removeAt(index).dispose();
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final tags = _tagsController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    final group = VaultGroup(
      id: widget.group?.id ?? '',
      name: _nameController.text.trim(),
      type: widget.group?.type ?? widget.type!,
      tags: tags,
      notes: _notesController.text.trim(),
      createdAt: widget.group?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final savedGroup = await _storage.upsertGroup(group);

    for (final f in _fields) {
      final secret = VaultSecret(
        id: f.secretId ?? '',
        name: f.nameController.text.trim(),
        value: f.valueController.text,
        groupId: savedGroup.id,
        updatedAt: DateTime.now(),
      );
      await _storage.upsert(secret);
    }

    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete Group?'),
        content: const Text('Member secrets will remain but be ungrouped.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('DELETE', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      await _storage.deleteGroup(widget.group!.id);
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: Text(widget.group == null ? 'NEW GROUP' : 'EDIT GROUP'),
        backgroundColor: AppColors.scaffoldBackground,
        actions: [
          if (widget.group != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              onPressed: _delete,
            ),
          TextButton(
            onPressed: _save,
            child: const Text('SAVE', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  _SectionHeader(title: 'METADATA'),
                  const SizedBox(height: 16),
                  _BrutalistInput(
                    controller: _nameController,
                    label: 'GROUP NAME',
                    validator: (v) => v?.isEmpty == true ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  _BrutalistInput(
                    controller: _tagsController,
                    label: 'TAGS (comma separated)',
                  ),
                  const SizedBox(height: 16),
                  _BrutalistInput(
                    controller: _notesController,
                    label: 'NOTES',
                    maxLines: 3,
                  ),
                  const SizedBox(height: 32),
                  _SectionHeader(
                    title: 'FIELDS',
                    action: TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('ADD'),
                      onPressed: _addField,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ..._fields.asMap().entries.map((e) => _FieldInputRow(
                        editor: e.value,
                        onRemove: () => _removeField(e.key),
                      )),
                ],
              ),
            ),
    );
  }
}

class _FieldEditor {
  _FieldEditor({required String name, required String value, this.secretId}) {
    nameController = TextEditingController(text: name);
    valueController = TextEditingController(text: value);
  }
  late TextEditingController nameController;
  late TextEditingController valueController;
  final String? secretId;

  void dispose() {
    nameController.dispose();
    valueController.dispose();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: AppColors.monoFamily,
            color: AppColors.textFaint,
            fontSize: 12,
            letterSpacing: 2,
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

class _BrutalistInput extends StatelessWidget {
  const _BrutalistInput({required this.controller, required this.label, this.validator, this.maxLines = 1});
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textFaint, fontSize: 12),
        filled: true,
        fillColor: AppColors.panel,
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
      ),
      validator: validator,
    );
  }
}

class _FieldInputRow extends StatelessWidget {
  const _FieldInputRow({required this.editor, required this.onRemove});
  final _FieldEditor editor;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: _BrutalistInput(
              controller: editor.nameController,
              label: 'LABEL',
              validator: (v) => v?.isEmpty == true ? 'Required' : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: editor.valueController,
              obscureText: true,
              style: const TextStyle(fontSize: 14, fontFamily: AppColors.monoFamily),
              decoration: const InputDecoration(
                labelText: 'VALUE',
                labelStyle: TextStyle(color: AppColors.textFaint, fontSize: 12),
                filled: true,
                fillColor: AppColors.panel,
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
              ),
              validator: (v) => v?.isEmpty == true ? 'Required' : null,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, color: AppColors.textFaint),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
