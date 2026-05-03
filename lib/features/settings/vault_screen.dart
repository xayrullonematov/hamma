import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/storage/app_lock_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../core/vault/vault_redactor.dart';
import '../../core/vault/vault_secret.dart';
import '../../core/vault/vault_storage.dart';

/// Settings → **Vault** screen.
///
/// Lists every named secret with VALUE hidden by default. The reveal
/// flow is PIN-gated; copy puts the value on the clipboard for 30
/// seconds then auto-clears. Brutalist styling matches the rest of
/// the Settings stack.
class VaultScreen extends StatefulWidget {
  const VaultScreen({
    super.key,
    VaultStorage? storage,
    AppLockStorage? appLockStorage,
  })  : _storage = storage,
        _appLockStorage = appLockStorage;

  final VaultStorage? _storage;
  final AppLockStorage? _appLockStorage;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen>
    with WidgetsBindingObserver {
  late final VaultStorage _storage;
  late final AppLockStorage _appLockStorage;

  /// 30-second auto-clear for clipboard copies. Tracks the value we
  /// wrote so we never clobber a clipboard the user populated
  /// themselves between copy and timeout. The generation counter
  /// guards against an older timer firing after a newer copy has
  /// re-armed the clipboard with the same value.
  static const Duration _clipboardLifetime = Duration(seconds: 30);
  Timer? _clipboardClearTimer;
  String? _lastCopiedValue;
  int _clipboardGeneration = 0;

  bool _loading = true;
  List<VaultSecret> _secrets = const [];
  final Set<String> _revealedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _storage = widget._storage ?? VaultStorage();
    _appLockStorage = widget._appLockStorage ?? AppLockStorage();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardClearTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Clear every revealed value the moment the app loses focus —
    // shoulder-surfing protection for app switchers, lock-screen
    // peeks, and (during development) hot reload.
    if (state != AppLifecycleState.resumed && _revealedIds.isNotEmpty) {
      setState(_revealedIds.clear);
    }
  }

  Future<void> _reload() async {
    final all = await _storage.loadAll();
    if (!mounted) return;
    setState(() {
      _secrets = all;
      _loading = false;
      // Refresh the global redactor so any in-flight error/AI call
      // sees the latest vault contents.
      GlobalVaultRedactor.set(VaultRedactor.from(all));
    });
  }

