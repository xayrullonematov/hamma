import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/ai/ai_command_service.dart';
import 'core/ai/ai_provider.dart';
import 'core/background/background_keepalive.dart';
import 'core/error/crash_screen.dart';
import 'core/error/error_reporter.dart';
import 'core/error/error_scrubber.dart';
import 'core/models/server_profile.dart';
import 'core/ssh/ssh_service.dart';
import 'core/storage/api_key_storage.dart';
import 'core/storage/app_lock_storage.dart';
import 'core/storage/app_prefs_storage.dart';
import 'core/storage/saved_servers_storage.dart';
import 'core/sync/runbook_sync_service.dart';
import 'core/sync/snippet_sync_service.dart';
import 'core/sync/snippet_sync_storage.dart';
import 'core/sync/vault_sync_service.dart';
import 'core/vault/vault_change_bus.dart';
import 'core/vault/vault_redactor.dart';
import 'core/vault/vault_storage.dart';
import 'core/theme/app_colors.dart';
import 'features/ai_assistant/global_command_palette.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'plugins/plugin_registry.dart';
import 'features/security/app_lock_screen.dart';
import 'features/servers/server_list_screen.dart';

/// Production flag to disable debug-only features and logs.
const bool kProduction = bool.fromEnvironment('dart.vm.product');

/// Number of consecutive in-process restart attempts. Incremented every
/// time the user taps **TRY RESTART** on the crash screen. When this
/// exceeds [_maxRestartAttempts] the restart button is hidden so a
/// deterministic startup failure can't trap the user in an infinite
/// crash → restart → crash loop.
int _restartAttempts = 0;
const int _maxRestartAttempts = 3;

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Install our error hooks (FlutterError.onError, PlatformDispatcher
    // .instance.onError, ErrorWidget.builder) BEFORE SentryFlutter.init
    // so Sentry's own integrations layer on top and chain to ours
    // rather than replacing them.
    ErrorReporter.install();

    try {
      await _bootstrapAndRun();
      // Successful boot — reset the restart counter so a subsequent
      // failure starts from a fresh budget rather than inheriting
      // attempts from earlier in this session.
      _restartAttempts = 0;
    } catch (error, stack) {
      // Fatal startup failure: report and fall back to the standalone
      // crash screen so the user sees a friendly recovery UI instead
      // of a black window. Suppress the restart button after enough
      // consecutive failures so a deterministic crash can't loop.
      await ErrorReporter.report(error, stack, hint: 'Startup failure');
      final canRestart = _restartAttempts < _maxRestartAttempts;
      runApp(CrashApp(
        error: error,
        stackTrace: stack,
        hint: canRestart
            ? 'Hamma failed to start.'
            : 'Hamma failed to start, and automatic restart has been '
                'disabled after $_restartAttempts attempts. Please quit '
                'and relaunch.',
        onRestart: canRestart
            ? () {
                _restartAttempts++;
                main();
              }
            : null,
      ));
    }
  }, (exception, stackTrace) async {
    // Async errors that escaped the zone — also funnel through the
    // central reporter so they appear on the crash screen if fatal.
    await ErrorReporter.report(exception, stackTrace,
        hint: 'Uncaught async error');
  });
}

