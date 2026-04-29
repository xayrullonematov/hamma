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
import 'core/models/server_profile.dart';
import 'core/ssh/ssh_service.dart';
import 'core/storage/api_key_storage.dart';
import 'core/storage/app_lock_storage.dart';
import 'core/storage/app_prefs_storage.dart';
import 'core/storage/saved_servers_storage.dart';
import 'features/ai_assistant/global_command_palette.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/security/app_lock_screen.dart';
import 'features/servers/server_list_screen.dart';

/// Production flag to disable debug-only features and logs.
const bool kProduction = bool.fromEnvironment('dart.vm.product');

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Initialize desktop managers
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      await hotKeyManager.unregisterAll();
      
      const windowOptions = WindowOptions(
        size: Size(1100, 750),
        minimumSize: Size(800, 600),
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

        // Scrub sensitive data before sending
        options.beforeSend = (SentryEvent event, Hint hint) {
          if (event.message != null) {
            event.message = SentryMessage(
              event.message!.formatted.replaceAll(
                RegExp(r'password[:=]\s*\S+'),
                'password=[SCRUBBED]',
              ),
            );
          }

          // Remove sensitive keys from contexts if they exist
          for (final context in event.contexts.values) {
            if (context is Map) {
              context.removeWhere(
                (key, value) =>
                    key.toString().toLowerCase().contains('password') ||
                    key.toString().toLowerCase().contains('key') ||
                    key.toString().toLowerCase().contains('secret'),
              );
            }
          }

          return event;
        };
      },
      appRunner: () => runApp(app),
    );
  }, (exception, stackTrace) async {
    await Sentry.captureException(exception, stackTrace: stackTrace);
  });
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
  static const _scaffoldBackground = Color(0xFF0F172A);
  static const _surface = Color(0xFF1E293B);
  static const _primary = Color(0xFF3B82F6);
  static const _textMuted = Color(0xFF94A3B8);

  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late AiProvider _aiProvider;
  late String _apiKey;
  late String? _openRouterModel;
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

    // Use a placeholder icon for now (or app icon if available)
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
    );

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
          content: Text('Success: Command executed on ${profile.name}.\n${output.length > 80 ? "${output.substring(0, 80)}..." : output}'),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error executing on ${profile.name}: $e'),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
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
  ) async {
    await widget.apiKeyStorage.saveSettings(
      provider: provider,
      apiKey: apiKey,
      openRouterModel: openRouterModel,
    );

    setState(() {
      _aiProvider = provider;
      _apiKey = apiKey;
      _openRouterModel = openRouterModel;
    });
  }

  @override
  Widget build(BuildContext context) {
    const colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _primary,
      onPrimary: Colors.white,
      secondary: Color(0xFF10B981),
      onSecondary: Colors.white,
      error: Color(0xFFEF4444),
      onError: Colors.white,
      surface: _surface,
      onSurface: Color(0xFFF8FAFC),
    );

    final serverListScreen = ServerListScreen(
      aiProvider: _aiProvider,
      apiKey: _apiKey,
      openRouterModel: _openRouterModel,
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
    );

    return CommandPaletteManager(
      aiCommandService: aiCommandService,
      availableServers: _servers.map((s) => s.name).toList(),
      onExecute: _handleExecuteIntent,
      child: MaterialApp(
        title: 'Hamma',
        debugShowCheckedModeBanner: !kProduction,
        scaffoldMessengerKey: _messengerKey,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: colorScheme,
          scaffoldBackgroundColor: _scaffoldBackground,
          cardColor: _surface,
          canvasColor: _scaffoldBackground,
          dialogTheme: const DialogThemeData(backgroundColor: _surface),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: _surface,
            contentTextStyle: TextStyle(color: Colors.white),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: _scaffoldBackground,
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          cardTheme: const CardThemeData(
            color: _surface,
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF162033),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: _primary, width: 1.2),
            ),
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: _primary,
            foregroundColor: Colors.white,
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0xFF334155)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(foregroundColor: _primary),
          ),
          textTheme: const TextTheme(
            headlineSmall: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
            titleLarge: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
            titleMedium: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
            bodyLarge: TextStyle(color: Colors.white),
            bodyMedium: TextStyle(color: Colors.white),
            bodySmall: TextStyle(color: _textMuted),
          ),
        ),
        builder: (context, child) {
          if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
            return child!;
          }
          return Column(
            children: [
              Container(
                height: 32,
                color: const Color(0xFF0F172A),
                child: const DragToMoveArea(
                  child: Row(
                    children: [
                      SizedBox(width: 12),
                      Text(
                        'Hamma',
                        style: TextStyle(
                          fontSize: 12,
                          color: _textMuted,
                          fontWeight: FontWeight.w500,
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
}
