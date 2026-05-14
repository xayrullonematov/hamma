import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/vault/vault_access_log.dart';
import '../../core/vault/vault_auth_service.dart';
import '../../core/vault/vault_group.dart';
import '../../core/vault/vault_secret.dart';
import '../../core/vault/vault_storage.dart';
import 'vault_group_edit_screen.dart';

class VaultGroupDetailScreen extends StatefulWidget {
  const VaultGroupDetailScreen({
    super.key,
    required this.group,
    this.storage,
    this.auth,
    this.accessLog,
  });

  final VaultGroup group;
  final VaultStorage? storage;
  final VaultAuthService? auth;
  final VaultAccessLog? accessLog;

  @override
  State<VaultGroupDetailScreen> createState() => _VaultGroupDetailScreenState();
}

class _VaultGroupDetailScreenState extends State<VaultGroupDetailScreen> {
  late final VaultAuthService _auth;
  late final VaultAccessLog _accessLog;
  late final VaultStorage _storage;
  List<VaultSecret> _secrets = [];
  final Map<String, DateTime?> _lastAccessedTimes = {};
  final Set<String> _visibleSecretIds = {};
  final Map<String, Timer> _visibilityTimers = {};
  Timer? _clipboardTimer;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _auth = widget.auth ?? VaultAuthService();
    _accessLog = widget.accessLog ?? VaultAccessLog();
    _storage = widget.storage ?? VaultStorage();
    _loadSecrets();
  }

  @override
  void dispose() {
    for (final t in _visibilityTimers.values) {
      t.cancel();
    }
    _clipboardTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSecrets() async {
    final secrets = await _storage.loadByGroup(widget.group.id);
    final times = <String, DateTime?>{};
    for (final s in secrets) {
      times[s.id] = await _accessLog.lastAccessed(s.id);
    }
    
    if (mounted) {
      setState(() {
        _secrets = secrets;
        _lastAccessedTimes.addAll(times);
        _isLoading = false;
      });
    }
  }

  Future<void> _logAccess(VaultSecret secret, VaultAccessAction action) async {
    final now = DateTime.now();
    await _accessLog.log(VaultAccessEvent(
      secretId: secret.id,
      groupId: widget.group.id,
      action: action,
      timestamp: now,
    ));
    
    // Update lastUsedAt in storage
    final updated = secret.copyWith(lastUsedAt: now);
    await _storage.upsert(updated);
    
    if (mounted) {
      setState(() {
        _lastAccessedTimes[secret.id] = now;
        // Update the secret in the list so UI stays in sync if needed
        final idx = _secrets.indexWhere((s) => s.id == secret.id);
        if (idx != -1) {
          _secrets[idx] = updated;
        }
      });
    }
  }

  Future<void> _copySecret(VaultSecret secret) async {
    final success = await _auth.authenticate('Authenticate to copy secret');
    if (!success) return;

    await Clipboard.setData(ClipboardData(text: secret.value));
    await _logAccess(secret, VaultAccessAction.copied);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${secret.name} copied (clears in 30s)')),
      );
    }

    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == secret.value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  Future<void> _toggleVisibility(VaultSecret secret) async {
    if (_visibleSecretIds.contains(secret.id)) {
      setState(() {
        _visibleSecretIds.remove(secret.id);
        _visibilityTimers[secret.id]?.cancel();
        _visibilityTimers.remove(secret.id);
      });
      return;
    }

    final success = await _auth.authenticate('Authenticate to reveal secret');
    if (!success) return;

    await _logAccess(secret, VaultAccessAction.revealed);

    setState(() {
      _visibleSecretIds.add(secret.id);
    });

    _visibilityTimers[secret.id]?.cancel();
    _visibilityTimers[secret.id] = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {
          _visibleSecretIds.remove(secret.id);
          _visibilityTimers.remove(secret.id);
        });
      }
    });
  }

  void _copyAllPlaceholders() {
    final placeholders = _secrets
        .map((s) => '${s.name}=\${vault:${widget.group.name}.${s.name}}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: placeholders));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Placeholders copied to clipboard')),
    );
  }

  bool get _anyNeedsRotation {
    final now = DateTime.now();
    final threshold = now.add(const Duration(days: 7));
    return _secrets.any((s) => s.rotateBy != null && s.rotateBy!.isBefore(threshold));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: Text(widget.group.name.toUpperCase()),
        backgroundColor: AppColors.scaffoldBackground,
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            onPressed: _copyAllPlaceholders,
            tooltip: 'Use in command',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _Header(group: widget.group, needsRotation: _anyNeedsRotation),
                const SizedBox(height: 32),
                const Divider(color: AppColors.border),
                const SizedBox(height: 16),
                ..._secrets.map((s) => _FieldRow(
                      secret: s,
                      isVisible: _visibleSecretIds.contains(s.id),
                      lastAccessed: _lastAccessedTimes[s.id],
                      onCopy: () => _copySecret(s),
                      onToggleVisibility: () => _toggleVisibility(s),
                    )),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => VaultGroupEditScreen(group: widget.group, storage: _storage),
          ),
        ),
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onPrimary,
        child: const Icon(Icons.edit),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.group, this.needsRotation = false});
  final VaultGroup group;
  final bool needsRotation;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(_getIconData(group.icon), color: AppColors.accent, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                group.name,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
              ),
            ),
            if (needsRotation)
              const Tooltip(
                message: 'Secrets in this group are due for rotation',
                child: Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 24),
              ),
          ],
        ),
        if (group.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: group.tags.map((t) => Chip(
                  label: Text(t, style: const TextStyle(fontSize: 10)),
                  backgroundColor: AppColors.panel,
                  side: const BorderSide(color: AppColors.border),
                )).toList(),
          ),
        ],
        if (group.notes != null && group.notes!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            group.notes!,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ],
      ],
    );
  }

  IconData _getIconData(String name) {
    switch (name) {
      case 'cloud': return Icons.cloud_outlined;
      case 'cloud_queue': return Icons.cloud_queue;
      case 'storage': return Icons.storage_outlined;
      case 'dns': return Icons.dns_outlined;
      case 'payments': return Icons.payments_outlined;
      case 'code': return Icons.code;
      case 'vpn_key': return Icons.vpn_key_outlined;
      case 'api': return Icons.api_outlined;
      default: return Icons.enhanced_encryption_outlined;
    }
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.secret,
    required this.isVisible,
    this.lastAccessed,
    required this.onCopy,
    required this.onToggleVisibility,
  });

  final VaultSecret secret;
  final bool isVisible;
  final DateTime? lastAccessed;
  final VoidCallback onCopy;
  final VoidCallback onToggleVisibility;

  @override
  Widget build(BuildContext context) {
    String subtitle = 'Never accessed';
    if (lastAccessed != null) {
      final diff = DateTime.now().difference(lastAccessed!);
      if (diff.inDays > 0) {
        subtitle = 'Last accessed ${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
      } else if (diff.inHours > 0) {
        subtitle = 'Last accessed ${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
      } else if (diff.inMinutes > 0) {
        subtitle = 'Last accessed ${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
      } else {
        subtitle = 'Last accessed just now';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  secret.name,
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    color: AppColors.textFaint,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  isVisible ? secret.value : '••••••••',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    color: isVisible ? Colors.white : AppColors.textMuted,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(isVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: onToggleVisibility,
                iconSize: 20,
                color: AppColors.textMuted,
              ),
              IconButton(
                icon: const Icon(Icons.copy_outlined),
                onPressed: onCopy,
                iconSize: 20,
                color: AppColors.textMuted,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 0),
            child: Text(
              subtitle,
              style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
