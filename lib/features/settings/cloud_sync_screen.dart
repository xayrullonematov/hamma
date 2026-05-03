import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';
import '../../core/storage/backup_storage.dart';
import '../../core/theme/app_colors.dart';
import 'cloud_restore_screen.dart';
import 'cloud_sync_onboarding_screen.dart';

/// Brutalist cloud sync settings screen — Phase 5.
///
/// Lists the three opt-in cloud destinations (S3-compatible, iCloud,
/// Dropbox), shows their configured / unconfigured state, last sync
/// time, and provides "Sync now" / "Reconfigure" / "Restore" actions.
///
/// All cryptography happens through [BackupService] + [CloudSyncEngine];
/// this screen only orchestrates user intent.
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  final BackupStorage _storage = BackupStorage();
  final BackupService _service = BackupService();
  BackupConfig? _config;
  bool _syncing = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await _storage.loadConfig();
    if (mounted) setState(() => _config = cfg);
  }

  Future<void> _configure(BackupDestination dest) async {
    final updated = await Navigator.of(context).push<BackupConfig>(
      MaterialPageRoute<BackupConfig>(
        builder: (_) => CloudSyncOnboardingScreen(
          destination: dest,
          existing: _config,
        ),
      ),
    );
    if (updated != null) {
      await _storage.saveConfig(updated);
      await _load();
    }
  }

  Future<void> _syncNow() async {
    final cfg = _config;
    if (cfg == null || !cfg.isCloudDestination) return;
    setState(() {
      _syncing = true;
      _statusMessage = null;
    });
    try {
      // Reuse the legacy backup pipeline; BackupService routes cloud
      // destinations through CloudSyncEngine internally.
      final pwd = await _promptPassword();
      if (pwd == null) {
        setState(() => _syncing = false);
        return;
      }
      await _service.backupToDestination(manualPassword: pwd);
      if (!mounted) return;
      setState(() => _statusMessage = 'Sync complete');
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Sync failed: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
      if (mounted) await _load();
    }
  }

  Future<String?> _promptPassword() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('MASTER PASSWORD'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Encryption password',
            helperText: 'Used to derive Argon2id key. Not stored.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('CONFIRM'),
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
        backgroundColor: AppColors.scaffoldBackground,
        title: const Text('CLOUD SYNC'),
        actions: [
          IconButton(
            tooltip: 'Restore from cloud',
            icon: const Icon(Icons.restore_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CloudRestoreScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ZeroTrustBanner(),
          const SizedBox(height: 16),
          for (final dest in <BackupDestination>[
            BackupDestination.s3Compat,
            BackupDestination.dropbox,
            // iCloud only makes sense on Apple platforms — the
            // ubiquity-container APIs simply don't exist elsewhere.
            // `kIsWeb` short-circuits before touching `Platform`,
            // which would throw on web builds.
            if (!kIsWeb && (Platform.isIOS || Platform.isMacOS))
              BackupDestination.iCloud,
          ])
            _DestinationCard(
              destination: dest,
              isActive: _config?.destination == dest,
              isConfigured: _isConfigured(dest),
              lastSync: _config?.destination == dest
                  ? _config?.lastCloudSyncTime
                  : null,
              status: _config?.destination == dest
                  ? _config?.lastCloudSyncStatus
                  : null,
              syncing: _syncing && _config?.destination == dest,
              onConfigure: () => _configure(dest),
              onSync: _config?.destination == dest ? _syncNow : null,
            ),
          if (_statusMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _statusMessage!,
              style: const TextStyle(
                color: AppColors.accent,
                fontFamily: AppColors.monoFamily,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _isConfigured(BackupDestination dest) {
    final c = _config;
    if (c == null) return false;
    switch (dest) {
      case BackupDestination.s3Compat:
        return c.s3Endpoint.isNotEmpty &&
            c.s3Bucket.isNotEmpty &&
            c.s3AccessKeyId.isNotEmpty;
      case BackupDestination.dropbox:
        return c.dropboxAccessToken.isNotEmpty;
      case BackupDestination.iCloud:
        return c.iCloudContainerId.isNotEmpty;
      default:
        return false;
    }
  }
}

class _ZeroTrustBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'ZERO-TRUST: Providers see ciphertext only.\n'
              'Argon2id + AES-256-GCM. Keys never leave this device.',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  const _DestinationCard({
    required this.destination,
    required this.isActive,
    required this.isConfigured,
    required this.lastSync,
    required this.status,
    required this.syncing,
    required this.onConfigure,
    required this.onSync,
  });

  final BackupDestination destination;
  final bool isActive;
  final bool isConfigured;
  final DateTime? lastSync;
  final String? status;
  final bool syncing;
  final VoidCallback onConfigure;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: isActive ? AppColors.accent : AppColors.border,
          width: isActive ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(destination), color: AppColors.textPrimary),
              const SizedBox(width: 12),
              Text(
                _labelFor(destination),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontFamily: AppColors.sansFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              _StatusPill(
                syncing: syncing,
                isConfigured: isConfigured,
                status: status,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _descriptionFor(destination),
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (lastSync != null) ...[
            const SizedBox(height: 8),
            Text(
              'LAST SYNC: ${lastSync!.toLocal().toString().split('.')[0]}',
              style: const TextStyle(
                color: AppColors.textFaint,
                fontFamily: AppColors.monoFamily,
                fontSize: 10,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onConfigure,
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(isConfigured ? 'RECONFIGURE' : 'SET UP'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: isConfigured && !syncing ? onSync : null,
                  icon: syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: const Text('SYNC NOW'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(BackupDestination d) {
    switch (d) {
      case BackupDestination.s3Compat:
        return Icons.cloud_outlined;
      case BackupDestination.dropbox:
        return Icons.folder_shared_outlined;
      case BackupDestination.iCloud:
        return Icons.apple;
      default:
        return Icons.help_outline;
    }
  }

  static String _labelFor(BackupDestination d) {
    switch (d) {
      case BackupDestination.s3Compat:
        return 'S3-COMPATIBLE';
      case BackupDestination.dropbox:
        return 'DROPBOX';
      case BackupDestination.iCloud:
        return 'ICLOUD';
      default:
        return d.name.toUpperCase();
    }
  }

  static String _descriptionFor(BackupDestination d) {
    switch (d) {
      case BackupDestination.s3Compat:
        return 'AWS S3, Cloudflare R2, MinIO, Backblaze B2 — '
            'any S3-compatible endpoint with SigV4.';
      case BackupDestination.dropbox:
        return 'Dropbox app folder via OAuth bearer token.';
      case BackupDestination.iCloud:
        return 'Apple iCloud Drive ubiquity container '
            '(iOS/macOS only).';
      default:
        return '';
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.syncing,
    required this.isConfigured,
    required this.status,
  });

  final bool syncing;
  final bool isConfigured;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = () {
      if (syncing) return ('SYNCING', AppColors.accent);
      if (status?.startsWith('Failed') ?? false) {
        return ('FAILED', AppColors.danger);
      }
      if (!isConfigured) return ('NOT SET', AppColors.textFaint);
      return ('READY', AppColors.accent);
    }();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontFamily: AppColors.monoFamily,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}
