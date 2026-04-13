import 'package:flutter/material.dart';

import 'core/ai/ai_provider.dart';
import 'core/storage/api_key_storage.dart';
import 'features/servers/server_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const apiKeyStorage = ApiKeyStorage();
  var savedSettings = const AiSettings(
    provider: AiProvider.openAi,
    apiKey: '',
  );
  String? aiSettingsStartupWarning;

  try {
    savedSettings = await apiKeyStorage.loadSettings();
  } catch (error) {
    aiSettingsStartupWarning =
        'Could not load the saved AI settings. You can continue and re-save them in Settings.\n$error';
  }

  runApp(
    AiServerApp(
      apiKeyStorage: apiKeyStorage,
      initialSettings: savedSettings,
      initialAiSettingsLoadError: aiSettingsStartupWarning,
    ),
  );
}

class AiServerApp extends StatefulWidget {
  const AiServerApp({
    super.key,
    required this.apiKeyStorage,
    required this.initialSettings,
    this.initialAiSettingsLoadError,
  });

  final ApiKeyStorage apiKeyStorage;
  final AiSettings initialSettings;
  final String? initialAiSettingsLoadError;

  @override
  State<AiServerApp> createState() => _AiServerAppState();
}

class _AiServerAppState extends State<AiServerApp> {
  late AiProvider _aiProvider;
  late String _apiKey;

  @override
  void initState() {
    super.initState();
    _aiProvider = widget.initialSettings.provider;
    _apiKey = widget.initialSettings.apiKey;
  }

  Future<void> _saveAiSettings(AiProvider provider, String apiKey) async {
    await widget.apiKeyStorage.saveSettings(
      provider: provider,
      apiKey: apiKey,
    );

    setState(() {
      _aiProvider = provider;
      _apiKey = apiKey;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Server V2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6F5F)),
      ),
      home: ServerListScreen(
        aiProvider: _aiProvider,
        apiKey: _apiKey,
        onSaveAiSettings: _saveAiSettings,
        startupWarning: widget.initialAiSettingsLoadError,
      ),
    );
  }
}
