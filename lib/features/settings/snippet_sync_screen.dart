import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';
import '../../core/storage/backup_storage.dart';
import '../../core/sync/snippet_sync_service.dart';
import '../../core/sync/snippet_sync_storage.dart';
import '../../core/theme/app_colors.dart';

/// Brutalist settings screen for the opt-in cross-device snippet
/// sharing feature. Toggle is gated on a configured cloud destination
/// — if none is set, the screen surfaces a hand-off to Cloud Sync
/// rather than letting the user enable a no-op.
class SnippetSyncScreen extends StatefulWidget {
  const SnippetSyncScreen({super.key});

  @override
  State<SnippetSyncScreen> createState() => _SnippetSyncScreenState();
}

class _SnippetSyncScreenState extends State<SnippetSyncScreen> {
  final SnippetSyncStorage _storage = const SnippetSyncStorage();
  final BackupStorage _backupStorage = const BackupStorage();
  final SnippetSyncService _service = SnippetSyncService();

  bool _enabled = false;
  bool _loading = true;
  bool _syncing = false;
  BackupConfig? _backupConfig;
  bool _adapterReady = false;
  DateTime? _lastSyncAt;
  List<SnippetSyncHistoryEntry> _history = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _storage.isEnabled();
    final backup = await _backupStorage.loadConfig();
    final last = await _storage.getLastSyncAt();
    final history = await _storage.loadHistory();
    // Gate enable on a *fully* configured adapter, not just the
    // destination type — `isCloudDestination` returns true even when
    // credentials are missing, which would let the user enable a
    // no-op sync.
    var adapterReady = false;
    if (backup.isCloudDestination) {
      try {
        final adapter = BackupService.buildCloudAdapter(backup);
        adapterReady = adapter.isConfigured;
      } catch (_) {
        adapterReady = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _backupConfig = backup;
      _adapterReady = adapterReady;
      _lastSyncAt = last;
      _history = history;
      _loading = false;
    });
  }

  Future<void> _toggle(bool value) async {
    await _storage.setEnabled(value);
    // The long-lived bus subscription is owned by the app-level
    // service instance started in `main.dart`; both push() and
    // pull() are runtime-gated on `isEnabled()`, so flipping the
    // flag here is sufficient — no need to start/stop a second
    // service from the UI.
    if (value) {
      // Kick off an initial pull-merge-push so users with existing
      // snippets start syncing without having to edit one or wait
      // for the next launch.
      setState(() => _syncing = true);
      try {
        await _service.pullAndMerge();
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
    }
    await _load();
  }

  Future<void> _syncNow({required bool pull}) async {
    setState(() => _syncing = true);
    try {
      if (pull) {
        await _service.pullAndMerge();
      } else {
        await _service.pushNow();
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
        await _load();
      }
    }
  }

  bool get _cloudReady =>
      (_backupConfig?.isCloudDestination ?? false) && _adapterReady;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(title: const Text('Snippet Sync')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _intro(),
                  const SizedBox(height: 16),
                  if (!_cloudReady) _noCloudCard() else _toggleCard(),
                  const SizedBox(height: 16),
                  _statusCard(),
                  const SizedBox(height: 16),
                  _historyCard(),
                ],
              ),
      ),
    );
  }

  Widget _intro() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CROSS-DEVICE SNIPPETS',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              color: AppColors.accent,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Reuses your encrypted cloud-sync transport to push your '
            'custom quick-action snippets to every Hamma install. Blobs '
            'are encrypted with your master PIN before they leave the '
            'device — the cloud provider never sees plaintext.',
            style: TextStyle(color: AppColors.textMuted, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _noCloudCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(left: BorderSide(color: AppColors.danger, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NO CLOUD DESTINATION',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              color: AppColors.danger,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            (_backupConfig?.isCloudDestination ?? false)
                ? 'Your cloud destination is selected but its credentials '
                    'are incomplete. Open Settings → Backup & Restore → '
                    'Cloud Sync and finish configuring it, then return '
                    'here to flip the switch.'
                : 'Snippet sync rides on top of Cloud Sync. Configure a '
                    'cloud destination first (Settings → Backup & '
                    'Restore → Cloud Sync), then return here to flip '
                    'the switch.',
            style: const TextStyle(color: AppColors.textMuted, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _toggleCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: SwitchListTile(
        value: _enabled,
        onChanged: (_syncing || !_cloudReady) ? null : _toggle,
        activeColor: AppColors.accent,
        title: const Text(
          'Sync snippets across devices',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        subtitle: const Text(
          'Push on edit (3-second debounce). Pull-and-merge on launch.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      ),
    );
  }

  Widget _statusCard() {
    final last = _lastSyncAt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'STATUS',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              color: AppColors.accent,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            last == null
                ? 'No sync yet.'
                : 'Last sync: ${last.toLocal()}',
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_enabled && _cloudReady && !_syncing)
                      ? () => _syncNow(pull: false)
                      : null,
                  icon: _syncing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: const Text('PUSH NOW'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: const BorderSide(color: AppColors.accent),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_enabled && _cloudReady && !_syncing)
                      ? () => _syncNow(pull: true)
                      : null,
                  icon: const Icon(Icons.cloud_download_outlined, size: 16),
                  label: const Text('PULL & MERGE'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: const BorderSide(color: AppColors.accent),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _historyCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HISTORY (LAST ${_history.length})',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              color: AppColors.accent,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          if (_history.isEmpty)
            const Text(
              'No sync events yet.',
              style: TextStyle(color: AppColors.textMuted),
            )
          else
            ..._history.map((e) {
              final color =
                  e.success ? AppColors.accent : AppColors.danger;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      e.success
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 14,
                      color: color,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${e.operation.toUpperCase()} · '
                            '${e.timestamp.toLocal()}',
                            style: TextStyle(
                              fontFamily: AppColors.monoFamily,
                              fontSize: 12,
                              color: color,
                            ),
                          ),
                          if (e.message != null)
                            Text(
                              e.message!,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
