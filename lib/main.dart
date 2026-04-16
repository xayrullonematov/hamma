import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'core/ai/ai_provider.dart';
import 'core/background/background_keepalive.dart';
import 'core/storage/api_key_storage.dart';
import 'core/storage/app_lock_storage.dart';
import 'features/security/app_lock_screen.dart';
import 'features/servers/server_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundKeepalive.initialize();

  const apiKeyStorage = ApiKeyStorage();
  const appLockStorage = AppLockStorage();
  var savedSettings = const AiSettings(
    provider: AiProvider.openAi,
    openRouterModel: null,
  );
  String? aiSettingsStartupWarning;
  var hasAppPin = false;

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

  await SentryFlutter.init(
    (options) {
      options.dsn =
          'https://61903110a3e1bd10a89811e3c87f2f24@o4511222528802816.ingest.de.sentry.io/4511222565568592';
      options.tracesSampleRate = 1.0;
    },
    appRunner: () {
      runApp(
        AiServerApp(
          apiKeyStorage: apiKeyStorage,
          appLockStorage: appLockStorage,
          initialSettings: savedSettings,
          initialHasAppPin: hasAppPin,
          initialAiSettingsLoadError: aiSettingsStartupWarning,
        ),
      );
    },
  );
}

class AiServerApp extends StatefulWidget {
  const AiServerApp({
    super.key,
    required this.apiKeyStorage,
    required this.appLockStorage,
    required this.initialSettings,
    required this.initialHasAppPin,
    this.initialAiSettingsLoadError,
  });

  final ApiKeyStorage apiKeyStorage;
  final AppLockStorage appLockStorage;
  final AiSettings initialSettings;
  final bool initialHasAppPin;
  final String? initialAiSettingsLoadError;

  @override
  State<AiServerApp> createState() => _AiServerAppState();
}

class _AiServerAppState extends State<AiServerApp> {
  static const _scaffoldBackground = Color(0xFF0F172A);
  static const _surface = Color(0xFF1E293B);
  static const _primary = Color(0xFF3B82F6);
  static const _textMuted = Color(0xFF94A3B8);

  late AiProvider _aiProvider;
  late String _apiKey;
  late String? _openRouterModel;

  @override
  void initState() {
    super.initState();
    _aiProvider = widget.initialSettings.provider;
    _apiKey = widget.initialSettings.apiKey;
    _openRouterModel = widget.initialSettings.openRouterModel;
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

    return MaterialApp(
      title: 'AI Server V2',
      debugShowCheckedModeBanner: false,
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
      home:
          widget.initialHasAppPin
              ? AppLockScreen(
                mode: AppLockMode.verify,
                appLockStorage: widget.appLockStorage,
                nextScreen: serverListScreen,
              )
              : serverListScreen,
    );
  }
}
