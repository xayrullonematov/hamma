import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ai/ai_provider.dart';

class AiSettings {
  const AiSettings({
    required this.provider,
    this.apiKeys = const {},
    this.openRouterModel,
  });

  factory AiSettings.fromJson(Map<String, dynamic> json) {
    final provider = aiProviderFromStorage(json['provider']?.toString());
    return AiSettings(
      provider: provider,
      apiKeys: _parseApiKeys(
        json['apiKeys'],
        provider: provider,
        legacyApiKey: json['apiKey'],
      ),
      openRouterModel: _normalizeOptionalString(json['openRouterModel']),
    );
  }

  final AiProvider provider;
  final Map<AiProvider, String> apiKeys;
  final String? openRouterModel;

  String get apiKey => apiKeyFor(provider);

  String apiKeyFor(AiProvider provider) {
    return _normalizeKey(apiKeys[provider]);
  }

  Map<String, dynamic> toJson() {
    return {
      'provider': provider.storageValue,
      'apiKey': apiKey,
      'apiKeys': {
        for (final provider in AiProvider.values)
          provider.storageValue: apiKeyFor(provider),
      },
      'openRouterModel': openRouterModel,
    };
  }

  static String? _normalizeOptionalString(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  static Map<AiProvider, String> _parseApiKeys(
    Object? value, {
    required AiProvider provider,
    Object? legacyApiKey,
  }) {
    final parsedKeys = <AiProvider, String>{};

    if (value is Map) {
      for (final entry in value.entries) {
        final resolvedProvider = aiProviderFromStorage(entry.key.toString());
        parsedKeys[resolvedProvider] = _normalizeKey(entry.value);
      }
    }

    final legacyKey = _normalizeKey(legacyApiKey);
    if (legacyKey.isNotEmpty && (parsedKeys[provider] ?? '').isEmpty) {
      parsedKeys[provider] = legacyKey;
    }

    return Map<AiProvider, String>.unmodifiable(parsedKeys);
  }

  static String _normalizeKey(Object? value) {
    return value?.toString().trim() ?? '';
  }
}

class ApiKeyStorage {
  const ApiKeyStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _legacyApiKeyStorageKey = 'ai_api_key';
  static const _providerStorageKey = 'ai_provider';
  static const _openRouterModelStorageKey = 'openrouter_model';

  final FlutterSecureStorage _secureStorage;

  Future<AiSettings> loadSettings() async {
    final storedProvider = await _secureStorage.read(key: _providerStorageKey);
    final storedOpenRouterModel = await _secureStorage.read(
      key: _openRouterModelStorageKey,
    );
    final apiKeys = <AiProvider, String>{};

    for (final provider in AiProvider.values) {
      final storedKey = await loadApiKey(provider);
      if (storedKey != null) {
        apiKeys[provider] = storedKey;
      }
    }

    return AiSettings.fromJson({
      'provider': storedProvider,
      'apiKeys': {
        for (final provider in AiProvider.values)
          provider.storageValue: apiKeys[provider] ?? '',
      },
      'openRouterModel': storedOpenRouterModel,
    });
  }

  Future<void> saveApiKey(AiProvider provider, String key) async {
    final trimmedKey = key.trim();
    if (trimmedKey.isEmpty) {
      await deleteApiKey(provider);
      return;
    }

    await _secureStorage.write(
      key: _apiKeyStorageKey(provider),
      value: trimmedKey,
    );
    await _secureStorage.delete(key: _legacyApiKeyStorageKey);
  }

  Future<String?> loadApiKey(AiProvider provider) async {
    final storedKey = _normalizeOptionalString(
      await _secureStorage.read(key: _apiKeyStorageKey(provider)),
    );
    if (storedKey != null) {
      return storedKey;
    }

    final storedProvider = aiProviderFromStorage(
      await _secureStorage.read(key: _providerStorageKey),
    );
    if (storedProvider != provider) {
      return null;
    }

    final legacyKey = _normalizeOptionalString(
      await _secureStorage.read(key: _legacyApiKeyStorageKey),
    );
    if (legacyKey == null) {
      return null;
    }

    await _secureStorage.write(
      key: _apiKeyStorageKey(provider),
      value: legacyKey,
    );
    await _secureStorage.delete(key: _legacyApiKeyStorageKey);
    return legacyKey;
  }

  Future<void> deleteApiKey(AiProvider provider) async {
    await _secureStorage.delete(key: _apiKeyStorageKey(provider));

    final storedProvider = aiProviderFromStorage(
      await _secureStorage.read(key: _providerStorageKey),
    );
    if (storedProvider == provider) {
      await _secureStorage.delete(key: _legacyApiKeyStorageKey);
    }
  }

  Future<void> saveSettings({
    required AiProvider provider,
    String? apiKey,
    String? openRouterModel,
  }) async {
    final trimmedOpenRouterModel = openRouterModel?.trim() ?? '';

    await _secureStorage.write(
      key: _providerStorageKey,
      value: provider.storageValue,
    );

    if (apiKey != null) {
      await saveApiKey(provider, apiKey);
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

  String _apiKeyStorageKey(AiProvider provider) {
    return 'api_key_${provider.name}';
  }

  String? _normalizeOptionalString(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}
