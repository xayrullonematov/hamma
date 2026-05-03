import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/ai/local_engine_detector.dart';
import '../../core/ai/ollama_client.dart';
import '../../core/background/background_keepalive.dart';
import '../../core/backup/backup_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/storage/app_lock_storage.dart';
import '../../core/storage/app_prefs_storage.dart';
import '../../core/storage/backup_storage.dart';
import '../../core/storage/log_triage_prefs.dart';
import '../security/app_lock_screen.dart';
import '../../core/theme/app_colors.dart';
import 'help_center_screen.dart';
import 'cloud_sync_screen.dart';
import 'extensions_screen.dart';
import 'vault_screen.dart';
import 'snippet_sync_screen.dart';
import 'local_ai_onboarding_screen.dart';
import 'local_models_screen.dart';
import 'widgets/settings_section_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialProvider,
    required this.initialApiKey,
    required this.initialOpenRouterModel,
    this.initialLocalEndpoint,
    this.initialLocalModel,
    required this.onSaveAiSettings,
    this.onBackupImported,
  });

  final AiProvider initialProvider;
  final String initialApiKey;
  final String? initialOpenRouterModel;
  final String? initialLocalEndpoint;
  final String? initialLocalModel;
  final Future<void> Function(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
    String? localEndpoint,
    String? localModel,
  )
  onSaveAiSettings;
  final Future<void> Function()? onBackupImported;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _panelColor = AppColors.panel;
  static const _mutedColor = AppColors.textMuted;
  static const _openRouterModelsUrl = 'https://openrouter.ai/api/v1/models';

  late final TextEditingController _openAiApiKeyController;
  late final TextEditingController _geminiApiKeyController;
  late final TextEditingController _openRouterApiKeyController;
  late final TextEditingController _openRouterModelController;
  late final TextEditingController _localEndpointController;
  late final TextEditingController _localModelController;
  bool _isTestingLocalConnection = false;
  String? _localConnectionTestResult;

  /// Validation error for the local endpoint TextFormField. Non-null
  /// while the user has typed something that is not a loopback URL;
  /// surfaced inline and used to gate Save / Test / Manage Models.
  String? get _localEndpointError {
    final raw = _localEndpointController.text.trim();
    if (raw.isEmpty) return null;
    if (OllamaClient.isLoopbackEndpoint(raw)) return null;
    return 'Endpoint must be loopback (localhost, 127.0.0.1, or ::1).';
  }

  bool get _isLocalEndpointValid {
    final raw = _localEndpointController.text.trim();
    return raw.isEmpty || OllamaClient.isLoopbackEndpoint(raw);
  }
  bool? _localConnectionTestSuccess;
  bool _isDetectingLocalEngines = false;
  List<DetectedEngine> _detectedLocalEngines = const [];
  String? _detectError;
  final AppLockStorage _appLockStorage = AppLockStorage();
  final BackupService _backupService = BackupService();
  final ApiKeyStorage _apiKeyStorage = ApiKeyStorage();
  final AppPrefsStorage _appPrefsStorage = AppPrefsStorage();
  final BackupStorage _backupStorage = BackupStorage();

  late BackupConfig _backupConfig;
  late final TextEditingController _sftpHostController;
  late final TextEditingController _sftpPortController;
  late final TextEditingController _sftpUsernameController;
  late final TextEditingController _sftpPasswordController;
  late final TextEditingController _sftpPathController;
  late final TextEditingController _webdavUrlController;
  late final TextEditingController _webdavUsernameController;
  late final TextEditingController _webdavPasswordController;
  late final TextEditingController _syncthingPathController;

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

  bool _healthMonitoringEnabled = false;
  int _healthCheckInterval = 30;

  bool _isDirty = false;
  bool _loadingFromStorage = true;

  final TextEditingController _settingsSearchController =
      TextEditingController();
  String _settingsSearchQuery = '';
  String _activeCategoryId = 'ai';
  final ScrollController _settingsScrollController = ScrollController();
  final Map<String, GlobalKey> _categoryKeys = {
    'ai': GlobalKey(),
    'triage': GlobalKey(),
    'health': GlobalKey(),
    'security': GlobalKey(),
    'backup': GlobalKey(),
    'support': GlobalKey(),
  };

  void _markDirty() {
    if (_loadingFromStorage || _isDirty || !mounted) return;
    setState(() => _isDirty = true);
  }

  /// "Watch with AI" lines-per-batch cadence. Loaded from
  /// [LogTriagePrefs] on init, persisted on slider change.
  final LogTriagePrefs _logTriagePrefs = const LogTriagePrefs();
  int _logTriageBatchSize = LogTriagePrefs.defaultBatchSize;
  bool _isLogTriageBatchSizeLoaded = false;

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
    _localEndpointController = TextEditingController(
      text: widget.initialLocalEndpoint ?? 'http://localhost:11434',
    );
    _localModelController = TextEditingController(
      text: widget.initialLocalModel ?? 'gemma3',
    );

    _backupConfig = const BackupConfig(destination: BackupDestination.local);
    _sftpHostController = TextEditingController();
    _sftpPortController = TextEditingController(text: '22');
    _sftpUsernameController = TextEditingController();
    _sftpPasswordController = TextEditingController();
    _sftpPathController = TextEditingController();
    _webdavUrlController = TextEditingController();
    _webdavUsernameController = TextEditingController();
    _webdavPasswordController = TextEditingController();
    _syncthingPathController = TextEditingController();

    final allControllers = <TextEditingController>[
      _openAiApiKeyController,
      _geminiApiKeyController,
      _openRouterApiKeyController,
      _openRouterModelController,
      _localEndpointController,
      _localModelController,
      _sftpHostController,
      _sftpPortController,
      _sftpUsernameController,
      _sftpPasswordController,
      _sftpPathController,
      _webdavUrlController,
      _webdavUsernameController,
      _webdavPasswordController,
      _syncthingPathController,
    ];
    for (final c in allControllers) {
      c.addListener(_markDirty);
    }

    _loadAppPinStatus();
    _loadLogTriageSettings();
    _loadHealthMonitoringSettings();
    Future.wait([
      _loadStoredApiKeys(),
      _loadBackupSettings(),
    ]).whenComplete(() {
      if (mounted) _loadingFromStorage = false;
    });
    if (_selectedProvider == AiProvider.openRouter) {
      _loadOpenRouterModels();
    }
  }

  Future<void> _loadLogTriageSettings() async {
    final size = await _logTriagePrefs.loadBatchSize();
    if (!mounted) return;
    setState(() {
      _logTriageBatchSize = size;
      _isLogTriageBatchSizeLoaded = true;
    });
  }

  Future<void> _saveLogTriageBatchSize(int size) async {
    final clamped = LogTriagePrefs.clampBatchSize(size);
    setState(() => _logTriageBatchSize = clamped);
    await _logTriagePrefs.saveBatchSize(clamped);
  }

  Future<void> _loadBackupSettings() async {
    final config = await _backupStorage.loadConfig();
    if (!mounted) return;
    setState(() {
      _backupConfig = config;
      _sftpHostController.text = config.sftpHost;
      _sftpPortController.text = config.sftpPort.toString();
      _sftpUsernameController.text = config.sftpUsername;
      _sftpPasswordController.text = config.sftpPassword;
      _sftpPathController.text = config.sftpPath;
      _webdavUrlController.text = config.webdavUrl;
      _webdavUsernameController.text = config.webdavUsername;
      _webdavPasswordController.text = config.webdavPassword;
      _syncthingPathController.text = config.syncthingPath;
    });
  }

  @override
  void dispose() {
    _openAiApiKeyController.dispose();
    _geminiApiKeyController.dispose();
    _openRouterApiKeyController.dispose();
    _openRouterModelController.dispose();
    _localEndpointController.dispose();
    _localModelController.dispose();
    _sftpHostController.dispose();
    _sftpPortController.dispose();
    _sftpUsernameController.dispose();
    _sftpPasswordController.dispose();
    _sftpPathController.dispose();
    _webdavUrlController.dispose();
    _webdavUsernameController.dispose();
    _webdavPasswordController.dispose();
    _syncthingPathController.dispose();
    _settingsSearchController.dispose();
    _settingsScrollController.dispose();
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
      case AiProvider.local:
        return '';
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
    if (_isBusy) return;
    if (_selectedProvider == AiProvider.local && !_isLocalEndpointValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Local AI endpoint must be loopback (localhost / 127.0.0.1 / ::1).',
          ),
        ),
      );
      return;
    }
    final openAiKey = _openAiApiKeyController.text.trim();
    final geminiKey = _geminiApiKeyController.text.trim();
    final openRouterKey = _openRouterApiKeyController.text.trim();
    final selectedApiKey = _apiKeyForProvider(_selectedProvider);
    final resolvedOpenRouterModel = _normalizeOpenRouterModel(
      _openRouterModelController.text,
    );

    setState(() {
      _isSaving = true;
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
        _localEndpointController.text.trim().isEmpty
            ? 'http://localhost:11434'
            : _localEndpointController.text.trim(),
        _localModelController.text.trim().isEmpty
            ? 'gemma3'
            : _localModelController.text.trim(),
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

      final newBackupConfig = BackupConfig(
        destination: _backupConfig.destination,
        sftpHost: _sftpHostController.text.trim(),
        sftpPort: int.tryParse(_sftpPortController.text) ?? 22,
        sftpUsername: _sftpUsernameController.text.trim(),
        sftpPassword: _sftpPasswordController.text.trim(),
        sftpPath: _sftpPathController.text.trim(),
        webdavUrl: _webdavUrlController.text.trim(),
        webdavUsername: _webdavUsernameController.text.trim(),
        webdavPassword: _webdavPasswordController.text.trim(),
        syncthingPath: _syncthingPathController.text.trim(),
        autoBackupEnabled: _backupConfig.autoBackupEnabled,
        lastBackupTime: _backupConfig.lastBackupTime,
        lastBackupStatus: _backupConfig.lastBackupStatus,
      );

      await _backupStorage.saveConfig(newBackupConfig);
      _backupConfig = newBackupConfig;

      if (_backupConfig.autoBackupEnabled) {
        await _backupService.scheduleDailyBackup();
      } else {
        await _backupService.cancelDailyBackup();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _isDirty = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save settings: $error')),
      );
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
    final hasPin = await _appLockStorage.hasPin();
    String? password;

    if (!hasPin) {
      password = await _promptForMasterPassword(
        title: 'Create Master Password',
        message:
            'Choose a master password to encrypt your backup file. You will need the same password to restore it later.',
        confirmLabel: 'Export Backup',
      );
      if (password == null) return;
    }

    setState(() {
      _isExportingBackup = true;
    });

    try {
      await _backupService.backupToDestination(manualPassword: password);
      await _loadBackupSettings();
      _showSnackBar('Backup complete.');
    } catch (error) {
      _showSnackBar('Backup failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isExportingBackup = false;
        });
      }
    }
  }

  Future<void> _importBackup() async {
    final hasPin = await _appLockStorage.hasPin();
    String? password;

    if (!hasPin) {
      password = await _promptForMasterPassword(
        title: 'Enter Master Password',
        message:
            'Enter the master password that was used when this backup file was created.',
        confirmLabel: 'Import Backup',
      );
      if (password == null) return;
    }

    setState(() {
      _isImportingBackup = true;
    });

    try {
      await _backupService.restoreFromDestination(manualPassword: password);

      // Reload app state after restore
      if (widget.onBackupImported != null) {
        await widget.onBackupImported!();
      }

      if (!mounted) return;
      _showSnackBar('Backup restored successfully.');
      Navigator.of(context).pop();
    } catch (error) {
      _showSnackBar('Restore failed: $error');
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
              .whereType<Map<dynamic, dynamic>>()
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
    final changed = provider != _selectedProvider;
    setState(() {
      _selectedProvider = provider;
      _openRouterModel = _normalizeOpenRouterModel(
        _openRouterModelController.text,
      );
      _localConnectionTestResult = null;
      _localConnectionTestSuccess = null;
      if (changed) _isDirty = true;
    });

    if (provider == AiProvider.openRouter) {
      _loadOpenRouterModels();
    } else if (provider == AiProvider.local) {
      // Best-effort: probe loopback once and, if nothing answers and the
      // user has never seen the wizard, walk them through install + pull.
      // We never block provider selection on the result.
      unawaited(_maybeAutoLaunchLocalAiOnboarding());
    }
  }

  /// Detects engines on loopback. If none are found and the user has
  /// not yet acknowledged the Local AI onboarding wizard, push the
  /// wizard automatically. Persists the "seen" flag the first time the
  /// wizard is shown so subsequent provider switches do not nag.
  Future<void> _maybeAutoLaunchLocalAiOnboarding() async {
    final alreadySeen = await _appPrefsStorage.isLocalAiOnboardingSeen();
    if (alreadySeen || !mounted) return;
    if (_selectedProvider != AiProvider.local) return;

    List<DetectedEngine> engines = const [];
    try {
      engines = await LocalEngineDetector().detect();
    } catch (_) {
      // Ignore detector failures — treat as "no engines reachable".
    }
    if (!mounted || _selectedProvider != AiProvider.local) return;
    if (engines.isNotEmpty) {
      // Engine already running; record the auto-fill and skip the wizard.
      if (_localEndpointController.text.trim() == 'http://localhost:11434') {
        setState(() {
          _localEndpointController.text = engines.first.endpoint;
        });
      }
      return;
    }

    await _appPrefsStorage.setLocalAiOnboardingSeen();
    if (!mounted || _selectedProvider != AiProvider.local) return;
    await _runLocalAiOnboarding();
  }

  Future<void> _detectLocalEngines() async {
    setState(() {
      _isDetectingLocalEngines = true;
      _detectError = null;
      _detectedLocalEngines = const [];
    });
    try {
      final engines = await LocalEngineDetector().detect();
      if (!mounted) return;
      setState(() {
        _detectedLocalEngines = engines;
        _detectError = engines.isEmpty
            ? 'No engines responded on localhost. Is Ollama / LM Studio running?'
            : null;
      });
      // Auto-fill the endpoint with the first detected engine if the
      // current value is still the default and we found something usable.
      if (engines.isNotEmpty &&
          _localEndpointController.text.trim() == 'http://localhost:11434') {
        _localEndpointController.text = engines.first.endpoint;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _detectError = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isDetectingLocalEngines = false);
      }
    }
  }

  Future<void> _openLocalModelManager() async {
    final endpoint = _localEndpointController.text.trim().isEmpty
        ? 'http://localhost:11434'
        : _localEndpointController.text.trim();
    final newDefault = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => LocalModelsScreen(
          endpoint: endpoint,
          currentDefault: _localModelController.text.trim().isEmpty
              ? null
              : _localModelController.text.trim(),
        ),
      ),
    );
    if (!mounted) return;
    if (newDefault != null && newDefault.isNotEmpty) {
      setState(() {
        _localModelController.text = newDefault;
      });
    }
  }

  Future<void> _runLocalAiOnboarding() async {
    final endpoint = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => const LocalAiOnboardingScreen(),
      ),
    );
    if (!mounted) return;
    if (endpoint != null && endpoint.isNotEmpty) {
      setState(() {
        _localEndpointController.text = endpoint;
      });
    }
  }

  Future<void> _testLocalConnection() async {
    final endpoint = _localEndpointController.text.trim().isEmpty
        ? 'http://localhost:11434'
        : _localEndpointController.text.trim();

    setState(() {
      _isTestingLocalConnection = true;
      _localConnectionTestResult = null;
      _localConnectionTestSuccess = null;
    });

    try {
      final uri = Uri.parse('$endpoint/v1/models');
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 6));

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        int modelCount = 0;
        try {
          final decoded = jsonDecode(response.body);
          final data = decoded['data'];
          if (data is List) modelCount = data.length;
        } catch (_) {}
        setState(() {
          _isTestingLocalConnection = false;
          _localConnectionTestSuccess = true;
          _localConnectionTestResult = modelCount > 0
              ? 'ENGINE ONLINE — $modelCount model${modelCount == 1 ? "" : "s"} available'
              : 'ENGINE ONLINE — connected (no models loaded yet)';
        });
      } else {
        setState(() {
          _isTestingLocalConnection = false;
          _localConnectionTestSuccess = false;
          _localConnectionTestResult = 'ENGINE UNREACHABLE — HTTP ${response.statusCode}';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isTestingLocalConnection = false;
        _localConnectionTestSuccess = false;
        _localConnectionTestResult = 'CONNECTION TIMED OUT — is Ollama running?';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTestingLocalConnection = false;
        _localConnectionTestSuccess = false;
        _localConnectionTestResult = 'CONNECTION FAILED — is Ollama running?';
      });
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
          borderRadius: BorderRadius.zero,
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
          borderRadius: BorderRadius.zero,
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

  Widget _buildLocalAiSection(ThemeData theme) {
    final testSuccess = _localConnectionTestSuccess;
    final testResult = _localConnectionTestResult;
    final testColor = testSuccess == null
        ? _mutedColor
        : testSuccess
            ? const Color(0xFF00FF88)
            : AppColors.danger;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(
            color: Color(0xFF0D1117),
            border: Border(
              left: BorderSide(color: Color(0xFF00FF88), width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF00FF88), width: 1),
                    ),
                    child: Text(
                      'ZERO TRUST',
                      style: TextStyle(
                        fontFamily: AppColors.monoFamily,
                        fontSize: 10,
                        color: const Color(0xFF00FF88),
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF00FF88), width: 1),
                    ),
                    child: Text(
                      'OFFLINE CAPABLE',
                      style: TextStyle(
                        fontFamily: AppColors.monoFamily,
                        fontSize: 10,
                        color: const Color(0xFF00FF88),
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'No API key required. No data leaves your machine. '
                'Runs on any OpenAI-compatible local engine: Ollama, LM Studio, llama.cpp.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _mutedColor,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _localEndpointController,
          enabled: !_isBusy,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Engine Endpoint',
            helperText:
                'Base URL of your local AI server (loopback only — no LAN/internet).',
            hintText: 'http://localhost:11434',
            errorText: _localEndpointError,
          ),
          style: const TextStyle(
            fontFamily: AppColors.monoFamily,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _localModelController,
          enabled: !_isBusy,
          decoration: const InputDecoration(
            labelText: 'Model Name',
            helperText: 'Exact model tag as shown by "ollama list".',
            hintText: 'gemma3',
          ),
          style: TextStyle(fontFamily: AppColors.monoFamily, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    (_isBusy || _isTestingLocalConnection || !_isLocalEndpointValid)
                        ? null
                        : _testLocalConnection,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                  side: const BorderSide(color: Color(0xFF00FF88)),
                  foregroundColor: const Color(0xFF00FF88),
                ),
                icon: _isTestingLocalConnection
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00FF88),
                        ),
                      )
                    : const Icon(Icons.electrical_services_rounded, size: 16),
                label: Text(
                  _isTestingLocalConnection ? 'TESTING...' : 'TEST CONNECTION',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 12,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (testResult != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _panelColor,
              border: Border(
                left: BorderSide(color: testColor, width: 3),
              ),
            ),
            child: Text(
              testResult,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 12,
                color: testColor,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_isBusy || _isDetectingLocalEngines)
                    ? null
                    : _detectLocalEngines,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                  side: const BorderSide(color: Color(0xFF00FF88)),
                  foregroundColor: const Color(0xFF00FF88),
                ),
                icon: _isDetectingLocalEngines
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00FF88),
                        ),
                      )
                    : const Icon(Icons.radar_rounded, size: 16),
                label: Text(
                  _isDetectingLocalEngines ? 'SCANNING...' : 'DETECT ENGINES',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 12,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_isBusy || !_isLocalEndpointValid)
                    ? null
                    : _openLocalModelManager,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                  side: const BorderSide(color: Color(0xFF00FF88)),
                  foregroundColor: const Color(0xFF00FF88),
                ),
                icon: const Icon(Icons.dns_rounded, size: 16),
                label: Text(
                  'MANAGE MODELS',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 12,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _isBusy ? null : _runLocalAiOnboarding,
          icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF00FF88),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          label: Text(
            'FIRST-RUN SETUP',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (_detectedLocalEngines.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._detectedLocalEngines.map((e) {
            final selected = _localEndpointController.text.trim() == e.endpoint;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _localEndpointController.text = e.endpoint;
                    _isDirty = true;
                  });
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _panelColor,
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF00FF88)
                          : AppColors.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 16,
                        color: selected
                            ? const Color(0xFF00FF88)
                            : AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.displayLabel,
                              style: TextStyle(
                                fontFamily: AppColors.monoFamily,
                                fontSize: 12,
                                color: const Color(0xFF00FF88),
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1,
                              ),
                            ),
                            Text(
                              e.endpoint,
                              style: TextStyle(
                                fontFamily: AppColors.monoFamily,
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
        if (_detectError != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _panelColor,
              border: Border(
                left: BorderSide(color: AppColors.danger, width: 3),
              ),
            ),
            child: Text(
              _detectError!,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 12,
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Back to servers',
        ),
      ),
      bottomNavigationBar: (!_isDirty && !_isSaving) ? null : SafeArea(
        top: false,
        child: Container(
          key: const ValueKey('settings_sticky_save_bar'),
          decoration: const BoxDecoration(
            color: AppColors.panel,
            border: Border(
              top: BorderSide(color: AppColors.border, width: 1),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _isSaving ? 'Saving…' : 'Unsaved changes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _mutedColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _isBusy ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                ),
                icon: _isSaving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded, size: 16),
                label: const Text('SAVE'),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showRail = constraints.maxWidth >= 1100;
            final hasSearch = _settingsSearchQuery.trim().isNotEmpty;
            final listPadding =
                EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 24);

            // Desktop: rail + selected-category detail pane.
            // Active search overrides master-detail so users see all matches.
            if (showRail) {
              final restrict =
                  hasSearch ? null : <String>{_activeCategoryId};
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCategoriesRail(theme),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 800),
                        child: _buildSectionList(
                          context,
                          theme,
                          controller: _settingsScrollController,
                          padding: listPadding,
                          restrictToIds: restrict,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }

            // Mobile/tablet with active search: show all matching cards inline.
            if (hasSearch) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: _buildSectionList(
                    context,
                    theme,
                    controller: _settingsScrollController,
                    padding: listPadding,
                  ),
                ),
              );
            }

            // Mobile/tablet without search: tappable category list that
            // pushes a detail route per category.
            return _buildMobileCategoryList(theme, listPadding);
          },
        ),
      ),
    );
  }

  Widget _buildSectionList(
    BuildContext context,
    ThemeData theme, {
    required ScrollController controller,
    required EdgeInsets padding,
    Set<String>? restrictToIds,
    bool showSearchField = true,
  }) {
    return ListView(
      key: const ValueKey('settings_sections_list'),
      controller: controller,
      padding: padding,
      children: [
        if (showSearchField) ...[
          _buildSettingsSearchField(theme),
          const SizedBox(height: 16),
        ],
                _wrapCategorySection(
                  'ai',
                  SettingsSectionCard(
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
                          borderRadius: BorderRadius.zero,
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
                            borderRadius: BorderRadius.zero,
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
                      if (_selectedProvider == AiProvider.local) ...[
                        const SizedBox(height: 20),
                        _buildLocalAiSection(theme),
                      ],
                    ],
                  ),
                  ),
                  restrictToIds: restrictToIds,
                ),
                _wrapCategorySection(
                  'triage',
                  SettingsSectionCard(
                  title: 'AI Log Triage Cadence',
                  subtitle:
                      'How many log lines accumulate before "Watch with AI" sends a batch to the local model. Smaller = more frequent insights and more model calls. Local AI only.',
                  icon: Icons.tune,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isLogTriageBatchSizeLoaded
                            ? 'Analyse every $_logTriageBatchSize lines'
                            : 'Loading…',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.textPrimary,
                          fontFamily: AppColors.monoFamily,
                        ),
                      ),
                      Slider(
                        min: LogTriagePrefs.minBatchSize.toDouble(),
                        max: LogTriagePrefs.maxBatchSize.toDouble(),
                        divisions:
                            (LogTriagePrefs.maxBatchSize -
                                    LogTriagePrefs.minBatchSize) ~/
                                10,
                        value: _logTriageBatchSize.toDouble().clamp(
                              LogTriagePrefs.minBatchSize.toDouble(),
                              LogTriagePrefs.maxBatchSize.toDouble(),
                            ),
                        label: '$_logTriageBatchSize lines',
                        onChanged: !_isLogTriageBatchSizeLoaded || _isBusy
                            ? null
                            : (v) => setState(() {
                                  _logTriageBatchSize =
                                      LogTriagePrefs.clampBatchSize(v.round());
                                  _isDirty = true;
                                }),
                        onChangeEnd: !_isLogTriageBatchSizeLoaded || _isBusy
                            ? null
                            : (v) => _saveLogTriageBatchSize(v.round()),
                      ),
                      Text(
                        'Range: ${LogTriagePrefs.minBatchSize}–${LogTriagePrefs.maxBatchSize} '
                        '(default ${LogTriagePrefs.defaultBatchSize}). '
                        'Open log views can override this per-session.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _mutedColor,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                  ),
                  restrictToIds: restrictToIds,
                ),
                _wrapCategorySection(
                  'health',
                  SettingsSectionCard(
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
                                    _isDirty = true;
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
                                      _isDirty = true;
                                    });
                                  },
                        ),
                      ],
                    ],
                  ),
                  ),
                  restrictToIds: restrictToIds,
                ),
                _wrapCategorySection(
                  'security',
                  SettingsSectionCard(
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
                          borderRadius: BorderRadius.zero,
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
                  restrictToIds: restrictToIds,
                ),
                _wrapCategorySection(
                  'backup',
                  SettingsSectionCard(
                  title: 'Backup & Restore',
                  subtitle:
                      'Securely backup your servers, AI keys, and chat history to your own server or local storage.',
                  icon: Icons.cloud_sync_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<BackupDestination>(
                        value: _backupConfig.destination,
                        decoration: const InputDecoration(
                          labelText: 'Backup Destination',
                        ),
                        items:
                            BackupDestination.values
                                .where((d) =>
                                    d != BackupDestination.s3Compat &&
                                    d != BackupDestination.iCloud &&
                                    d != BackupDestination.dropbox)
                                .map((dest) {
                              return DropdownMenuItem(
                                value: dest,
                                child: Text(dest.name.toUpperCase()),
                              );
                            }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _isDirty = true;
                              _backupConfig = BackupConfig(
                                destination: value,
                                sftpHost: _backupConfig.sftpHost,
                                sftpPort: _backupConfig.sftpPort,
                                sftpUsername: _backupConfig.sftpUsername,
                                sftpPassword: _backupConfig.sftpPassword,
                                sftpPath: _backupConfig.sftpPath,
                                webdavUrl: _backupConfig.webdavUrl,
                                webdavUsername: _backupConfig.webdavUsername,
                                webdavPassword: _backupConfig.webdavPassword,
                                syncthingPath: _backupConfig.syncthingPath,
                                autoBackupEnabled:
                                    _backupConfig.autoBackupEnabled,
                                lastBackupTime: _backupConfig.lastBackupTime,
                                lastBackupStatus: _backupConfig.lastBackupStatus,
                              );
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      if (_backupConfig.destination == BackupDestination.sftp) ...[
                        _buildApiKeyField(
                          controller: _sftpHostController,
                          label: 'SFTP Host',
                          helperText: 'Hostname or IP of your server',
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _buildApiKeyField(
                                controller: _sftpUsernameController,
                                label: 'Username',
                                helperText: '',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildApiKeyField(
                                controller: _sftpPortController,
                                label: 'Port',
                                helperText: '',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildApiKeyField(
                          controller: _sftpPasswordController,
                          label: 'Password',
                          helperText: 'SSH Password',
                        ),
                        const SizedBox(height: 12),
                        _buildApiKeyField(
                          controller: _sftpPathController,
                          label: 'Backup Directory',
                          helperText: 'Absolute path on server',
                        ),
                      ],
                      if (_backupConfig.destination == BackupDestination.webdav) ...[
                        _buildApiKeyField(
                          controller: _webdavUrlController,
                          label: 'WebDAV URL',
                          helperText: 'e.g. https://nextcloud.com/remote.php/dav/files/user/',
                        ),
                        const SizedBox(height: 12),
                        _buildApiKeyField(
                          controller: _webdavUsernameController,
                          label: 'Username',
                          helperText: '',
                        ),
                        const SizedBox(height: 12),
                        _buildApiKeyField(
                          controller: _webdavPasswordController,
                          label: 'Password / App Token',
                          helperText: '',
                        ),
                      ],
                      if (_backupConfig.destination == BackupDestination.syncthing) ...[
                        _buildApiKeyField(
                          controller: _syncthingPathController,
                          label: 'Syncthing Local Path',
                          helperText: 'The folder Syncthing monitors on this device',
                        ),
                      ],
                      const SizedBox(height: 16),
                      SwitchListTile(
                        title: const Text('Daily Automatic Backup'),
                        subtitle: const Text(
                          'Background backup when connected to Wi-Fi.',
                        ),
                        value: _backupConfig.autoBackupEnabled,
                        onChanged: (value) {
                          setState(() {
                            _isDirty = true;
                            _backupConfig = BackupConfig(
                              destination: _backupConfig.destination,
                              sftpHost: _backupConfig.sftpHost,
                              sftpPort: _backupConfig.sftpPort,
                              sftpUsername: _backupConfig.sftpUsername,
                              sftpPassword: _backupConfig.sftpPassword,
                              sftpPath: _backupConfig.sftpPath,
                              webdavUrl: _backupConfig.webdavUrl,
                              webdavUsername: _backupConfig.webdavUsername,
                              webdavPassword: _backupConfig.webdavPassword,
                              syncthingPath: _backupConfig.syncthingPath,
                              autoBackupEnabled: value,
                              lastBackupTime: _backupConfig.lastBackupTime,
                              lastBackupStatus: _backupConfig.lastBackupStatus,
                            );
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                      const Divider(height: 32, color: AppColors.border),
                      if (_backupConfig.lastBackupTime != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            'Last Backup: ${_backupConfig.lastBackupTime!.toLocal().toString().split('.')[0]} (${_backupConfig.lastBackupStatus ?? 'Unknown'})',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
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
                                      : const Icon(Icons.backup_outlined),
                              label: const Text('Backup Now'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
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
                                      : const Icon(Icons.restore_outlined),
                              label: const Text('Restore'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _isBusy
                              ? null
                              : () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const CloudSyncScreen(),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.cloud_outlined),
                          label: const Text('Cloud Sync (Encrypted)'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _isBusy
                              ? null
                              : () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const SnippetSyncScreen(),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.sync_alt_outlined),
                          label: const Text('Snippet Sync (Cross-Device)'),
                        ),
                      ),
                    ],
                  ),
                  ),
                  restrictToIds: restrictToIds,
                ),
                _wrapCategorySection(
                  'support',
                  SettingsSectionCard(
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
                              MaterialPageRoute<void>(builder: (_) => const HelpCenterScreen()),
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
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ExtensionsScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.extension_outlined),
                          label: const Text('Extensions'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const VaultScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.lock_outline),
                          label: const Text('Vault'),
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
                  restrictToIds: restrictToIds,
                ),
        Text(
          'Hamma v1.0.0',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: _mutedColor,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildMobileCategoryList(ThemeData theme, EdgeInsets padding) {
    return ListView(
      key: const ValueKey('settings_mobile_category_list'),
      controller: _settingsScrollController,
      padding: padding,
      children: [
        _buildSettingsSearchField(theme),
        const SizedBox(height: 16),
        ..._categoryMeta.entries.map((entry) {
          final id = entry.key;
          final meta = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: AppColors.panel,
              child: InkWell(
                key: ValueKey('settings_mobile_category_$id'),
                onTap: () => _openCategoryDetail(id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
                  child: Row(
                    children: [
                      Icon(meta.icon, size: 20),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          meta.title.toUpperCase(),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  void _openCategoryDetail(String id) {
    final meta = _categoryMeta[id];
    if (meta == null) return;
    final ctrl = ScrollController();
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: 'settings_category_detail/$id'),
            builder: (routeContext) {
              final routeTheme = Theme.of(routeContext);
              final inset =
                  MediaQuery.of(routeContext).viewInsets.bottom;
              return Scaffold(
                key: ValueKey('settings_category_detail_$id'),
                appBar: AppBar(
                  title: Text(meta.title.toUpperCase()),
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(routeContext).pop(),
                  ),
                ),
                body: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 800),
                      child: _buildSectionList(
                        routeContext,
                        routeTheme,
                        controller: ctrl,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          12,
                          16,
                          inset + 24,
                        ),
                        restrictToIds: <String>{id},
                        showSearchField: false,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        )
        .whenComplete(() => ctrl.dispose());
  }

  static const Map<String, ({String title, IconData icon, String search})>
      _categoryMeta = {
    'ai': (
      title: 'AI Configuration',
      icon: Icons.smart_toy_outlined,
      // Search keywords cover both the category and every field label
      // inside it, so search hits surface the matching category card.
      search:
          'ai configuration provider openai gemini openrouter local model '
          'copilot key default provider openai key gemini key openrouter key '
          'local endpoint local model',
    ),
    'triage': (
      title: 'AI Log Triage',
      icon: Icons.tune,
      search:
          'ai log triage cadence batch lines watch local analyse every',
    ),
    'health': (
      title: 'Health Monitoring',
      icon: Icons.health_and_safety_outlined,
      search:
          'health monitoring background check interval uptime servers '
          'enable background monitoring check interval minutes',
    ),
    'security': (
      title: 'Security',
      icon: Icons.lock_outline,
      search:
          'security app pin biometric lock vault master password '
          'set app pin remove app pin',
    ),
    'backup': (
      title: 'Backup & Restore',
      icon: Icons.cloud_sync_outlined,
      search:
          'backup restore sftp webdav syncthing snippet cloud sync export '
          'import daily backup destination sftp host username port password '
          'backup directory webdav url syncthing local path daily automatic '
          'backup backup now restore cloud sync',
    ),
    'support': (
      title: 'Support',
      icon: Icons.support_agent_outlined,
      search:
          'support help center extensions vault contact feedback',
    ),
  };

  bool _categoryMatchesQuery(String id) {
    final q = _settingsSearchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    final meta = _categoryMeta[id];
    if (meta == null) return true;
    return meta.title.toLowerCase().contains(q) ||
        meta.search.contains(q);
  }

  Widget _wrapCategorySection(
    String id,
    Widget card, {
    Set<String>? restrictToIds,
  }) {
    final visible = restrictToIds != null
        ? restrictToIds.contains(id)
        : _categoryMatchesQuery(id);
    return KeyedSubtree(
      key: _categoryKeys[id],
      child: Visibility(
        visible: visible,
        maintainState: true,
        maintainAnimation: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: card,
        ),
      ),
    );
  }

  Widget _buildSettingsSearchField(ThemeData theme) {
    return TextField(
      key: const ValueKey('settings_search_field'),
      controller: _settingsSearchController,
      onChanged: (value) {
        setState(() => _settingsSearchQuery = value);
      },
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 18),
        hintText: 'Search settings…',
        isDense: true,
        suffixIcon: _settingsSearchQuery.isEmpty
            ? null
            : IconButton(
                key: const ValueKey('settings_search_clear'),
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _settingsSearchController.clear();
                  setState(() => _settingsSearchQuery = '');
                },
              ),
      ),
    );
  }

  Widget _buildCategoriesRail(ThemeData theme) {
    return Container(
      key: const ValueKey('settings_categories_rail'),
      width: 220,
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: ListView(
        children: _categoryMeta.entries.map((entry) {
          final id = entry.key;
          final meta = entry.value;
          final selected = _activeCategoryId == id;
          final dim = !_categoryMatchesQuery(id);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Material(
              color: selected ? AppColors.overlayHover : Colors.transparent,
              child: InkWell(
                key: ValueKey('settings_category_$id'),
                onTap: dim ? null : () => _scrollToCategory(id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        meta.icon,
                        size: 16,
                        color: dim ? AppColors.textMuted : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          meta.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: dim ? AppColors.textMuted : null,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _scrollToCategory(String id) async {
    final key = _categoryKeys[id];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    setState(() => _activeCategoryId = id);
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      alignment: 0,
    );
  }
}
