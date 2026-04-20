import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppPrefsStorage {
  const AppPrefsStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _onboardingCompleteKey = 'onboarding_complete';

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
}
