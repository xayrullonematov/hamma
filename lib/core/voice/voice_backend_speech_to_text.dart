import 'dart:io' show Platform;

import 'package:speech_to_text/speech_to_text.dart';

import 'voice_recognizer.dart';

/// Production [VoiceBackend] backed by the `speech_to_text` plugin.
///
/// On-device guarantees per platform:
///   * iOS: passes `onDevice: true` to `listen()` which sets
///     `SFSpeechRecognizer.requiresOnDeviceRecognition`. iOS hard-fails
///     when the locale isn't installed on-device.
///   * Android: passes `EXTRA_PREFER_OFFLINE`. This is the OS-level
///     preference, not an absolute contract — see `docs/voice-mode.md`.
///
/// All plugin errors propagate to [VoiceRecognizer] via the `onError`
/// callback so the UI can flip to `unavailable` and disable the mic.
class SpeechToTextBackend implements VoiceBackend {
  SpeechToTextBackend({SpeechToText? client}) : _stt = client ?? SpeechToText();

  final SpeechToText _stt;
  bool _initialized = false;
  bool _onDevice = false;
  void Function(String error)? _activeOnError;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get supportsOnDevice => _onDevice;

  @override
  Future<bool> initialize() async {
    final ok = await _stt.initialize(
      onError: (notification) {
        _activeOnError?.call(notification.errorMsg);
      },
      onStatus: (_) {},
    );
    _initialized = ok;
    if (!ok) return false;

    // Refuse outside iOS / Android — desktop / web have no on-device
    // SFSpeechRecognizer / SpeechRecognizer with an offline mode.
    if (!(Platform.isIOS || Platform.isAndroid)) {
      _onDevice = false;
      return ok;
    }

    // Probe locales as a minimum-viability check: if the platform
    // reports zero recognizable locales the recognizer is structurally
    // unusable and we must not pretend on-device support exists.
    try {
      final locales = await _stt.locales();
      _onDevice = locales.isNotEmpty;
    } catch (_) {
      _onDevice = false;
    }
    return ok;
  }

  @override
  Future<bool> hasMicPermission() async => _stt.hasPermission;

  @override
  Future<bool> requestMicPermission() async {
    // The plugin requests mic + speech-recognition permission as part
    // of initialize(); re-running it triggers the OS prompt.
    final ok = await _stt.initialize();
    _initialized = ok;
    return ok && (await _stt.hasPermission);
  }

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
  }) async {
    _activeOnError = onError;
    try {
      await _stt.listen(
        onDevice: true,
        partialResults: true,
        cancelOnError: true,
        onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      );
    } catch (e) {
      _activeOnError?.call(e.toString());
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _stt.stop();
    } finally {
      _activeOnError = null;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _stt.cancel();
    } finally {
      _activeOnError = null;
    }
  }
}
