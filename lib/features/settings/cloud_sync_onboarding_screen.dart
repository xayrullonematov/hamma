import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';
import '../../core/backup/cloud_sync_engine.dart';
import '../../core/storage/backup_storage.dart';
import '../../core/theme/app_colors.dart';

/// 4-step brutalist wizard for configuring a cloud destination.
///
/// Steps: 1) PICK (already chosen via [destination]), 2) AUTH (creds),
/// 3) ENCRYPT (cadence + remind about master password), 4) VERIFY
/// (lightweight `isConfigured` ping). Returns the new [BackupConfig]
/// to the caller via Navigator.pop.
class CloudSyncOnboardingScreen extends StatefulWidget {
  const CloudSyncOnboardingScreen({
    super.key,
    required this.destination,
    this.existing,
  });

  final BackupDestination destination;
  final BackupConfig? existing;

  @override
  State<CloudSyncOnboardingScreen> createState() =>
      _CloudSyncOnboardingScreenState();
}

class _CloudSyncOnboardingScreenState
    extends State<CloudSyncOnboardingScreen> {
  int _step = 0;
  CloudSyncCadence _cadence = CloudSyncCadence.daily;
  bool _verifying = false;
  String? _verifyError;

  // S3 controllers
  final _s3Endpoint = TextEditingController();
  final _s3Region = TextEditingController(text: 'us-east-1');
  final _s3Bucket = TextEditingController();
  final _s3Key = TextEditingController();
  final _s3Secret = TextEditingController();
  final _s3Prefix = TextEditingController(text: 'hamma/');
  bool _s3PathStyle = false;

  // Dropbox controllers
  final _dbxToken = TextEditingController();
  final _dbxFolder = TextEditingController(text: '/Apps/Hamma');

  // iCloud controllers
  final _icContainer = TextEditingController();
  final _icFolder = TextEditingController(text: 'Hamma');

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null && e.destination == widget.destination) {
      _cadence = e.cloudCadence;
      _s3Endpoint.text = e.s3Endpoint;
      if (e.s3Region.isNotEmpty) _s3Region.text = e.s3Region;
      _s3Bucket.text = e.s3Bucket;
      _s3Key.text = e.s3AccessKeyId;
      _s3Secret.text = e.s3SecretAccessKey;
      if (e.s3Prefix.isNotEmpty) _s3Prefix.text = e.s3Prefix;
      _s3PathStyle = e.s3UsePathStyle;
      _dbxToken.text = e.dropboxAccessToken;
      if (e.dropboxAppFolder.isNotEmpty) _dbxFolder.text = e.dropboxAppFolder;
      _icContainer.text = e.iCloudContainerId;
      if (e.iCloudFolder.isNotEmpty) _icFolder.text = e.iCloudFolder;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _s3Endpoint, _s3Region, _s3Bucket, _s3Key, _s3Secret, _s3Prefix,
      _dbxToken, _dbxFolder, _icContainer, _icFolder,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  BackupConfig _buildConfig() {
    final base = widget.existing ??
        const BackupConfig(destination: BackupDestination.local);
    return base.copyWith(
      destination: widget.destination,
      cloudCadence: _cadence,
      cloudDeviceId: base.cloudDeviceId.isEmpty
          ? generateDeviceId()
          : base.cloudDeviceId,
      s3Endpoint: _s3Endpoint.text.trim(),
      s3Region: _s3Region.text.trim(),
      s3Bucket: _s3Bucket.text.trim(),
      s3AccessKeyId: _s3Key.text.trim(),
      s3SecretAccessKey: _s3Secret.text,
      s3Prefix: _s3Prefix.text.trim(),
      s3UsePathStyle: _s3PathStyle,
      dropboxAccessToken: _dbxToken.text.trim(),
      dropboxAppFolder: _dbxFolder.text.trim(),
      iCloudContainerId: _icContainer.text.trim(),
      iCloudFolder: _icFolder.text.trim(),
    );
  }

  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _verifyError = null;
    });
    try {
      final cfg = _buildConfig();
      final adapter = BackupService.buildCloudAdapter(cfg);
      if (!adapter.isConfigured) {
        throw const FormatException('Required fields are missing.');
      }
      // Smoke test: list (cheap, read-only). Adapters tolerate empty.
      await adapter.list();
      if (mounted) Navigator.of(context).pop(cfg);
    } catch (e) {
      setState(() => _verifyError = e.toString());
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        title: Text('SETUP — ${widget.destination.name.toUpperCase()}'),
      ),
      body: Column(
        children: [
          _StepBar(step: _step),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildStep(),
            ),
          ),
          _NavBar(
            step: _step,
            onBack: _step == 0 ? null : () => setState(() => _step--),
            onNext: _step < 3
                ? () => setState(() => _step++)
                : (_verifying ? null : _verify),
            nextLabel: _step < 3 ? 'NEXT' : 'VERIFY & SAVE',
            verifying: _verifying,
          ),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _StepIntro(destination: widget.destination);
      case 1:
        return _buildAuthStep();
      case 2:
        return _buildCadenceStep();
      case 3:
      default:
        return _buildVerifyStep();
    }
  }

  Widget _buildAuthStep() {
    switch (widget.destination) {
      case BackupDestination.s3Compat:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_s3Endpoint, 'Endpoint URL',
                'e.g. https://s3.us-east-1.amazonaws.com'),
            _field(_s3Region, 'Region', 'e.g. us-east-1'),
            _field(_s3Bucket, 'Bucket', ''),
            _field(_s3Key, 'Access Key ID', ''),
            _field(_s3Secret, 'Secret Access Key', '', obscure: true),
            _field(_s3Prefix, 'Prefix (optional)', 'hamma/'),
            SwitchListTile(
              value: _s3PathStyle,
              onChanged: (v) => setState(() => _s3PathStyle = v),
              title: const Text('Path-style addressing'),
              subtitle: const Text('Use for MinIO / non-AWS endpoints'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        );
      case BackupDestination.dropbox:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_dbxToken, 'OAuth Access Token', 'sl.B...',
                obscure: true),
            _field(_dbxFolder, 'App Folder', '/Apps/Hamma'),
          ],
        );
      case BackupDestination.iCloud:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_icContainer, 'iCloud Container ID',
                'iCloud.com.hamma.app'),
            _field(_icFolder, 'Folder', 'Hamma'),
            const SizedBox(height: 8),
            const Text(
              'iCloud is only available on iOS / macOS.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildCadenceStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'SYNC CADENCE',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontFamily: AppColors.sansFamily,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        for (final c in CloudSyncCadence.values)
          RadioListTile<CloudSyncCadence>(
            value: c,
            groupValue: _cadence,
            onChanged: (v) =>
                v == null ? null : setState(() => _cadence = v),
            title: Text(c.name.toUpperCase()),
            contentPadding: EdgeInsets.zero,
          ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.accent),
          ),
          child: const Text(
            'Each sync re-derives the encryption key from your master '
            'password using Argon2id. The password is never sent to the '
            'provider and never stored on disk.',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVerifyStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'READY TO VERIFY',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontFamily: AppColors.sansFamily,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Tapping VERIFY & SAVE performs a read-only listing call to '
          'confirm credentials are valid. No data is uploaded yet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        if (_verifyError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.danger),
            ),
            child: Text(
              _verifyError!,
              style: const TextStyle(
                color: AppColors.danger,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _field(TextEditingController c, String label, String hint,
      {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          helperText: hint.isEmpty ? null : hint,
        ),
      ),
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    const labels = ['INTRO', 'AUTH', 'ENCRYPT', 'VERIFY'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: i == step ? AppColors.accent : AppColors.border,
                    width: i == step ? 2 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${i + 1}. ${labels[i]}',
                  style: TextStyle(
                    color: i == step
                        ? AppColors.accent
                        : AppColors.textMuted,
                    fontFamily: AppColors.monoFamily,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            if (i < labels.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class _StepIntro extends StatelessWidget {
  const _StepIntro({required this.destination});
  final BackupDestination destination;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ZERO-TRUST CLOUD SYNC',
          style: TextStyle(
            color: AppColors.accent,
            fontFamily: AppColors.sansFamily,
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Hamma encrypts every snapshot on this device before it is sent. '
          'The cloud provider stores opaque ciphertext blobs only — it '
          'cannot read your servers, AI keys, or chat history.',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '• Argon2id key derivation\n'
          '• AES-256-GCM authenticated encryption\n'
          '• HMBK v2 ciphertext header (verified before every upload)\n'
          '• Per-device manifest with newer-wins conflict resolution',
          style: TextStyle(
            color: AppColors.textMuted,
            fontFamily: AppColors.monoFamily,
            fontSize: 11,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.step,
    required this.onBack,
    required this.onNext,
    required this.nextLabel,
    required this.verifying,
  });

  final int step;
  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final String nextLabel;
  final bool verifying;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: onBack,
              child: const Text('BACK'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: onNext,
              child: verifying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(nextLabel),
            ),
          ),
        ],
      ),
    );
  }
}
