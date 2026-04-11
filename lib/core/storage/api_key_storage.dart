import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiKeyStorage {
  const ApiKeyStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _apiKeyStorageKey = 'openai_api_key';

  final FlutterSecureStorage _secureStorage;

  Future<String?> loadApiKey() {
    return _secureStorage.read(key: _apiKeyStorageKey);
  }

  Future<void> saveApiKey(String apiKey) {
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      return _secureStorage.delete(key: _apiKeyStorageKey);
    }

    return _secureStorage.write(
      key: _apiKeyStorageKey,
      value: trimmedApiKey,
    );
  }
}
