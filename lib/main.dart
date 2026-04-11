import 'package:flutter/material.dart';

import 'core/storage/api_key_storage.dart';
import 'features/servers/server_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const apiKeyStorage = ApiKeyStorage();
  String savedApiKey = '';
  String? apiKeyStartupWarning;

  try {
    savedApiKey = await apiKeyStorage.loadApiKey() ?? '';
  } catch (error) {
    apiKeyStartupWarning =
        'Could not load the saved API key. You can continue and re-save it in Settings.\n$error';
  }

  runApp(
    AiServerApp(
      apiKeyStorage: apiKeyStorage,
      initialApiKey: savedApiKey,
      initialApiKeyLoadError: apiKeyStartupWarning,
    ),
  );
}

class AiServerApp extends StatefulWidget {
  const AiServerApp({
    super.key,
    required this.apiKeyStorage,
    required this.initialApiKey,
    this.initialApiKeyLoadError,
  });

  final ApiKeyStorage apiKeyStorage;
  final String initialApiKey;
  final String? initialApiKeyLoadError;

  @override
  State<AiServerApp> createState() => _AiServerAppState();
}

class _AiServerAppState extends State<AiServerApp> {
  late String _apiKey;

  @override
  void initState() {
    super.initState();
    _apiKey = widget.initialApiKey;
  }

  Future<void> _saveApiKey(String apiKey) async {
    await widget.apiKeyStorage.saveApiKey(apiKey);
    setState(() {
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
        apiKey: _apiKey,
        onSaveApiKey: _saveApiKey,
        startupWarning: widget.initialApiKeyLoadError,
      ),
    );
  }
}
