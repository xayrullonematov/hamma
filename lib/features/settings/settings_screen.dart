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
import 'widgets/settings_edit_pages.dart';
import 'widgets/settings_row.dart';
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

  bool get _isLocalEndpointValid {
    final raw = _localEndpointController.text.trim();
    return raw.isEmpty || OllamaClient.isLoopbackEndpoint(raw);
  }
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
  List<String> _openRouterModels = const [];

  bool _healthMonitoringEnabled = false;
  int _healthCheckInterval = 30;

  bool _isDirty = false;
  bool _loadingFromStorage = true;

  // Notifies the mobile per-category detail route (pushed onto a separate
  // Element subtree from this State) so its sticky save bar appears the
  // moment the user dirties a field inside the pushed page.
  final ValueNotifier<int> _saveBarTrigger = ValueNotifier<int>(0);
  void _bumpSaveBar() => _saveBarTrigger.value++;

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
    _bumpSaveBar();
  }

  /// Single source of truth for row search metadata. Both
  /// [_rowMatches] (which gates row visibility) and
  /// [_categoryMatchesQuery] (which gates category visibility) read
  /// from this map, so a search query for any registered row keyword
  /// is guaranteed to keep the parent category on screen. Adding a
  /// row in the UI without registering it here will assert in debug
  /// mode via [_rowMatches].
  ///
  /// Inner key is a row identifier (usually equal to the row label,
  /// disambiguated with a `(group)` suffix when the same label is
  /// reused inside a category — e.g. SFTP / WebDAV "Username").
  static const Map<String, Map<String, String>> _categoryRowKeywords = {
    'ai': {
      'Default Provider':
          'ai provider openai gemini openrouter local default',
      'OpenAI Key': 'openai key api',
      'Gemini Key': 'gemini key api',
      'OpenRouter Key': 'openrouter key api',
      'OpenRouter Model': 'openrouter model gpt claude llama',
      'Engine Endpoint':
          'local endpoint loopback ollama llamacpp lmstudio url',
      'Local Model': 'local model ollama tag pull',
      'Test Connection': 'test ping connection probe',
      'Detect Engines': 'detect scan engines local',
      'Manage Models': 'manage pull models tags',
      'First-Run Setup':
          'first run setup wizard onboarding install local engine',
    },
    'triage': {
      'Batch Size':
          'log triage cadence batch lines analyse every watch',
    },
    'health': {
      'Enable Background Monitoring':
          'health monitor background uptime servers enable',
      'Check Interval': 'check interval minutes frequency every',
    },
    'security': {
      'App PIN':
          'security app pin biometric lock unlock vault master password',
    },
    'backup': {
      'Backup Destination':
          'destination sftp webdav webdav url syncthing local host '
              'port username password url path token nextcloud',
      'SFTP Host': 'sftp host server hostname',
      'SFTP Username': 'sftp username user',
      'SFTP Port': 'sftp port',
      'SFTP Password': 'sftp password ssh',
      'SFTP Backup Directory': 'sftp path directory backup folder',
      'WebDAV URL': 'webdav url nextcloud server',
      'WebDAV Username': 'webdav username user',
      'WebDAV Password': 'webdav password app token',
      'Syncthing Local Path': 'syncthing path folder local',
      'Daily Automatic Backup':
          'daily automatic auto backup schedule wifi background',
      'Backup Now': 'backup now export run',
      'Restore': 'restore import backup',
      'Cloud Sync (Encrypted)':
          'cloud sync encrypted end to end device e2e',
      'Snippet Sync (Cross-Device)':
          'snippet sync cross device share command',
    },
    'support': {
      'Help Center':
          'help center guides faqs troubleshooting documentation',
      'Extensions': 'extensions plugins manage installed',
      'Vault': 'vault secrets encrypted credentials',
      'Contact Support':
          'contact support feedback email hamma team',
    },
  };

  /// Returns true if the registered row in [categoryId] keyed by
  /// [rowKey] matches the active search query. Empty query matches
  /// all. Asserts in debug if a callsite passes an unregistered
  /// (categoryId, rowKey) — preventing silent search drift.
  bool _rowMatches(String categoryId, String rowKey) {
    final keywords = _categoryRowKeywords[categoryId]?[rowKey];
    assert(
      keywords != null,
      'Settings row "$rowKey" in category "$categoryId" is missing '
      'from _categoryRowKeywords. Register it so search keeps the '
      'category visible when the row matches.',
    );
    final q = _settingsSearchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    return rowKey.toLowerCase().contains(q) ||
        (keywords ?? '').toLowerCase().contains(q);
  }

  /// Renders the "current value" for any secret chevron row. We never
  /// echo any portion of the underlying secret regardless of length —
  /// the row only conveys whether a secret is saved.
  String _secretValueLabel(String key) =>
      key.isEmpty ? 'Not set' : 'Set';

  Future<void> _editApiKey({
    required TextEditingController controller,
    required String title,
    required String helperText,
  }) async {
    final result = await pushSettingsTextEdit(
      context: context,
      title: title,
      currentValue: controller.text,
      helperText: helperText,
      obscure: true,
    );
    if (result == null || !mounted) return;
    if (result == controller.text) return;
    setState(() {
      controller.text = result;
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  Future<void> _pickAiProvider() async {
    final picked = await pushSettingsChoiceEdit<AiProvider>(
      context: context,
      title: 'Default Provider',
      currentValue: _selectedProvider,
      choices: AiProvider.values
          .map((p) => SettingsChoice<AiProvider>(
                value: p,
                label: p.label,
                subtitle: p.helperText,
              ))
          .toList(),
    );
    if (picked == null || !mounted) return;
    _handleProviderChanged(picked);
  }

  Future<void> _editLocalEndpointRow() async {
    final result = await pushSettingsTextEdit(
      context: context,
      title: 'Engine Endpoint',
      currentValue: _localEndpointController.text,
      helperText:
          'Base URL of your local AI server (loopback only — no LAN/internet).',
      hintText: 'http://localhost:11434',
      monospace: true,
      validator: (v) {
        if (v.isEmpty) return null;
        if (OllamaClient.isLoopbackEndpoint(v)) return null;
        return 'Endpoint must be loopback (localhost, 127.0.0.1, or ::1).';
      },
    );
    if (result == null || !mounted) return;
    if (result == _localEndpointController.text) return;
    setState(() {
      _localEndpointController.text = result;
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  Future<void> _editLocalModelRow() async {
    final result = await pushSettingsTextEdit(
      context: context,
      title: 'Model Name',
      currentValue: _localModelController.text,
      helperText: 'Exact model tag as shown by "ollama list".',
      hintText: 'gemma3',
      monospace: true,
    );
    if (result == null || !mounted) return;
    if (result == _localModelController.text) return;
    setState(() {
      _localModelController.text = result;
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  Future<void> _editOpenRouterModelRow() async {
    if (!_hasLoadedOpenRouterModels) {
      await _loadOpenRouterModels();
    }
    if (!mounted) return;
    final choices = _openRouterModels
        .map((id) => SettingsChoice<String>(value: id, label: id))
        .toList();
    if (choices.isEmpty) {
      // Fall back to free-text edit so the user can paste a model id.
      final result = await pushSettingsTextEdit(
        context: context,
        title: 'OpenRouter Model',
        currentValue: _openRouterModel ?? '',
        helperText: 'Model id, e.g. openai/gpt-4o-mini',
        monospace: true,
      );
      if (result == null || !mounted) return;
      setState(() {
        _openRouterModel = _normalizeOpenRouterModel(result);
        _openRouterModelController.text = _openRouterModel ?? '';
        _isDirty = true;
        _bumpSaveBar();
      });
      return;
    }
    final picked = await pushSettingsChoiceEdit<String>(
      context: context,
      title: 'OpenRouter Model',
      currentValue: _openRouterModel ?? choices.first.value,
      choices: choices,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _openRouterModel = _normalizeOpenRouterModel(picked);
      _openRouterModelController.text = _openRouterModel ?? '';
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  Future<void> _editLogTriageBatchSizeRow() async {
    if (!_isLogTriageBatchSizeLoaded) return;
    final picked = await pushSettingsSliderEdit(
      context: context,
      title: 'Batch Size',
      currentValue: _logTriageBatchSize,
      min: LogTriagePrefs.minBatchSize,
      max: LogTriagePrefs.maxBatchSize,
      divisions: (LogTriagePrefs.maxBatchSize - LogTriagePrefs.minBatchSize) ~/
          10,
      labelBuilder: (v) => 'Analyse every $v lines',
      helperText:
          'Range: ${LogTriagePrefs.minBatchSize}–${LogTriagePrefs.maxBatchSize} '
          '(default ${LogTriagePrefs.defaultBatchSize}). Open log views can '
          'override this per-session.',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _logTriageBatchSize = LogTriagePrefs.clampBatchSize(picked);
      _isDirty = true;
      _bumpSaveBar();
    });
    await _saveLogTriageBatchSize(picked);
  }

  Future<void> _editHealthIntervalRow() async {
    final picked = await pushSettingsSliderEdit(
      context: context,
      title: 'Check Interval',
      currentValue: _healthCheckInterval,
      min: 15,
      max: 120,
      divisions: 7,
      labelBuilder: (v) => '$v minutes',
      helperText:
          'How often saved servers are probed in the background.',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _healthCheckInterval = picked;
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  void _setHealthMonitoringEnabled(bool value) {
    setState(() {
      _healthMonitoringEnabled = value;
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  Future<void> _pickBackupDestination() async {
    final allowed = BackupDestination.values
        .where((d) =>
            d != BackupDestination.s3Compat &&
            d != BackupDestination.iCloud &&
            d != BackupDestination.dropbox)
        .toList();
    final picked = await pushSettingsChoiceEdit<BackupDestination>(
      context: context,
      title: 'Backup Destination',
      currentValue: _backupConfig.destination,
      choices: allowed
          .map((d) => SettingsChoice<BackupDestination>(
                value: d,
                label: d.name.toUpperCase(),
              ))
          .toList(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _isDirty = true;
      _bumpSaveBar();
      _backupConfig = BackupConfig(
        destination: picked,
        sftpHost: _backupConfig.sftpHost,
        sftpPort: _backupConfig.sftpPort,
        sftpUsername: _backupConfig.sftpUsername,
        sftpPassword: _backupConfig.sftpPassword,
        sftpPath: _backupConfig.sftpPath,
        webdavUrl: _backupConfig.webdavUrl,
        webdavUsername: _backupConfig.webdavUsername,
        webdavPassword: _backupConfig.webdavPassword,
        syncthingPath: _backupConfig.syncthingPath,
        autoBackupEnabled: _backupConfig.autoBackupEnabled,
        lastBackupTime: _backupConfig.lastBackupTime,
        lastBackupStatus: _backupConfig.lastBackupStatus,
      );
    });
  }

  Future<void> _editBackupTextField({
    required TextEditingController controller,
    required String title,
    String? helperText,
    String? hintText,
    bool obscure = false,
    bool monospace = false,
    TextInputType keyboardType = TextInputType.text,
  }) async {
    final result = await pushSettingsTextEdit(
      context: context,
      title: title,
      currentValue: controller.text,
      helperText: helperText,
      hintText: hintText,
      obscure: obscure,
      monospace: monospace,
      keyboardType: keyboardType,
    );
    if (result == null || !mounted) return;
    if (result == controller.text) return;
    setState(() {
      controller.text = result;
      _isDirty = true;
      _bumpSaveBar();
    });
  }

  void _setAutoBackupEnabled(bool value) {
    setState(() {
      _isDirty = true;
      _bumpSaveBar();
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
      _bumpSaveBar();
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
        _bumpSaveBar();
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
          _bumpSaveBar();
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
        _hasLoadedOpenRouterModels = true;
      });
      _openRouterModelController.text = _openRouterModel ?? '';
    } on TimeoutException {
      // Silently fall through: the OpenRouter model row remains
      // editable as a free-text chevron, which is the documented
      // fallback when the model index is unreachable.
    } catch (_) {
      // Same fallback as the timeout path above.
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
      if (changed) {
        _isDirty = true;
        _bumpSaveBar();
      }
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
          _localConnectionTestResult = modelCount > 0
              ? 'ENGINE ONLINE — $modelCount model${modelCount == 1 ? "" : "s"} available'
              : 'ENGINE ONLINE — connected (no models loaded yet)';
        });
      } else {
        setState(() {
          _isTestingLocalConnection = false;
          _localConnectionTestResult = 'ENGINE UNREACHABLE — HTTP ${response.statusCode}';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isTestingLocalConnection = false;
        _localConnectionTestResult = 'CONNECTION TIMED OUT — is Ollama running?';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTestingLocalConnection = false;
        _localConnectionTestResult = 'CONNECTION FAILED — is Ollama running?';
      });
    }
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
      bottomNavigationBar: _buildStickySaveBar(theme),
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
                      SettingsRowGroup(
                        header: 'PROVIDER',
                        children: [
                          if (_rowMatches('ai', 'Default Provider'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_ai_provider'),
                              iconColor: AppColors.accentAi,
                              icon: Icons.bolt_rounded,
                              label: 'Default Provider',
                              value: _selectedProvider.label,
                              enabled: !_isBusy,
                              onTap: _isBusy ? null : _pickAiProvider,
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SettingsRowGroup(
                        header: 'API KEYS',
                        children: [
                          if (_rowMatches('ai', 'OpenAI Key'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_openai_key'),
                              iconColor: AppColors.accentAi,
                              icon: Icons.vpn_key_rounded,
                              label: 'OpenAI Key',
                              value: _secretValueLabel(
                                  _openAiApiKeyController.text),
                              enabled: !_isBusy,
                              onTap: _isBusy
                                  ? null
                                  : () => _editApiKey(
                                        controller: _openAiApiKeyController,
                                        title: 'OpenAI Key',
                                        helperText:
                                            'Leave blank to clear the saved OpenAI key.',
                                      ),
                            ),
                          if (_rowMatches('ai', 'Gemini Key'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_gemini_key'),
                              iconColor: AppColors.accentAi,
                              icon: Icons.vpn_key_rounded,
                              label: 'Gemini Key',
                              value: _secretValueLabel(
                                  _geminiApiKeyController.text),
                              enabled: !_isBusy,
                              onTap: _isBusy
                                  ? null
                                  : () => _editApiKey(
                                        controller: _geminiApiKeyController,
                                        title: 'Gemini Key',
                                        helperText:
                                            'Leave blank to clear the saved Gemini key.',
                                      ),
                            ),
                          if (_rowMatches('ai', 'OpenRouter Key'))
                            SettingsRow.chevron(
                              key: const ValueKey(
                                  'settings_row_openrouter_key'),
                              iconColor: AppColors.accentAi,
                              icon: Icons.vpn_key_rounded,
                              label: 'OpenRouter Key',
                              value: _secretValueLabel(
                                  _openRouterApiKeyController.text),
                              enabled: !_isBusy,
                              onTap: _isBusy
                                  ? null
                                  : () => _editApiKey(
                                        controller:
                                            _openRouterApiKeyController,
                                        title: 'OpenRouter Key',
                                        helperText:
                                            'Leave blank to clear the saved OpenRouter key.',
                                      ),
                            ),
                        ],
                      ),
                      if (_selectedProvider == AiProvider.openRouter) ...[
                        const SizedBox(height: 16),
                        SettingsRowGroup(
                          header: 'OPENROUTER',
                          children: [
                            if (_rowMatches('ai', 'OpenRouter Model'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_openrouter_model'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.memory_rounded,
                                label: 'OpenRouter Model',
                                value: _openRouterModel ?? 'Default',
                                enabled: !_isBusy,
                                onTap:
                                    _isBusy ? null : _editOpenRouterModelRow,
                              ),
                          ],
                        ),
                      ],
                      if (_selectedProvider == AiProvider.local) ...[
                        const SizedBox(height: 16),
                        SettingsRowGroup(
                          header: 'LOCAL ENGINE',
                          children: [
                            if (_rowMatches('ai', 'Engine Endpoint'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_local_endpoint'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.dns_rounded,
                                label: 'Engine Endpoint',
                                value: _localEndpointController.text.isEmpty
                                    ? 'http://localhost:11434'
                                    : _localEndpointController.text,
                                enabled: !_isBusy,
                                onTap: _isBusy ? null : _editLocalEndpointRow,
                              ),
                            if (_rowMatches('ai', 'Local Model'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_local_model'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.memory_rounded,
                                label: 'Local Model',
                                value: _localModelController.text.isEmpty
                                    ? 'gemma3'
                                    : _localModelController.text,
                                enabled: !_isBusy,
                                onTap: _isBusy ? null : _editLocalModelRow,
                              ),
                            if (_rowMatches('ai', 'Test Connection'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_test_local_connection'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.electrical_services_rounded,
                                label: 'Test Connection',
                                value: _localConnectionTestResult ??
                                    'Probe loopback for a running engine',
                                enabled: !_isBusy &&
                                    !_isTestingLocalConnection &&
                                    _isLocalEndpointValid,
                                onTap: _testLocalConnection,
                              ),
                            if (_rowMatches('ai', 'Detect Engines'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_detect_engines'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.radar_rounded,
                                label: 'Detect Engines',
                                value: _detectError ??
                                    (_detectedLocalEngines.isEmpty
                                        ? 'Scan loopback for installed engines'
                                        : '${_detectedLocalEngines.length} engine(s) found'),
                                enabled: !_isBusy && !_isDetectingLocalEngines,
                                onTap: _detectLocalEngines,
                              ),
                            if (_rowMatches('ai', 'Manage Models'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_manage_models'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.dns_rounded,
                                label: 'Manage Models',
                                value: 'Pull, list, or remove local models',
                                enabled: !_isBusy && _isLocalEndpointValid,
                                onTap: _openLocalModelManager,
                              ),
                            if (_rowMatches('ai', 'First-Run Setup'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_first_run_setup'),
                                iconColor: AppColors.accentAi,
                                icon: Icons.auto_fix_high_rounded,
                                label: 'First-Run Setup',
                                value: 'Walk through install + initial pull',
                                enabled: !_isBusy,
                                onTap: _runLocalAiOnboarding,
                              ),
                          ],
                        ),
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
                      SettingsRowGroup(
                        header: 'BATCH CADENCE',
                        children: [
                          if (_rowMatches('triage', 'Batch Size'))
                            SettingsRow.chevron(
                              key: const ValueKey(
                                  'settings_row_triage_batch_size'),
                              iconColor: AppColors.accentTriage,
                              icon: Icons.tune_rounded,
                              label: 'Batch Size',
                              value: _isLogTriageBatchSizeLoaded
                                  ? 'Analyse every $_logTriageBatchSize lines'
                                  : 'Loading…',
                              enabled:
                                  _isLogTriageBatchSizeLoaded && !_isBusy,
                              onTap: _editLogTriageBatchSizeRow,
                            ),
                        ],
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
                      SettingsRowGroup(
                        header: 'BACKGROUND MONITORING',
                        children: [
                          if (_rowMatches('health', 'Enable Background Monitoring'))
                            SettingsRow.toggle(
                              key: const ValueKey(
                                  'settings_row_health_enabled'),
                              iconColor: AppColors.accentHealth,
                              icon: Icons.monitor_heart_rounded,
                              label: 'Enable Background Monitoring',
                              value:
                                  'Periodically check all saved servers',
                              toggleValue: _healthMonitoringEnabled,
                              enabled: !_isBusy,
                              onToggle: _isBusy
                                  ? null
                                  : _setHealthMonitoringEnabled,
                            ),
                          if (_healthMonitoringEnabled &&
                              _rowMatches('health', 'Check Interval'))
                            SettingsRow.chevron(
                              key: const ValueKey(
                                  'settings_row_health_interval'),
                              iconColor: AppColors.accentHealth,
                              icon: Icons.timer_rounded,
                              label: 'Check Interval',
                              value: '$_healthCheckInterval minutes',
                              enabled: !_isBusy,
                              onTap: _isBusy ? null : _editHealthIntervalRow,
                            ),
                        ],
                      ),
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
                      SettingsRowGroup(
                        header: 'APP LOCK',
                        children: [
                          if (_rowMatches('security', 'App PIN'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_app_pin'),
                              iconColor: AppColors.accentSecurity,
                              icon: _hasAppPin == true
                                  ? Icons.lock_open_outlined
                                  : Icons.pin_outlined,
                              label: 'App PIN',
                              value: _hasAppPin == null
                                  ? 'Checking app lock status…'
                                  : _hasAppPin!
                                      ? 'Enabled — tap to remove'
                                      : 'Not set — tap to add',
                              enabled: _hasAppPin != null && !_isBusy,
                              onTap: _hasAppPin == null || _isBusy
                                  ? null
                                  : _openAppLockSettings,
                            ),
                        ],
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
                      SettingsRowGroup(
                        header: 'DESTINATION',
                        children: [
                          if (_rowMatches('backup', 'Backup Destination'))
                            SettingsRow.chevron(
                              key: const ValueKey(
                                  'settings_row_backup_destination'),
                              iconColor: AppColors.accentBackup,
                              icon: Icons.folder_zip_rounded,
                              label: 'Backup Destination',
                              value: _backupConfig.destination.name
                                  .toUpperCase(),
                              enabled: !_isBusy,
                              onTap:
                                  _isBusy ? null : _pickBackupDestination,
                            ),
                        ],
                      ),
                      if (_backupConfig.destination ==
                          BackupDestination.sftp) ...[
                        const SizedBox(height: 16),
                        SettingsRowGroup(
                          header: 'SFTP',
                          children: [
                            if (_rowMatches('backup', 'SFTP Host'))
                              SettingsRow.chevron(
                                key: const ValueKey('settings_row_sftp_host'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.dns_rounded,
                                label: 'SFTP Host',
                                value: _sftpHostController.text.isEmpty
                                    ? 'Not set'
                                    : _sftpHostController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _sftpHostController,
                                  title: 'SFTP Host',
                                  helperText: 'Hostname or IP of your server',
                                ),
                              ),
                            if (_rowMatches('backup', 'SFTP Username'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_sftp_username'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.person_outline_rounded,
                                label: 'Username',
                                value: _sftpUsernameController.text.isEmpty
                                    ? 'Not set'
                                    : _sftpUsernameController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _sftpUsernameController,
                                  title: 'SFTP Username',
                                ),
                              ),
                            if (_rowMatches('backup', 'SFTP Port'))
                              SettingsRow.chevron(
                                key: const ValueKey('settings_row_sftp_port'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.numbers_rounded,
                                label: 'Port',
                                value: _sftpPortController.text.isEmpty
                                    ? '22'
                                    : _sftpPortController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _sftpPortController,
                                  title: 'SFTP Port',
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                            if (_rowMatches('backup', 'SFTP Password'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_sftp_password'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.password_rounded,
                                label: 'Password',
                                value: _secretValueLabel(
                                    _sftpPasswordController.text),
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _sftpPasswordController,
                                  title: 'SFTP Password',
                                  helperText: 'SSH Password',
                                  obscure: true,
                                ),
                              ),
                            if (_rowMatches('backup', 'SFTP Backup Directory'))
                              SettingsRow.chevron(
                                key: const ValueKey('settings_row_sftp_path'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.folder_outlined,
                                label: 'Backup Directory',
                                value: _sftpPathController.text.isEmpty
                                    ? 'Not set'
                                    : _sftpPathController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _sftpPathController,
                                  title: 'Backup Directory',
                                  helperText: 'Absolute path on server',
                                  monospace: true,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (_backupConfig.destination ==
                          BackupDestination.webdav) ...[
                        const SizedBox(height: 16),
                        SettingsRowGroup(
                          header: 'WEBDAV',
                          children: [
                            if (_rowMatches('backup', 'WebDAV URL'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_webdav_url'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.link_rounded,
                                label: 'WebDAV URL',
                                value: _webdavUrlController.text.isEmpty
                                    ? 'Not set'
                                    : _webdavUrlController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _webdavUrlController,
                                  title: 'WebDAV URL',
                                  helperText:
                                      'e.g. https://nextcloud.com/remote.php/dav/files/user/',
                                  monospace: true,
                                ),
                              ),
                            if (_rowMatches('backup', 'WebDAV Username'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_webdav_username'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.person_outline_rounded,
                                label: 'Username',
                                value: _webdavUsernameController.text.isEmpty
                                    ? 'Not set'
                                    : _webdavUsernameController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _webdavUsernameController,
                                  title: 'WebDAV Username',
                                ),
                              ),
                            if (_rowMatches('backup', 'WebDAV Password'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_webdav_password'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.password_rounded,
                                label: 'Password / App Token',
                                value: _secretValueLabel(
                                    _webdavPasswordController.text),
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _webdavPasswordController,
                                  title: 'WebDAV Password',
                                  obscure: true,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (_backupConfig.destination ==
                          BackupDestination.syncthing) ...[
                        const SizedBox(height: 16),
                        SettingsRowGroup(
                          header: 'SYNCTHING',
                          children: [
                            if (_rowMatches('backup', 'Syncthing Local Path'))
                              SettingsRow.chevron(
                                key: const ValueKey(
                                    'settings_row_syncthing_path'),
                                iconColor: AppColors.accentBackup,
                                icon: Icons.folder_outlined,
                                label: 'Syncthing Local Path',
                                value: _syncthingPathController.text.isEmpty
                                    ? 'Not set'
                                    : _syncthingPathController.text,
                                enabled: !_isBusy,
                                onTap: () => _editBackupTextField(
                                  controller: _syncthingPathController,
                                  title: 'Syncthing Local Path',
                                  helperText:
                                      'The folder Syncthing monitors on this device',
                                  monospace: true,
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      SettingsRowGroup(
                        header: 'AUTOMATION',
                        children: [
                          if (_rowMatches('backup', 'Daily Automatic Backup'))
                            SettingsRow.toggle(
                              key: const ValueKey(
                                  'settings_row_daily_auto_backup'),
                              iconColor: AppColors.accentBackup,
                              icon: Icons.schedule_rounded,
                              label: 'Daily Automatic Backup',
                              value: 'Background backup over Wi-Fi',
                              toggleValue: _backupConfig.autoBackupEnabled,
                              enabled: !_isBusy,
                              onToggle: _setAutoBackupEnabled,
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SettingsRowGroup(
                        header: 'ACTIONS',
                        children: [
                          if (_rowMatches('backup', 'Backup Now'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_backup_now'),
                              iconColor: AppColors.accentBackup,
                              icon: Icons.backup_outlined,
                              label: 'Backup Now',
                              value: _backupConfig.lastBackupTime != null
                                  ? 'Last: ${_backupConfig.lastBackupTime!.toLocal().toString().split('.')[0]} '
                                      '(${_backupConfig.lastBackupStatus ?? 'Unknown'})'
                                  : 'Never run',
                              enabled: !_isBusy && !_isExportingBackup,
                              onTap: _exportBackup,
                            ),
                          if (_rowMatches('backup', 'Restore'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_restore'),
                              iconColor: AppColors.accentBackup,
                              icon: Icons.restore_outlined,
                              label: 'Restore',
                              value: 'Import a previous backup file',
                              enabled: !_isBusy && !_isImportingBackup,
                              onTap: _importBackup,
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SettingsRowGroup(
                        header: 'SYNC',
                        children: [
                          if (_rowMatches('backup', 'Cloud Sync (Encrypted)'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_cloud_sync'),
                              iconColor: AppColors.accentBackup,
                              icon: Icons.cloud_outlined,
                              label: 'Cloud Sync (Encrypted)',
                              value: 'End-to-end encrypted device sync',
                              enabled: !_isBusy,
                              onTap: _isBusy
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              const CloudSyncScreen(),
                                        ),
                                      );
                                    },
                            ),
                          if (_rowMatches('backup', 'Snippet Sync (Cross-Device)'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_snippet_sync'),
                              iconColor: AppColors.accentBackup,
                              icon: Icons.sync_alt_outlined,
                              label: 'Snippet Sync (Cross-Device)',
                              value: 'Share command snippets between devices',
                              enabled: !_isBusy,
                              onTap: _isBusy
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                            builder: (_) =>
                                                const SnippetSyncScreen()),
                                      );
                                    },
                            ),
                        ],
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SettingsRowGroup(
                        header: 'RESOURCES',
                        children: [
                          if (_rowMatches('support', 'Help Center'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_help_center'),
                              iconColor: AppColors.accentSupport,
                              icon: Icons.help_center_outlined,
                              label: 'Help Center',
                              value: 'Guides, FAQs, and troubleshooting',
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const HelpCenterScreen(),
                                  ),
                                );
                              },
                            ),
                          if (_rowMatches('support', 'Extensions'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_extensions'),
                              iconColor: AppColors.accentSupport,
                              icon: Icons.extension_outlined,
                              label: 'Extensions',
                              value: 'Manage installed Hamma extensions',
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const ExtensionsScreen(),
                                  ),
                                );
                              },
                            ),
                          if (_rowMatches('support', 'Vault'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_vault'),
                              iconColor: AppColors.accentSupport,
                              icon: Icons.lock_outline,
                              label: 'Vault',
                              value: 'Secrets and encrypted credentials',
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const VaultScreen(),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SettingsRowGroup(
                        header: 'FEEDBACK',
                        children: [
                          if (_rowMatches('support', 'Contact Support'))
                            SettingsRow.chevron(
                              key: const ValueKey('settings_row_contact'),
                              iconColor: AppColors.accentSupport,
                              icon: Icons.mail_outline,
                              label: 'Contact Support',
                              value: 'Email the Hamma team',
                              enabled: !_isBusy,
                              onTap: _isBusy ? null : _launchFeedbackEmail,
                            ),
                        ],
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

  // Sticky bottom bar exposing SAVE while there are unsaved AI-settings.
  // Reused by both the main settings Scaffold and the mobile per-category
  // detail route so edits made inside a pushed detail page don't leave the
  // user without a save affordance until they navigate back.
  Widget? _buildStickySaveBar(ThemeData theme) {
    if (!_isDirty && !_isSaving) return null;
    return SafeArea(
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
              // AnimatedBuilder rebuilds on dirty/saving state changes so
              // the save bar appears in the pushed route too.
              return AnimatedBuilder(
                animation: _saveBarTrigger,
                builder: (innerCtx, _) => Scaffold(
                key: ValueKey('settings_category_detail_$id'),
                appBar: AppBar(
                  title: Text(meta.title.toUpperCase()),
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(routeContext).pop(),
                  ),
                ),
                bottomNavigationBar: _buildStickySaveBar(routeTheme),
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
                ),
              );
            },
          ),
        )
        .whenComplete(() => ctrl.dispose());
  }

  static const Map<String, ({String title, IconData icon})> _categoryMeta = {
    'ai': (title: 'AI Configuration', icon: Icons.smart_toy_outlined),
    'triage': (title: 'AI Log Triage', icon: Icons.tune),
    'health':
        (title: 'Health Monitoring', icon: Icons.health_and_safety_outlined),
    'security': (title: 'Security', icon: Icons.lock_outline),
    'backup': (title: 'Backup & Restore', icon: Icons.cloud_sync_outlined),
    'support': (title: 'Support', icon: Icons.support_agent_outlined),
  };

  bool _categoryMatchesQuery(String id) {
    final q = _settingsSearchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    final meta = _categoryMeta[id];
    if (meta != null && meta.title.toLowerCase().contains(q)) return true;
    // Defer to the row registry so any row keyword that matches keeps
    // its parent category visible.
    final rows = _categoryRowKeywords[id];
    if (rows == null) return false;
    for (final entry in rows.entries) {
      if (entry.key.toLowerCase().contains(q) ||
          entry.value.toLowerCase().contains(q)) {
        return true;
      }
    }
    return false;
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