/// Performs the full app startup sequence and calls `runApp` exactly
/// once on success. Any exception escapes to the caller in `main` so
/// the crash-screen fallback can be shown.
Future<void> _bootstrapAndRun() async {
  // Initialize desktop managers
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await hotKeyManager.unregisterAll();

    const windowOptions = WindowOptions(
      size: Size(1100, 750),
      // Allow shrinking down to phone-class width so the responsive
      // (mobile) layout can be tested directly on desktop.
      minimumSize: Size(360, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await windowManager.setPreventClose(true);
  }

  // Initialize notifications
  final notifications = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  await notifications.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
  );

  // Initialize background sentinel
  await BackgroundKeepalive.initialize();

  const apiKeyStorage = ApiKeyStorage();
  const appLockStorage = AppLockStorage();
  const appPrefsStorage = AppPrefsStorage();

  var savedSettings = const AiSettings(
    provider: AiProvider.openAi,
    openRouterModel: null,
  );
  String? aiSettingsStartupWarning;
  var hasAppPin = false;
  var isOnboardingComplete = false;

  try {
    savedSettings = await apiKeyStorage.loadSettings();
  } catch (error) {
    aiSettingsStartupWarning =
        'Could not load the saved AI settings. You can continue and re-save them in Settings.\n$error';
  }

  try {
    hasAppPin = await appLockStorage.hasPin();
  } catch (_) {
    hasAppPin = false;
  }

  try {
    isOnboardingComplete = await appPrefsStorage.isOnboardingComplete();
  } catch (_) {
    isOnboardingComplete = false;
  }

  // Start health monitoring if enabled
  try {
    if (await appPrefsStorage.isHealthMonitoringEnabled()) {
      final interval = await appPrefsStorage.getHealthCheckInterval();
      await BackgroundKeepalive.enable(intervalMinutes: interval);
    }
  } catch (_) {}

  // Plugin registry (Phase 7) — register the compiled-in builtins
  // and load persisted enabled-state. Best-effort: a failure here
  // simply means no plugin tabs show up in the dashboard until the
  // next launch, never a crash.
  try {
    PluginRegistry.instance.registerBuiltins();
    await PluginRegistry.instance.load();
  } catch (_) {
    // Plugin loading is non-critical; never block app launch on it.
  }

  // Cross-device snippet sync (Phase 5.1) — opt-in. Bind a single,
  // long-lived service to the snippet change-bus so debounced pushes
  // fire on every local edit even before the user opens the settings
  // screen. The instance is intentionally retained for the lifetime
  // of the process; both push() and pull() runtime-gate on the
  // `isEnabled` flag so flipping the toggle takes effect without
  // restarting it. Pull-and-merge runs once on launch (best-effort)
  // so snippets edited on another device are visible immediately.
  try {
    final snippetSync = SnippetSyncService()..start();
    if (await const SnippetSyncStorage().isEnabled()) {
      // Fire-and-forget; never blocks startup.
      unawaited(snippetSync.pullAndMerge());
    }
  } catch (_) {
    // Snippet sync is non-critical; never block app launch on it.
  }

  // Per-server secrets vault (Task #31). Two pieces stand up here:
  //
  //   1. Seed the GlobalVaultRedactor from disk so the first error,
  //      AI prompt, or Sentry breadcrumb after launch already sees
  //      the right values to redact — there is no "secrets aren't
  //      registered yet" gap. Subsequent edits re-seed via the
  //      VaultChangeBus listener below.
  //   2. Start the VaultSyncService so per-device edits ride the
  //      same cloud blob already used for snippets/runbooks.
  //
  // Both are wrapped in best-effort try/catch — vault wiring must
  // never block app launch.
  try {
    final vaultStorage = VaultStorage();
    final initial = await vaultStorage.loadAll();
    GlobalVaultRedactor.set(VaultRedactor.from(initial));
    VaultChangeBus.instance.changes.listen((_) async {
      try {
        final next = await vaultStorage.loadAll();
        GlobalVaultRedactor.set(VaultRedactor.from(next));
      } catch (_) {/* best-effort */}
    });
    final vaultSync = VaultSyncService(
      vaultStorage: vaultStorage,
      deviceId: await vaultStorage.getOrCreateDeviceId(),
    )..start();
    if (await const SnippetSyncStorage().isEnabled()) {
      unawaited(vaultSync.pullAndMerge());
    }
  } catch (_) {
    // Vault sync/redactor seeding is non-critical; never block launch.
  }

  // Cross-device runbook sync (Phase 8) — sibling of snippet sync.
  // Only `team:true` runbooks ride the wire; everything else stays
  // on the originating device. Reuses the same encrypted blob /
  // password / cloud-adapter stack so flipping the snippet sync
  // toggle in settings activates this too.
  try {
    final runbookSync = RunbookSyncService()..start();
    if (await const SnippetSyncStorage().isEnabled()) {
      unawaited(runbookSync.pullAndMerge());
    }
  } catch (_) {
    // Runbook sync is non-critical; never block app launch on it.
  }

  // Sentry DSN can be hardcoded for production or overridden by dev config
  const productionDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

  final app = AiServerApp(
    apiKeyStorage: apiKeyStorage,
    appLockStorage: appLockStorage,
    appPrefsStorage: appPrefsStorage,
    initialSettings: savedSettings,
    initialHasAppPin: hasAppPin,
    initialIsOnboardingComplete: isOnboardingComplete,
    initialAiSettingsLoadError: aiSettingsStartupWarning,
  );

  if (productionDsn.isEmpty) {
    runApp(app);
    return;
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = kProduction ? productionDsn : '';
      options.tracesSampleRate = 1.0;
      options.attachStacktrace = true;
      options.enableAutoSessionTracking = true;

      // Transport-side scrubbing: every event leaving the device
      // passes through the same scrubber the in-app crash screen uses
      // so the two views of an error stay consistent.
      //
      // ErrorScrubber.scrub already runs the GlobalVaultRedactor as a
      // pre-pass, so calling it once on every string-shaped field
      // gets us regex-pattern scrubbing AND vault-value redaction in
      // one go.
      options.beforeSend = (SentryEvent event, Hint hint) {
        String s(String? input) => ErrorScrubber.scrub(input ?? '');
        Object? scrubAny(Object? value) {
          if (value == null) return null;
          if (value is String) return s(value);
          if (value is num || value is bool) return value;
          if (value is Map) {
            return value.map(
              (k, v) => MapEntry(k, scrubAny(v)),
            );
          }
          if (value is List) return value.map(scrubAny).toList();
          return s(value.toString());
        }

        // 1. message (formatted + template + params)
        if (event.message != null) {
          event.message = SentryMessage(
            s(event.message!.formatted),
            template: event.message!.template == null
                ? null
                : s(event.message!.template),
            params: event.message!.params
                ?.map((p) => scrubAny(p))
                .toList(growable: false),
          );
        }

        // 2. exception values (the human-readable thrown text)
        if (event.exceptions != null) {
          for (final ex in event.exceptions!) {
            ex.value = s(ex.value);
          }
        }

        // 3. breadcrumbs (message + the entire data map). These are
        //    the worst leak surface in practice — every navigation,
        //    HTTP call, and console log lands here.
        if (event.breadcrumbs != null) {
          for (final b in event.breadcrumbs!) {
            b.message = b.message == null ? null : s(b.message);
            if (b.data != null) {
              b.data = (scrubAny(b.data) as Map).cast<String, dynamic>();
            }
          }
        }

        // 4. tags: short labels but they CAN contain user input.
        if (event.tags != null) {
          event.tags = event.tags!.map((k, v) => MapEntry(k, s(v)));
        }

        // 6. contexts: drop obviously sensitive keys outright, then
        //    recursively scrub everything that survives.
        for (final entry in event.contexts.entries.toList()) {
          final value = entry.value;
          if (value is Map) {
            value.removeWhere(
              (k, _) =>
                  k.toString().toLowerCase().contains('password') ||
                  k.toString().toLowerCase().contains('key') ||
                  k.toString().toLowerCase().contains('secret') ||
                  k.toString().toLowerCase().contains('token'),
            );
            // Now scrub the surviving values in place.
            value.forEach((k, v) {
              value[k] = scrubAny(v);
            });
          }
        }

        return event;
      };
    },
    appRunner: () => runApp(app),
  );
}

