import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppPrefsStorage {
  const AppPrefsStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _onboardingCompleteKey = 'onboarding_complete';
  static const _showHiddenFilesKey = 'show_hidden_files';
  static const _fileSortModeKey = 'file_sort_mode';

  final FlutterSecureStorage _secureStorage;

  Future<bool> isOnboardingComplete() async {
    final value = await _secureStorage.read(key: _onboardingCompleteKey);
    return value == 'true';
  }

  Future<void> setOnboardingComplete() async {
    await _secureStorage.write(key: _onboardingCompleteKey, value: 'true');
  }

  Future<void> resetOnboarding() async {
    await _secureStorage.delete(key: _onboardingCompleteKey);
  }

  Future<bool> shouldShowHiddenFiles() async {
    final value = await _secureStorage.read(key: _showHiddenFilesKey);
    return value == 'true';
  }

  Future<void> setShowHiddenFiles(bool value) async {
    await _secureStorage.write(key: _showHiddenFilesKey, value: value.toString());
  }

  Future<String> getFileSortMode() async {
    return await _secureStorage.read(key: _fileSortModeKey) ?? 'name';
  }

  Future<void> setFileSortMode(String mode) async {
    await _secureStorage.write(key: _fileSortModeKey, value: mode);
  }
}
