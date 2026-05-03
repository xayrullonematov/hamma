import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'voice_session.dart';

/// Persists the [VoiceMode] selection per server so on-call engineers
/// who turn on conversational mode for a critical server keep it on
/// across app restarts. Stored alongside the other voice consent
/// flags in secure storage.
class VoiceModeStorage {
  const VoiceModeStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'hamma.voice.mode_v1.';

  final FlutterSecureStorage _storage;

  String _key(String serverId) => '$_prefix$serverId';

  Future<VoiceMode> load(String serverId) async {
    final raw = await _storage.read(key: _key(serverId));
    switch (raw) {
      case 'pushToTalk':
        return VoiceMode.pushToTalk;
      case 'conversational':
        return VoiceMode.conversational;
      case 'off':
      default:
        return VoiceMode.off;
    }
  }

  Future<void> save(String serverId, VoiceMode mode) {
    return _storage.write(key: _key(serverId), value: mode.name);
  }
}
