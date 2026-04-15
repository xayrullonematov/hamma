import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/backup/backup_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/storage/app_lock_storage.dart';
import '../security/app_lock_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialProvider,
    required this.initialApiKey,
    required this.initialOpenRouterModel,
    required this.onSaveAiSettings,
    this.onBackupImported,
  });

  final AiProvider initialProvider;
  final String initialApiKey;
  final String? initialOpenRouterModel;
  final Future<void> Function(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
  )
  onSaveAiSettings;
  final Future<void> Function()? onBackupImported;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);
  static const _openRouterModelsUrl = 'https://openrouter.ai/api/v1/models';

  late final TextEditingController _apiKeyController;
  late final TextEditingController _openRouterModelController;
  final AppLockStorage _appLockStorage = const AppLockStorage();
  final BackupService _backupService = const BackupService();
  final ApiKeyStorage _apiKeyStorage = const ApiKeyStorage();
  late AiProvider _selectedProvider;
  String? _openRouterModel;
  bool _isSaving = false;
  bool _isExportingBackup = false;
  bool _isImportingBackup = false;
  bool? _hasAppPin;
  bool _isLoadingOpenRouterModels = false;
  bool _hasLoadedOpenRouterModels = false;
  String? _openRouterModelsError;
  List<String> _openRouterModels = const [];
  String _status = '';

  bool get _isBusy => _isSaving || _isExportingBackup || _isImportingBackup;

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialProvider;
    _openRouterModel = _normalizeOpenRouterModel(widget.initialOpenRouterModel);
    _apiKeyController = TextEditingController(text: widget.initialApiKey);
    _openRouterModelController = TextEditingController(
      text: _openRouterModel ?? '',
    );
    _loadAppPinStatus();
    if (_selectedProvider == AiProvider.openRouter) {
      _loadOpenRouterModels();
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _openRouterModelController.dispose();
    super.dispose();
  }

  String? _normalizeOpenRouterModel(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> _save() async {
    final apiKey = _apiKeyController.text.trim();
    final resolvedOpenRouterModel = _normalizeOpenRouterModel(
      _openRouterModelController.text,
    );

    setState(() {
      _isSaving = true;
      _status = apiKey.isEmpty ? 'Clearing API key' : 'Saving AI settings';
      _openRouterModel = resolvedOpenRouterModel;
    });

    try {
      await widget.onSaveAiSettings(
        _selectedProvider,
        apiKey,
        resolvedOpenRouterModel,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _status = apiKey.isEmpty ? 'API key cleared.' : 'AI settings saved.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to save AI settings: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<String?> _promptForMasterPassword({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final controller = TextEditingController();

    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          String? errorText;

          return StatefulBuilder(
            builder: (context, setDialogState) {
              void submit() {
                final password = controller.text;
                if (password.trim().isEmpty) {
                  setDialogState(() {
                    errorText = 'Master password is required.';
                  });
                  return;
                }

                Navigator.of(dialogContext).pop(password);
              }

              return AlertDialog(
                title: Text(title),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        labelText: 'Master Password',
                        errorText: errorText,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(onPressed: submit, child: Text(confirmLabel)),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _exportBackup() async {
    final password = await _promptForMasterPassword(
      title: 'Create Master Password',
      message:
          'Choose a master password to encrypt your backup file. You will need the same password to restore it later.',
      confirmLabel: 'Export Backup',
    );
    if (password == null) {
      return;
    }

    setState(() {
      _isExportingBackup = true;
    });

    try {
      await _backupService.exportBackup(password);
      if (!mounted) {
        return;
      }

      _showSnackBar('Backup exported. Use the share sheet to save it.');
    } catch (error) {
      if (!mounted) {
        return;
      }

      _showSnackBar(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isExportingBackup = false;
        });
      }
    }
  }

  Future<void> _importBackup() async {
    final pickedFile = await FilePicker.platform.pickFiles();
    if (pickedFile == null || pickedFile.files.isEmpty) {
      return;
    }

    final filePath = pickedFile.files.single.path;
    if (filePath == null || filePath.trim().isEmpty) {
      _showSnackBar('Selected backup file could not be opened.');
      return;
    }

    final password = await _promptForMasterPassword(
      title: 'Enter Master Password',
      message:
          'Enter the master password that was used when this backup file was created.',
      confirmLabel: 'Import Backup',
    );
    if (password == null) {
      return;
    }

    setState(() {
      _isImportingBackup = true;
    });

    try {
      await _backupService.importBackup(password, filePath);
      final importedSettings = await _apiKeyStorage.loadSettings();

      await widget.onSaveAiSettings(
        importedSettings.provider,
        importedSettings.apiKey,
        importedSettings.openRouterModel,
      );

      final onBackupImported = widget.onBackupImported;
      if (onBackupImported != null) {
        await onBackupImported();
      }

      if (!mounted) {
        return;
      }

      _showSnackBar('Backup restored successfully.');
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) {
        return;
      }

      _showSnackBar(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isImportingBackup = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _launchFeedbackEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@example.com',
      queryParameters: const {'subject': 'Hamma Beta Feedback'},
    );

    try {
      await launchUrl(uri);
    } catch (_) {
      // Ignore launch failures when no email client is available.
    }
  }

  Future<void> _loadAppPinStatus() async {
    try {
      final hasPin = await _appLockStorage.hasPin();
      if (!mounted) {
        return;
      }

      setState(() {
        _hasAppPin = hasPin;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _hasAppPin = false;
      });
    }
  }

  Future<void> _openAppLockSettings() async {
    final hasAppPin = _hasAppPin;
    if (hasAppPin == null) {
      return;
    }

    final didChange = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder:
            (_) => AppLockScreen(
              mode: hasAppPin ? AppLockMode.remove : AppLockMode.setup,
              appLockStorage: _appLockStorage,
            ),
      ),
    );

    if (didChange == true && mounted) {
      await _loadAppPinStatus();
    }
  }

  Future<void> _loadOpenRouterModels({bool forceRefresh = false}) async {
    if (_isLoadingOpenRouterModels) {
      return;
    }

    if (_hasLoadedOpenRouterModels && !forceRefresh) {
      return;
    }

    setState(() {
      _isLoadingOpenRouterModels = true;
      _openRouterModelsError = null;
    });

    try {
      final response = await http
          .get(Uri.parse(_openRouterModelsUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'OpenRouter model list request failed with status ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('OpenRouter model response was invalid.');
      }

      final data = decoded['data'];
      if (data is! List) {
        throw const FormatException('OpenRouter model response was invalid.');
      }

      final models =
          data
              .whereType<Map>()
              .map((item) => (item['id'] ?? '').toString().trim())
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      final selectedModel = _normalizeOpenRouterModel(_openRouterModel);
      if (selectedModel != null && !models.contains(selectedModel)) {
        models.insert(0, selectedModel);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _openRouterModels = models;
        _openRouterModelsError = null;
        _hasLoadedOpenRouterModels = true;
      });
      _openRouterModelController.text = _openRouterModel ?? '';
    } on TimeoutException {
      if (!mounted) {
        return;
      }

      setState(() {
        _openRouterModelsError =
            'OpenRouter model list request timed out. Try again.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _openRouterModelsError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingOpenRouterModels = false;
        });
      }
    }
  }

  void _handleProviderChanged(AiProvider provider) {
    setState(() {
      _selectedProvider = provider;
      _openRouterModel = _normalizeOpenRouterModel(
        _openRouterModelController.text,
      );
    });

    if (provider == AiProvider.openRouter) {
      _loadOpenRouterModels();
    }
  }

  Widget _buildOpenRouterModelSelector(ThemeData theme) {
    if (_isLoadingOpenRouterModels) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Loading OpenRouter models...',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _mutedColor,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_openRouterModelsError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _openRouterModelsError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _mutedColor,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  _isBusy
                      ? null
                      : () => _loadOpenRouterModels(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry Model Fetch'),
            ),
          ],
        ),
      );
    }

    return DropdownMenu<String>(
      controller: _openRouterModelController,
      initialSelection: _openRouterModel,
      enabled: !_isBusy,
      enableFilter: true,
      enableSearch: true,
      requestFocusOnTap: true,
      width: double.infinity,
      label: const Text('OpenRouter Model'),
      hintText: 'Search models',
      helperText: 'Choose a model for command generation and chat.',
      dropdownMenuEntries:
          _openRouterModels
              .map(
                (modelId) =>
                    DropdownMenuEntry<String>(value: modelId, label: modelId),
              )
              .toList(),
      onSelected: (value) {
        setState(() {
          _openRouterModel = _normalizeOpenRouterModel(value);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 24),
          children: [
            _SettingsSectionCard(
              title: 'AI Configuration',
              subtitle:
                  'Choose your AI provider and manage the API key used by the copilot.',
              icon: Icons.smart_toy_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Theme(
                    data: theme.copyWith(canvasColor: _panelColor),
                    child: DropdownButtonFormField<AiProvider>(
                      // ignore: deprecated_member_use
                      value: _selectedProvider,
                      decoration: const InputDecoration(
                        labelText: 'AI Provider',
                      ),
                      items:
                          AiProvider.values.map((provider) {
                            return DropdownMenuItem<AiProvider>(
                              value: provider,
                              child: Text(provider.label),
                            );
                          }).toList(),
                      onChanged:
                          _isBusy
                              ? null
                              : (provider) {
                                if (provider == null) {
                                  return;
                                }

                                _handleProviderChanged(provider);
                              },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _panelColor,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      _selectedProvider.helperText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _mutedColor,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _apiKeyController,
                    enabled: !_isBusy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Enter API Key',
                      helperText: 'Leave blank to clear the saved API key.',
                    ),
                  ),
                  if (_selectedProvider == AiProvider.openRouter) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _panelColor,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        'OpenRouter requires a specific model selection. Saved model: ${_openRouterModel ?? 'Default'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _mutedColor,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildOpenRouterModelSelector(theme),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _isBusy ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child:
                  _isSaving
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Text('Save'),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _mutedColor,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 20),
            _SettingsSectionCard(
              title: 'Security',
              subtitle:
                  'Protect local app access with a custom 4-digit PIN and optional biometric unlock.',
              icon: Icons.lock_outline,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _panelColor,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      _hasAppPin == null
                          ? 'Checking app lock status...'
                          : _hasAppPin!
                          ? 'App lock is enabled. Remove the current PIN from this device.'
                          : 'No app PIN is set. Add one to require PIN or biometric unlock on launch.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _mutedColor,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed:
                          _hasAppPin == null || _isBusy
                              ? null
                              : _openAppLockSettings,
                      icon: Icon(
                        _hasAppPin == true
                            ? Icons.lock_open_outlined
                            : Icons.pin_outlined,
                      ),
                      label: Text(
                        _hasAppPin == true ? 'Remove App PIN' : 'Set App PIN',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _SettingsSectionCard(
              title: 'Backup & Restore',
              subtitle:
                  'Create an AES-256 encrypted backup file for saved servers and AI settings, then restore it locally later.',
              icon: Icons.cloud_sync_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _panelColor,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'Your backup stays local. Export creates an encrypted file and opens the native share sheet so you can save it to cloud storage yourself.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _mutedColor,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _isBusy ? null : _exportBackup,
                      icon:
                          _isExportingBackup
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.upload_file_outlined),
                      label: Text(
                        _isExportingBackup
                            ? 'Exporting Backup'
                            : 'Export Backup',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isBusy ? null : _importBackup,
                      icon:
                          _isImportingBackup
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.download_outlined),
                      label: Text(
                        _isImportingBackup
                            ? 'Importing Backup'
                            : 'Import Backup',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _SettingsSectionCard(
              title: 'About & Support',
              subtitle:
                  'Send beta feedback, report bugs, or share issues you find while using Hamma.',
              icon: Icons.mail_outline,
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isBusy ? null : _launchFeedbackEmail,
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('Send Feedback / Report Bug'),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Hamma v1.0.0 (Beta)',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _mutedColor,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSectionCard extends StatelessWidget {
  const _SettingsSectionCard({
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
        color: _SettingsScreenState._surfaceColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: _SettingsScreenState._shadowColor,
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
                child: Icon(icon, color: theme.colorScheme.primary),
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
                        color: _SettingsScreenState._mutedColor,
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
