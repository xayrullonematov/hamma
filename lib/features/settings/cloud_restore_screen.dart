import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';
import '../../core/storage/backup_storage.dart';
import '../../core/theme/app_colors.dart';

/// Restore-on-new-device flow.
///
/// Loads the saved [BackupConfig] (which must already be a cloud
/// destination — the user provided creds either via the onboarding
/// wizard or by importing a config), prompts for the master password,
/// then asks [BackupService] to pull the latest manifest entry,
/// decrypt it, and overwrite the local secure storage.
class CloudRestoreScreen extends StatefulWidget {
  const CloudRestoreScreen({super.key});

  @override
  State<CloudRestoreScreen> createState() => _CloudRestoreScreenState();
}

class _CloudRestoreScreenState extends State<CloudRestoreScreen> {
  final BackupStorage _storage = BackupStorage();
  final BackupService _service = BackupService();
  final TextEditingController _password = TextEditingController();
  BackupConfig? _config;
  bool _restoring = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _storage.loadConfig().then((c) {
      if (mounted) setState(() => _config = c);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final cfg = _config;
    if (cfg == null || !cfg.isCloudDestination) {
      setState(() => _error = 'No cloud destination is configured.');
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = 'Master password is required.');
      return;
    }
    setState(() {
      _restoring = true;
      _error = null;
      _success = null;
    });
    try {
      await _service.restoreFromDestination(
        manualPassword: _password.text,
      );
      if (!mounted) return;
      setState(() => _success = 'Restore complete. Restart the app.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      // Clear the master password from memory ASAP — defence in depth.
      _password.clear();
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        title: const Text('CLOUD RESTORE'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.danger, width: 2),
            ),
            child: const Text(
              'WARNING — Restoring overwrites this device\'s vault with '
              'the latest snapshot from your cloud provider. Existing '
              'unsynced data will be lost.',
              style: TextStyle(
                color: AppColors.danger,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (cfg == null)
            const Text('Loading configuration…',
                style: TextStyle(color: AppColors.textMuted))
          else if (!cfg.isCloudDestination)
            const Text(
              'No cloud destination is configured. Open Cloud Sync to '
              'set one up first.',
              style: TextStyle(color: AppColors.textMuted),
            )
          else ...[
            Text(
              'PROVIDER: ${cfg.destination.name.toUpperCase()}',
              style: const TextStyle(
                color: AppColors.accent,
                fontFamily: AppColors.monoFamily,
                fontSize: 12,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Master password',
                helperText:
                    'Same password used when the snapshot was created.',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _restoring ? null : _restore,
              icon: _restoring
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined),
              label: const Text('PULL & DECRYPT LATEST'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(
                color: AppColors.danger,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
              ),
            ),
          ],
          if (_success != null) ...[
            const SizedBox(height: 16),
            Text(
              _success!,
              style: const TextStyle(
                color: AppColors.accent,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