  Future<bool> _verifyPin() async {
    final hasPin = await _appLockStorage.hasPin();
    if (!hasPin) {
      // No PIN set — fail closed: the vault reveal flow needs the
      // user to have configured app-lock first.
      _snack('Set a master PIN in Security settings first.');
      return false;
    }
    final actualPin = await _appLockStorage.readPin();
    if (!mounted) return false;
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        String? error;
        return StatefulBuilder(
          builder: (context, setSt) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('REVEAL SECRET'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Enter your master PIN to reveal this secret.'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'PIN',
                    errorText: error,
                  ),
                  onSubmitted: (_) {
                    if (controller.text == actualPin) {
                      Navigator.of(ctx).pop(controller.text);
                    } else {
                      setSt(() => error = 'Incorrect PIN.');
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('CANCEL'),
              ),
              FilledButton(
                onPressed: () {
                  if (controller.text == actualPin) {
                    Navigator.of(ctx).pop(controller.text);
                  } else {
                    setSt(() => error = 'Incorrect PIN.');
                  }
                },
                child: const Text('REVEAL'),
              ),
            ],
          ),
        );
      },
    );
    return entered != null;
  }

  Future<void> _toggleReveal(VaultSecret secret) async {
    if (_revealedIds.contains(secret.id)) {
      setState(() => _revealedIds.remove(secret.id));
      return;
    }
    final ok = await _verifyPin();
    if (!ok || !mounted) return;
    setState(() => _revealedIds.add(secret.id));
  }

  Future<void> _copyToClipboard(VaultSecret secret) async {
    final ok = await _verifyPin();
    if (!ok) return;
    await Clipboard.setData(ClipboardData(text: secret.value));
    _lastCopiedValue = secret.value;
    _clipboardClearTimer?.cancel();
    final myGeneration = ++_clipboardGeneration;
    _clipboardClearTimer = Timer(
      _clipboardLifetime,
      () => _autoClearClipboard(myGeneration),
    );
    _snack('Copied. Auto-clears in 30 s.');
  }

  Future<void> _autoClearClipboard(int generation) async {
    // A newer copy already re-armed the clipboard — that copy owns
    // the lifetime now, so this stale timer must do nothing.
    if (generation != _clipboardGeneration) return;
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    // Only clear when the clipboard still contains exactly what we
    // wrote — never stomp on something the user copied themselves.
    if (current?.text == _lastCopiedValue) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
    _lastCopiedValue = null;
  }

  Future<void> _addOrEdit({VaultSecret? existing}) async {
    final result = await showDialog<VaultSecret>(
      context: context,
      builder: (ctx) => _VaultSecretDialog(initial: existing),
    );
    if (result == null) return;
    try {
      await _storage.upsert(result);
      await _reload();
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  Future<void> _delete(VaultSecret secret) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('DELETE SECRET'),
        content: Text('Delete "${secret.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _storage.delete(secret.id);
    await _reload();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text('VAULT'),
        backgroundColor: AppColors.scaffoldBackground,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: const Text('NEW SECRET'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _secrets.isEmpty
              ? _emptyState(context)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: _secrets.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final s = _secrets[i];
                    return _SecretTile(
                      secret: s,
                      revealed: _revealedIds.contains(s.id),
                      onReveal: () => _toggleReveal(s),
                      onCopy: () => _copyToClipboard(s),
                      onEdit: () => _addOrEdit(existing: s),
                      onDelete: () => _delete(s),
                    );
                  },
                ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline,
                color: AppColors.textMuted, size: 48),
            const SizedBox(height: 16),
            Text(
              'No secrets yet.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Add a secret, then reference it in any command as '
              r'${vault:NAME}.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecretTile extends StatelessWidget {
  const _SecretTile({
    required this.secret,
    required this.revealed,
    required this.onReveal,
    required this.onCopy,
    required this.onEdit,
    required this.onDelete,
  });

  final VaultSecret secret;
  final bool revealed;
  final VoidCallback onReveal;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  secret.name,
                  style: const TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: secret.isGlobal
                      ? AppColors.accentDim
                      : AppColors.border,
                ),
                child: Text(
                  secret.isGlobal ? 'GLOBAL' : 'SERVER',
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: AppColors.monoFamily,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: AppColors.panel,
            child: Text(
              revealed ? secret.value : '•' * 12,
              style: const TextStyle(
                fontFamily: AppColors.monoFamily,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (secret.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              secret.description,
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onReveal,
                icon: Icon(revealed ? Icons.visibility_off : Icons.visibility),
                label: Text(revealed ? 'HIDE' : 'REVEAL'),
              ),
              OutlinedButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy),
                label: const Text('COPY'),
              ),
              OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('EDIT'),
              ),
              OutlinedButton.icon(
                onPressed: onDelete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('DELETE'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VaultSecretDialog extends StatefulWidget {
  const _VaultSecretDialog({this.initial});
  final VaultSecret? initial;

  @override
  State<_VaultSecretDialog> createState() => _VaultSecretDialogState();
}

class _VaultSecretDialogState extends State<_VaultSecretDialog> {
  late final TextEditingController _name;
  late final TextEditingController _value;
  late final TextEditingController _description;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _value = TextEditingController(text: widget.initial?.value ?? '');
    _description =
        TextEditingController(text: widget.initial?.description ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final value = _value.text;
    if (name.isEmpty || value.isEmpty) {
      setState(() => _error = 'Name and value are required.');
      return;
    }
    final secret = VaultSecret(
      id: widget.initial?.id ?? '',
      name: name,
      value: value,
      scope: widget.initial?.scope,
      description: _description.text.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    if (!secret.isValid) {
      setState(() => _error =
          'Name must match [A-Za-z_][A-Za-z0-9_]* and value must not be '
          'empty.');
      return;
    }
    Navigator.of(context).pop(secret);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.initial == null ? 'NEW SECRET' : 'EDIT SECRET'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'NAME (e.g. DB_PASSWORD)',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'VALUE'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'DESCRIPTION (optional)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: AppColors.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton(onPressed: _submit, child: const Text('SAVE')),
      ],
    );
  }
}
