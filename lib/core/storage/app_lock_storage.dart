// ignore_for_file: deprecated_member_use

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppLockStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const AppLockStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _appPinStorageKey = 'app_lock_pin';

  final FlutterSecureStorage _secureStorage;

  Future<String?> readPin() async {
    final value = await _secureStorage.read(key: _appPinStorageKey);
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value;
  }

  Future<bool> hasPin() async {
    return (await readPin()) != null;
  }

  Future<void> savePin(String pin) async {
    final trimmedPin = pin.trim();
    if (trimmedPin.isEmpty) {
      await deletePin();
      return;
    }

    await _secureStorage.write(
      key: _appPinStorageKey,
      value: trimmedPin,
    );
  }

  Future<void> deletePin() async {
    await _secureStorage.delete(key: _appPinStorageKey);
  }
}
