import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/vault/vault_export_service.dart';

class VaultExportScreen extends StatefulWidget {
  const VaultExportScreen({super.key, this.service});

  final VaultExportService? service;

  @override
  State<VaultExportScreen> createState() => _VaultExportScreenState();
}

class _VaultExportScreenState extends State<VaultExportScreen> {
  late final VaultExportService _service;
  final _exportPassController = TextEditingController();
  final _exportConfirmController = TextEditingController();
  final _importPassController = TextEditingController();

  bool _isExporting = false;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? VaultExportService();
  }

  @override
  void dispose() {
    _exportPassController.dispose();
    _exportConfirmController.dispose();
    _importPassController.dispose();
    super.dispose();
  }

  double _calculateStrength(String pass) {
    if (pass.isEmpty) return 0;
    double strength = 0;
    if (pass.length >= 8) strength += 0.2;
    if (pass.length >= 12) strength += 0.2;
    if (RegExp(r'[A-Z]').hasMatch(pass)) strength += 0.2;
    if (RegExp(r'[0-9]').hasMatch(pass)) strength += 0.2;
    if (RegExp(r'[!@#\$&*~]').hasMatch(pass)) strength += 0.2;
    return strength;
  }

  Future<void> _handleExport() async {
    final pass = _exportPassController.text;
    final confirm = _exportConfirmController.text;

    if (pass.isEmpty) {
      _showError('Passphrase cannot be empty.');
      return;
    }
    if (pass != confirm) {
      _showError('Passphrases do not match.');
      return;
    }
    if (_calculateStrength(pass) < 0.6) {
      _showError('Passphrase is too weak. Use a longer one with mixed characters.');
      return;
    }

    setState(() => _isExporting = true);
    try {
      final bytes = await _service.export(pass);
      final fileName = 'hamma_vault_${DateTime.now().millisecondsSinceEpoch}.hmvt';

      if (Platform.isAndroid || Platform.isIOS) {
        final xfile = XFile.fromData(bytes, name: fileName, mimeType: 'application/octet-stream');
        await Share.shareXFiles([xfile], subject: 'Hamma Vault Export');
      } else {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Vault Export',
          fileName: fileName,
          type: FileType.any,
        );
        if (path != null) {
          await File(path).writeAsBytes(bytes);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Vault exported successfully.')),
            );
          }
        }
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleImport() async {
    final pass = _importPassController.text;
    if (pass.isEmpty) {
      _showError('Please enter the decryption passphrase.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    Uint8List? bytes;
    if (file.bytes != null) {
      bytes = file.bytes;
    } else if (file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }

    if (bytes == null) {
      _showError('Could not read the selected file.');
      return;
    }

    setState(() => _isImporting = true);
    try {
      final importResult = await _service.import(bytes, pass);
      if (mounted) {
        _showResultDialog(importResult);
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.danger),
    );
  }

  void _showResultDialog(VaultImportResult result) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('IMPORT COMPLETE', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Imported: ${result.imported}', style: const TextStyle(color: Colors.white)),
            Text('Skipped (local newer): ${result.skipped}', style: const TextStyle(color: AppColors.textMuted)),
            Text('Updated existing: ${result.conflicts}', style: const TextStyle(color: AppColors.textMuted)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strength = _calculateStrength(_exportPassController.text);

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text('VAULT EXPORT / IMPORT'),
        backgroundColor: AppColors.scaffoldBackground,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildSectionHeader('ENCRYPTED EXPORT'),
          const SizedBox(height: 16),
          const Text(
            'Create a password-protected backup of your entire vault. '
            'This file contains all your groups and secrets in an encrypted format.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          _buildTextField(
            controller: _exportPassController,
            label: 'PASSPHRASE',
            isObscure: true,
            onChanged: (v) => setState(() {}),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: strength,
            backgroundColor: AppColors.panel,
            valueColor: AlwaysStoppedAnimation<Color>(
              strength < 0.4 ? AppColors.danger : (strength < 0.8 ? Colors.amber : AppColors.accent),
            ),
          ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _exportConfirmController,
            label: 'CONFIRM PASSPHRASE',
            isObscure: true,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.1),
              border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'If you lose this passphrase, your export cannot be recovered. We have no way to help you.',
                    style: TextStyle(color: AppColors.danger, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _isExporting ? null : _handleExport,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.onPrimary,
              ),
              child: _isExporting
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('GENERATE EXPORT FILE'),
            ),
          ),
          const SizedBox(height: 48),
          _buildSectionHeader('IMPORT VAULT'),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _importPassController,
            label: 'DECRYPTION PASSPHRASE',
            isObscure: true,
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: _isImporting ? null : _handleImport,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.border),
                foregroundColor: Colors.white,
              ),
              child: _isImporting
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('PICK FILE & IMPORT'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: AppColors.monoFamily,
        color: AppColors.textFaint,
        fontSize: 12,
        letterSpacing: 2,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    bool isObscure = false,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: isObscure,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14, fontFamily: AppColors.monoFamily),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textFaint, fontSize: 12),
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
        filled: true,
        fillColor: AppColors.surface,
      ),
    );
  }
}
