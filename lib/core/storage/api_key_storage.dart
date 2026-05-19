// lib/core/storage/api_key_storage.dart
//
// FIX 3 (partial): Changed _defaultLocalModel from 'gemma3' (Ollama shortname)
// to 'gemma3-1b-it-q4' (BundledModel.id of the recommended catalog entry).
// This ensures that when no localModel has been explicitly saved, the model
// string in every OpenAI-compatible request matches the id the BundledEngine
// loaded — so LocalEngineHealthMonitor's /v1/models check finds a match and
// reports "online" rather than silently treating the engine as offline.
//
// The Ollama default 'gemma3' is still valid for users running an external
// Ollama daemon (who should have saved their model name via settings), but
// it was never the right fallback for the bundled engine.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ai/ai_provider.dart';

const _defaultLocalEndpoint = 'http://localhost:11434';

// CHANGED: was 'gemma3-1b-it-q4' — must match BundledModelCatalog.defaultPick.id.
// If you change the recommended model in bundled_model_catalog.dart, update
// this constant to match.
const _defaultLocalModel = 'hamma-gemma-4-devops-q4';

class AiSettings {
  const AiSettings({
    required this.provider,
    this.apiKeys = const {},
    this.openRouterModel,
    this.localEndpoint = _defaultLocalEndpoint,
    this.localModel = _defaultLocalModel,
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
      localEndpoint: _normalizeWithDefault(json['localEndpoint'], _defaultLocalEndpoint),
      localModel: _normalizeWithDefault(json['localModel'], _defaultLocalModel),
    );
  }

  final AiProvider provider;
  final Map<AiProvider, String> apiKeys;
  final String? openRouterModel;
  final String localEndpoint;
  final String localModel;

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
      'localEndpoint': localEndpoint,
      'localModel': localModel,
    };
  }

  static String? _normalizeOptionalString(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  static String _normalizeWithDefault(Object? value, String defaultValue) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? defaultValue : normalized;
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
  static const _localEndpointStorageKey = 'local_ai_endpoint';
  static const _localModelStorageKey = 'local_ai_model';

  final FlutterSecureStorage _secureStorage;

  Future<AiSettings> loadSettings() async {
    final storedProvider = await _secureStorage.read(key: _providerStorageKey);
    final storedOpenRouterModel = await _secureStorage.read(
      key: _openRouterModelStorageKey,
    );
    final storedLocalEndpoint = await _secureStorage.read(
      key: _localEndpointStorageKey,
    );
    final storedLocalModel = await _secureStorage.read(
      key: _localModelStorageKey,
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
      'localEndpoint': storedLocalEndpoint,
      'localModel': storedLocalModel,
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
    String? localEndpoint,
    String? localModel,
  }) async {
    final trimmedOpenRouterModel = openRouterModel?.trim() ?? '';
    final trimmedLocalEndpoint = localEndpoint?.trim() ?? '';
    final trimmedLocalModel = localModel?.trim() ?? '';

    await _secureStorage.write(
      key: _providerStorageKey,
      value: provider.storageValue,
    );

    if (apiKey != null) {
      await saveApiKey(provider, apiKey);
    }

    if (trimmedOpenRouterModel.isEmpty) {
      await _secureStorage.delete(key: _openRouterModelStorageKey);
    } else {
      await _secureStorage.write(
        key: _openRouterModelStorageKey,
        value: trimmedOpenRouterModel,
      );
    }

    await _secureStorage.write(
      key: _localEndpointStorageKey,
      value: trimmedLocalEndpoint.isEmpty ? _defaultLocalEndpoint : trimmedLocalEndpoint,
    );

    await _secureStorage.write(
      key: _localModelStorageKey,
      // CHANGED: falls back to the new _defaultLocalModel constant
      // ('gemma3-1b-it-q4') instead of the old 'gemma3' Ollama shortname.
      value: trimmedLocalModel.isEmpty ? _defaultLocalModel : trimmedLocalModel,
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
