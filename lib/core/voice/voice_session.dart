import 'package:flutter/foundation.dart';

/// Voice mode for the AI Assistant on a single server.
///
/// * [off] — typed input only.
/// * [pushToTalk] — mic button visible; user holds to talk, replies
///   are shown but not spoken.
/// * [conversational] — mic + TTS; assistant replies are spoken aloud.
enum VoiceMode { off, pushToTalk, conversational }

extension VoiceModeLabel on VoiceMode {
  String get label {
    switch (this) {
      case VoiceMode.off:
        return 'Voice off';
      case VoiceMode.pushToTalk:
        return 'Push to talk';
      case VoiceMode.conversational:
        return 'Conversational';
    }
  }
}

/// Per-screen controller for voice state. Tracks the active mode and
/// whether the mic / speaker is currently producing audio so the
/// "🎤 ON-DEVICE" chip can light up.
class VoiceSession extends ChangeNotifier {
  VoiceSession({VoiceMode initialMode = VoiceMode.off}) : _mode = initialMode;

  VoiceMode _mode;
  bool _audioActive = false;

  VoiceMode get mode => _mode;
  bool get audioActive => _audioActive;
  bool get isConversational => _mode == VoiceMode.conversational;
  bool get isVoiceEnabled => _mode != VoiceMode.off;

  void setMode(VoiceMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }

  void setAudioActive(bool active) {
    if (_audioActive == active) return;
    _audioActive = active;
    notifyListeners();
  }
}
