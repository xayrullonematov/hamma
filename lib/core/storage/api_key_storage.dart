import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ai/ai_provider.dart';

class AiSettings {
  const AiSettings({
    required this.provider,
    required this.apiKey,
    this.openRouterModel,
  });

  factory AiSettings.fromJson(Map<String, dynamic> json) {
    return AiSettings(
      provider: aiProviderFromStorage(json['provider']?.toString()),
      apiKey: (json['apiKey'] ?? '').toString(),
      openRouterModel: _normalizeOptionalString(json['openRouterModel']),
    );
  }

  final AiProvider provider;
  final String apiKey;
  final String? openRouterModel;

  Map<String, dynamic> toJson() {
    return {
      'provider': provider.storageValue,
      'apiKey': apiKey,
      'openRouterModel': openRouterModel,
    };
  }

  static String? _normalizeOptionalString(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}

class ApiKeyStorage {
  const ApiKeyStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _apiKeyStorageKey = 'ai_api_key';
  static const _providerStorageKey = 'ai_provider';
  static const _openRouterModelStorageKey = 'openrouter_model';

  final FlutterSecureStorage _secureStorage;

  Future<AiSettings> loadSettings() async {
    final storedApiKey = await _secureStorage.read(key: _apiKeyStorageKey) ?? '';
    final storedProvider = await _secureStorage.read(key: _providerStorageKey);
    final storedOpenRouterModel =
        await _secureStorage.read(key: _openRouterModelStorageKey);

    return AiSettings.fromJson({
      'provider': storedProvider,
      'apiKey': storedApiKey,
      'openRouterModel': storedOpenRouterModel,
    });
  }

  Future<void> saveSettings({
    required AiProvider provider,
    required String apiKey,
    String? openRouterModel,
  }) async {
    final trimmedApiKey = apiKey.trim();
    final trimmedOpenRouterModel = openRouterModel?.trim() ?? '';

    await _secureStorage.write(
      key: _providerStorageKey,
      value: provider.storageValue,
    );

    if (trimmedApiKey.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
    } else {
      await _secureStorage.write(
        key: _apiKeyStorageKey,
        value: trimmedApiKey,
      );
    }

    if (trimmedOpenRouterModel.isEmpty) {
      await _secureStorage.delete(key: _openRouterModelStorageKey);
      return;
    }

    await _secureStorage.write(
      key: _openRouterModelStorageKey,
      value: trimmedOpenRouterModel,
    );
  }
}
