import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists whether the user has acknowledged the voice-mode privacy
/// disclosure. Stored in secure storage to keep parity with other
/// consent flags (app lock, biometrics).
class VoiceDisclosureStorage {
  const VoiceDisclosureStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'hamma.voice.disclosure_accepted_v1';

  final FlutterSecureStorage _storage;

  Future<bool> hasAccepted() async {
    final v = await _storage.read(key: _key);
    return v == '1';
  }

  Future<void> markAccepted() => _storage.write(key: _key, value: '1');

  Future<void> reset() => _storage.delete(key: _key);
}