class AiServerApp extends StatefulWidget {
  const AiServerApp({
    super.key,
    required this.apiKeyStorage,
    required this.appLockStorage,
    required this.appPrefsStorage,
    required this.initialSettings,
    required this.initialHasAppPin,
    required this.initialIsOnboardingComplete,
    this.initialAiSettingsLoadError,
  });

  final ApiKeyStorage apiKeyStorage;
  final AppLockStorage appLockStorage;
  final AppPrefsStorage appPrefsStorage;
  final AiSettings initialSettings;
  final bool initialHasAppPin;
  final bool initialIsOnboardingComplete;
  final String? initialAiSettingsLoadError;

  @override
  State<AiServerApp> createState() => _AiServerAppState();
}

class _AiServerAppState extends State<AiServerApp> with TrayListener, WindowListener {
  static const _scaffoldBackground = AppColors.scaffoldBackground;
  static const _surface = AppColors.surface;
  static const _primary = AppColors.primary;

  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late AiProvider _aiProvider;
  late String _apiKey;
  late String? _openRouterModel;
  late String _localEndpoint;
  late String _localModel;
  late bool _isOnboardingComplete;
  List<ServerProfile> _servers = [];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initTray();
    
    _aiProvider = widget.initialSettings.provider;
    _apiKey = widget.initialSettings.apiKey;
    _openRouterModel = widget.initialSettings.openRouterModel;
    _localEndpoint = widget.initialSettings.localEndpoint;
    _localModel = widget.initialSettings.localModel;
    _isOnboardingComplete = widget.initialIsOnboardingComplete;
    _loadServers();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) return;

    await trayManager.setIcon('assets/images/logo.png');

    final menu = Menu(
      items: [
        MenuItem(
          key: 'show_hamma',
          label: 'Show Hamma',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit_hamma',
          label: 'Quit',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  @override
  void onWindowClose() async {
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_hamma') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'quit_hamma') {
      await windowManager.destroy();
    }
  }

  Future<void> _loadServers() async {
    try {
      final servers = await const SavedServersStorage().loadServers();
      if (mounted) {
        setState(() {
          _servers = servers;
        });
      }
    } catch (_) {
      // Ignore initial load errors for palette
    }
  }

  Future<void> _handleExecuteIntent(CommandIntent intent) async {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;

    final targetName = intent.targetServer?.toLowerCase();
    if (targetName == null || targetName.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Target server not found.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    final profile = _servers.firstWhere(
      (s) => s.name.toLowerCase() == targetName || s.id == targetName,
      orElse: () => ServerProfile(
        id: '',
        name: '',
        host: '',
        port: 22,
        username: '',
        password: '',
      ),
    );

    if (profile.id.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Target server not found.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('Connecting and executing...'), behavior: SnackBarBehavior.floating),
    );

    final sshService = SshService(); // Use a fresh instance for background execution
    try {
      await sshService.connect(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        password: profile.password,
        privateKey: profile.privateKey,
        privateKeyPassword: profile.privateKeyPassword,
      );

      final output = await sshService.execute(intent.command);
      
      messenger.showSnackBar(
        SnackBar(
          content: Text('OK: Command executed on ${profile.name}.\n${output.length > 80 ? "${output.substring(0, 80)}..." : output}'),
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: AppColors.borderStrong),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('ERROR on ${profile.name}: $e'),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
          ),
        ),
      );
    } finally {
      await sshService.disconnect();
    }
  }

  Future<void> _saveAiSettings(
    AiProvider provider,
    String apiKey,
    String? openRouterModel,
    String? localEndpoint,
    String? localModel,
  ) async {
    await widget.apiKeyStorage.saveSettings(
      provider: provider,
      apiKey: apiKey,
      openRouterModel: openRouterModel,
      localEndpoint: localEndpoint,
      localModel: localModel,
    );

    setState(() {
      _aiProvider = provider;
      _apiKey = apiKey;
      _openRouterModel = openRouterModel;
      if (localEndpoint != null) _localEndpoint = localEndpoint;
      if (localModel != null) _localModel = localModel;
    });
  }

  @override
  Widget build(BuildContext context) {
    const colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _primary,
      onPrimary: AppColors.onPrimary,
      secondary: AppColors.primary,
      onSecondary: AppColors.onPrimary,
      error: AppColors.danger,
      onError: Colors.white,
      surface: _surface,
      onSurface: AppColors.textPrimary,
      outline: AppColors.border,
      outlineVariant: AppColors.borderStrong,
    );

    final serverListScreen = ServerListScreen(
      aiProvider: _aiProvider,
      apiKey: _apiKey,
      openRouterModel: _openRouterModel,
      localEndpoint: _localEndpoint,
      localModel: _localModel,
      onSaveAiSettings: _saveAiSettings,
      startupWarning: widget.initialAiSettingsLoadError,
    );

    final initialScreen =
        _isOnboardingComplete
            ? (widget.initialHasAppPin
                ? AppLockScreen(
                  mode: AppLockMode.verify,
                  appLockStorage: widget.appLockStorage,
                  nextScreen: serverListScreen,
                )
                : serverListScreen)
            : OnboardingScreen(
              appPrefsStorage: widget.appPrefsStorage,
              onComplete: () {
                setState(() {
                  _isOnboardingComplete = true;
                });
              },
            );

    final aiCommandService = AiCommandService.forProvider(
      provider: _aiProvider,
      apiKey: _apiKey,
      openRouterModel: _openRouterModel,
      localEndpoint: _localEndpoint,
      localModel: _localModel,
    );

    return CommandPaletteManager(
      aiCommandService: aiCommandService,
      availableServers: _servers.map((s) => s.name).toList(),
      onExecute: _handleExecuteIntent,
      child: MaterialApp(
        title: 'Hamma',
        debugShowCheckedModeBanner: !kProduction,
        scaffoldMessengerKey: _messengerKey,
        theme: _buildBrutalistTheme(colorScheme),
        builder: (context, child) {
          if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
            return child!;
          }
          return Column(
            children: [
              Container(
                height: 32,
                decoration: const BoxDecoration(
                  color: AppColors.scaffoldBackground,
                  border: Border(
                    bottom: BorderSide(color: AppColors.border, width: 1),
                  ),
                ),
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      const SizedBox(width: 10),
                      // Logo mark
                      Image.asset(
                        AppColors.logoAsset,
                        width: 18,
                        height: 18,
                        filterQuality: FilterQuality.high,
                      ),
                      const SizedBox(width: 7),
                      // Wordmark in brand cyan
                      const Text(
                        'HAMMA',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.4,
                          fontFamily: AppColors.monoFamily,
                          fontFamilyFallback: AppColors.monoFallback,
                        ),
                      ),
                      Expanded(
                        child: WindowCaption(
                          brightness: Brightness.dark,
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: child!),
            ],
          );
        },
        home: initialScreen,
      ),
    );
  }

  /// Builds the global brutalist ThemeData.
  ///
  /// Pillars:
  /// 1. Pure black scaffold, near-black surfaces, white primary,
  ///    harsh red (#FF0000) for danger.
  /// 2. Zero-radius corners across every component.
  /// 3. Wireframe 1px borders replace all elevation/shadows.
  /// 4. Geometric sans (Inter/Geist) globally; monospace
  ///    (JetBrains Mono/Geist Mono) reserved for technical data.
  /// 5. AppBar blends seamlessly with the scaffold (elevation 0).
  ThemeData _buildBrutalistTheme(ColorScheme scheme) {
    const sansFamily = AppColors.sansFamily;
    const monoFamily = AppColors.monoFamily;
    const sansFallback = AppColors.sansFallback;

    const wireframeBorder = OutlineInputBorder(
      borderRadius: BorderRadius.zero,
      borderSide: BorderSide(color: AppColors.border, width: 1),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      scaffoldBackgroundColor: _scaffoldBackground,
      cardColor: _surface,
      canvasColor: _scaffoldBackground,
      dividerColor: AppColors.border,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.white10,
      hoverColor: Colors.white10,
      dialogTheme: const DialogThemeData(
        backgroundColor: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.borderStrong, width: 1),
        ),
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
        contentTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontFamily: sansFamily,
          fontFamilyFallback: sansFallback,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: _surface,
        modalBackgroundColor: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.borderStrong, width: 1),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: _surface,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.borderStrong, width: 1),
        ),
        contentTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
          fontSize: 13,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _scaffoldBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
      ),
      cardTheme: const CardThemeData(
        color: _surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppColors.panel,
        border: wireframeBorder,
        enabledBorder: wireframeBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.textPrimary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.danger, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.danger, width: 1.5),
        ),
        labelStyle: TextStyle(color: AppColors.textMuted),
        hintStyle: TextStyle(color: AppColors.textFaint),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          disabledBackgroundColor: AppColors.surface,
          disabledForegroundColor: AppColors.textFaint,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            fontFamily: sansFamily,
            fontFamilyFallback: sansFallback,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          elevation: 0,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.borderStrong, width: 1),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            fontFamily: sansFamily,
            fontFamilyFallback: sansFallback,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            fontFamily: sansFamily,
            fontFamilyFallback: sansFallback,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: AppColors.panel,
        selectedColor: AppColors.primary,
        side: BorderSide(color: AppColors.border, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        labelStyle: TextStyle(
          color: AppColors.textPrimary,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
          fontSize: 11,
          letterSpacing: 0.8,
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.fromBorderSide(
            BorderSide(color: AppColors.borderStrong, width: 1),
          ),
          borderRadius: BorderRadius.zero,
        ),
        textStyle: TextStyle(
          color: AppColors.textPrimary,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
          fontSize: 11,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.textPrimary,
        linearTrackColor: AppColors.border,
        circularTrackColor: AppColors.border,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.textPrimary,
        inactiveTrackColor: AppColors.border,
        thumbColor: AppColors.textPrimary,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.onPrimary
              : AppColors.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primary
              : AppColors.panel,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(AppColors.border),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        side: const BorderSide(color: AppColors.borderStrong, width: 1),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primary
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(AppColors.onPrimary),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.textPrimary
              : AppColors.textMuted,
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: AppColors.accent,
        unselectedLabelColor: AppColors.textMuted,
        indicatorColor: AppColors.accent,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: AppColors.border,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textPrimary,
        textColor: AppColors.textPrimary,
        tileColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.borderStrong, width: 1),
        ),
        textStyle: TextStyle(
          color: AppColors.textPrimary,
          fontFamily: sansFamily,
          fontFamilyFallback: sansFallback,
        ),
      ),
      menuTheme: const MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(AppColors.surface),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide(color: AppColors.borderStrong, width: 1),
            ),
          ),
        ),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.scaffoldBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: AppColors.accentDim,
        indicatorShape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.accent);
          }
          return const IconThemeData(color: AppColors.textMuted);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w600);
          }
          return const TextStyle(color: AppColors.textMuted, fontSize: 11);
        }),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        displayMedium: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        displaySmall: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
        ),
        headlineLarge: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
        headlineMedium: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
        headlineSmall: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          fontFamily: monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
        ),
        titleLarge: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
        titleMedium: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
        titleSmall: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: AppColors.textPrimary),
        bodyMedium: TextStyle(color: AppColors.textPrimary),
        bodySmall: TextStyle(color: AppColors.textMuted),
        labelLarge: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
        labelMedium: TextStyle(
          color: AppColors.textMuted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
        labelSmall: TextStyle(
          color: AppColors.textMuted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
