import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/background/background_keepalive.dart';
import '../../core/backup/backup_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/storage/app_lock_storage.dart';
import '../../core/storage/app_prefs_storage.dart';
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
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _openRouterModelsUrl = 'https://openrouter.ai/api/v1/models';

  late final TextEditingController _openAiApiKeyController;
  late final TextEditingController _geminiApiKeyController;
  late final TextEditingController _openRouterApiKeyController;
  late final TextEditingController _openRouterModelController;
  final AppLockStorage _appLockStorage = const AppLockStorage();
  final BackupService _backupService = const BackupService();
  final ApiKeyStorage _apiKeyStorage = const ApiKeyStorage();
  final AppPrefsStorage _appPrefsStorage = const AppPrefsStorage();

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

  bool _healthMonitoringEnabled = false;
  int _healthCheckInterval = 30;

  bool get _isBusy => _isSaving || _isExportingBackup || _isImportingBackup;

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialProvider;
    _openRouterModel = _normalizeOpenRouterModel(widget.initialOpenRouterModel);
    _openAiApiKeyController = TextEditingController(
      text:
          widget.initialProvider == AiProvider.openAi
              ? widget.initialApiKey
              : '',
    );
    _geminiApiKeyController = TextEditingController(
      text:
          widget.initialProvider == AiProvider.gemini
              ? widget.initialApiKey
              : '',
    );
    _openRouterApiKeyController = TextEditingController(
      text:
          widget.initialProvider == AiProvider.openRouter
              ? widget.initialApiKey
              : '',
    );
    _openRouterModelController = TextEditingController(
      text: _openRouterModel ?? '',
    );
    _loadStoredApiKeys();
    _loadAppPinStatus();
    _loadHealthMonitoringSettings();
    if (_selectedProvider == AiProvider.openRouter) {
      _loadOpenRouterModels();
    }
  }

  @override
  void dispose() {
    _openAiApiKeyController.dispose();
    _geminiApiKeyController.dispose();
    _openRouterApiKeyController.dispose();
    _openRouterModelController.dispose();
    super.dispose();
  }

  String? _normalizeOpenRouterModel(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  String _apiKeyForProvider(AiProvider provider) {
    switch (provider) {
      case AiProvider.openAi:
        return _openAiApiKeyController.text.trim();
      case AiProvider.gemini:
        return _geminiApiKeyController.text.trim();
      case AiProvider.openRouter:
        return _openRouterApiKeyController.text.trim();
    }
  }

  Future<void> _loadStoredApiKeys() async {
    try {
      final openAiKey = await _apiKeyStorage.loadApiKey(AiProvider.openAi);
      final geminiKey = await _apiKeyStorage.loadApiKey(AiProvider.gemini);
      final openRouterKey = await _apiKeyStorage.loadApiKey(
        AiProvider.openRouter,
      );
      if (!mounted) {
        return;
      }

      _openAiApiKeyController.text = openAiKey ?? _openAiApiKeyController.text;
      _geminiApiKeyController.text = geminiKey ?? _geminiApiKeyController.text;
      _openRouterApiKeyController.text =
          openRouterKey ?? _openRouterApiKeyController.text;
    } catch (_) {
      // Ignore storage load failures here and keep the current in-memory values.
    }
  }

  Future<void> _loadHealthMonitoringSettings() async {
    final enabled = await _appPrefsStorage.isHealthMonitoringEnabled();
    final interval = await _appPrefsStorage.getHealthCheckInterval();
    if (!mounted) return;
    setState(() {
      _healthMonitoringEnabled = enabled;
      _healthCheckInterval = interval;
    });
  }

  Future<void> _save() async {
    final openAiKey = _openAiApiKeyController.text.trim();
    final geminiKey = _geminiApiKeyController.text.trim();
    final openRouterKey = _openRouterApiKeyController.text.trim();
    final selectedApiKey = _apiKeyForProvider(_selectedProvider);
    final resolvedOpenRouterModel = _normalizeOpenRouterModel(
      _openRouterModelController.text,
    );

    setState(() {
      _isSaving = true;
      _status = 'Saving settings';
      _openRouterModel = resolvedOpenRouterModel;
    });

    try {
      await _apiKeyStorage.saveApiKey(AiProvider.openAi, openAiKey);
      await _apiKeyStorage.saveApiKey(AiProvider.gemini, geminiKey);
      await _apiKeyStorage.saveApiKey(AiProvider.openRouter, openRouterKey);
      await widget.onSaveAiSettings(
        _selectedProvider,
        selectedApiKey,
        resolvedOpenRouterModel,
      );

      await _appPrefsStorage.setHealthMonitoringEnabled(
        _healthMonitoringEnabled,
      );
      await _appPrefsStorage.setHealthCheckInterval(_healthCheckInterval);

      if (_healthMonitoringEnabled) {
        await BackgroundKeepalive.enable(
          intervalMinutes: _healthCheckInterval,
        );
      } else {
        await BackgroundKeepalive.disable();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Settings saved.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to save settings: $error';
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
      queryParameters: const {'subject': 'Hamma Feedback'},
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

  Widget _buildApiKeyField({
    required TextEditingController controller,
    required String label,
    required String helperText,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_isBusy,
      obscureText: true,
      decoration: InputDecoration(labelText: label, helperText: helperText),
    );
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
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 24),
          children: [
            _SettingsSectionCard(
              title: 'AI Configuration',
              subtitle:
                  'Choose your default AI provider and manage the saved keys used by the copilot.',
              icon: Icons.smart_toy_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Theme(
                    data: theme.copyWith(canvasColor: _panelColor),
                    child: DropdownButtonFormField<AiProvider>(
                      value: _selectedProvider,
                      decoration: const InputDecoration(
                        labelText: 'Default Provider',
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
                  _buildApiKeyField(
                    controller: _openAiApiKeyController,
                    label: 'OpenAI Key',
                    helperText: 'Leave blank to clear the saved OpenAI key.',
                  ),
                  const SizedBox(height: 16),
                  _buildApiKeyField(
                    controller: _geminiApiKeyController,
                    label: 'Gemini Key',
                    helperText: 'Leave blank to clear the saved Gemini key.',
                  ),
                  const SizedBox(height: 16),
                  _buildApiKeyField(
                    controller: _openRouterApiKeyController,
                    label: 'OpenRouter Key',
                    helperText:
                        'Leave blank to clear the saved OpenRouter key.',
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
            _SettingsSectionCard(
              title: 'Health Monitoring',
              subtitle:
                  'Monitor server health in the background and receive alerts for downtime or high resource usage.',
              icon: Icons.health_and_safety_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Text('Enable Background Monitoring'),
                    subtitle: const Text(
                      'Periodically check all saved servers.',
                    ),
                    value: _healthMonitoringEnabled,
                    onChanged:
                        _isBusy
                            ? null
                            : (value) {
                              setState(() {
                                _healthMonitoringEnabled = value;
                              });
                            },
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_healthMonitoringEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Check Interval: $_healthCheckInterval minutes',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Slider(
                      value: _healthCheckInterval.toDouble(),
                      min: 15,
                      max: 120,
                      divisions: 7,
                      label: '$_healthCheckInterval min',
                      onChanged:
                          _isBusy
                              ? null
                              : (value) {
                                setState(() {
                                  _healthCheckInterval = value.toInt();
                                });
                              },
                    ),
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
              title: 'Support',
              subtitle: 'Access the help center and documentation.',
              icon: Icons.support_agent_outlined,
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
                        );
                      },
                      icon: const Icon(Icons.help_center_outlined),
                      label: const Text('Help Center'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isBusy ? null : _launchFeedbackEmail,
                      icon: const Icon(Icons.mail_outline),
                      label: const Text('Contact Support'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Hamma v1.0.0',
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

class HelpCenterScreen extends StatelessWidget {
  const HelpCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final topics = [
      {
        'title': 'Connecting via SSH',
        'markdown': '''
# Connecting via SSH
Hamma uses `dartssh2` to establish secure connections. To connect:
1. Tap **Add Server**.
2. Enter the **Host** (IP or Domain) and **Port** (default 22).
3. Provide your **Username**.
4. Use either a **Password** or a **Private Key** (Ed25519 or RSA).
5. Tap **Test Connection** to verify settings before saving.
'''
      },
      {
        'title': 'Managing Docker',
        'markdown': '''
# Managing Docker
Hamma provides a simplified Docker dashboard:
1. Open a server from the list.
2. Select **Docker Manager**.
3. View running containers, stats, and images.
4. Perform actions like **Restart**, **Stop**, or **View Logs** directly from buttons.
'''
      },
      {
        'title': 'Using AI Assistant',
        'markdown': '''
# Using AI Assistant
The AI Copilot helps you manage servers without writing complex commands:
1. Tap the **AI Assistant** icon in a server dashboard.
2. Ask questions like "How do I check Nginx logs?" or "Restart my Postgres container".
3. The AI suggests commands which you can **edit** and **run** after explicit confirmation.
4. If a command fails, use **Smart Error Analysis** to get a technical breakdown of the failure.
'''
      },
      {
        'title': 'Fleet Monitoring',
        'markdown': '''
# Fleet Monitoring
Monitor your entire infrastructure at once:
1. Open the **Fleet Command Center** from the main server list.
2. View CPU, RAM, and Disk metrics across all saved servers.
3. Enable **Background Health Monitoring** in Settings to receive alerts if a server goes offline or exceeds resource thresholds.
'''
      },
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Help Center')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: topics.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final topic = topics[index];
          return Card(
            child: ListTile(
              title: Text(topic['title']!),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(topic['title']!)),
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: MarkdownBody(
                          data: topic['markdown']!,
                          selectable: true,
                          styleSheet: MarkdownStyleSheet(
                            h1: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22),
                            p: const TextStyle(color: Color(0xFFE2E8F0), height: 1.6, fontSize: 15),
                            listBullet: const TextStyle(color: Color(0xFF3B82F6)),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
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

  static const _surfaceColor = Color(0xFF1E293B);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: _shadowColor,
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
                        color: _mutedColor,
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
