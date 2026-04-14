import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ai/ai_provider.dart';

class AiSettings {
  const AiSettings({
    required this.provider,
    required this.apiKey,
  });

  final AiProvider provider;
  final String apiKey;
}

class ApiKeyStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const ApiKeyStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _apiKeyStorageKey = 'ai_api_key';
  static const _providerStorageKey = 'ai_provider';

  final FlutterSecureStorage _secureStorage;

  Future<AiSettings> loadSettings() async {
    final storedApiKey = await _secureStorage.read(key: _apiKeyStorageKey) ?? '';
    final storedProvider = await _secureStorage.read(key: _providerStorageKey);

    return AiSettings(
      provider: aiProviderFromStorage(storedProvider),
      apiKey: storedApiKey,
    );
  }

  Future<void> saveSettings({
    required AiProvider provider,
    required String apiKey,
  }) async {
    final trimmedApiKey = apiKey.trim();

    await _secureStorage.write(
      key: _providerStorageKey,
      value: provider.storageValue,
    );

    if (trimmedApiKey.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
      return;
    }

    await _secureStorage.write(
      key: _apiKeyStorageKey,
      value: trimmedApiKey,
    );
  }
}
