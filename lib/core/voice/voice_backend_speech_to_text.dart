import 'dart:io' show Platform;

import 'package:speech_to_text/speech_to_text.dart';

import 'voice_recognizer.dart';

/// Production [VoiceBackend] backed by the `speech_to_text` plugin.
///
/// Configures the underlying recognizer for on-device-only operation:
///   * iOS: `SFSpeechRecognizer.requiresOnDeviceRecognition = true`
///     via `SpeechListenOptions(onDevice: true)`. iOS surfaces a hard
///     error if the locale isn't installed on-device — that error
///     bubbles into the recognizer's error state and the UI disables
///     the mic. No cloud fallback ever runs.
///   * Android: routes through `SpeechRecognizer` with
///     `EXTRA_PREFER_OFFLINE = true`. **Known limitation:** Android's
///     flag is a *preference*, not an absolute hardware contract.
///     Some OEM recognizers still fall back to a cloud service if the
///     offline language pack isn't installed. We surface every plugin
///     error verbatim and document the limitation in
///     `docs/voice-mode.md` so the user can verify their offline pack
///     is installed before relying on the on-device guarantee.
///
/// All plugin errors are propagated to [VoiceRecognizer] via the
/// `onError` callback supplied to [listen]; nothing is swallowed.
class SpeechToTextBackend implements VoiceBackend {
  SpeechToTextBackend({SpeechToText? client}) : _stt = client ?? SpeechToText();

  final SpeechToText _stt;
  bool _initialized = false;
  bool _onDevice = false;
  // Active session callbacks. The plugin emits errors via the
  // statusListener installed at initialize() time — not via a
  // per-listen callback — so we hold a reference to the recognizer's
  // current error sink for the duration of the listen window.
  void Function(String error)? _activeOnError;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get supportsOnDevice => _onDevice;

  @override
  Future<bool> initialize() async {
    final ok = await _stt.initialize(
      // Forward every plugin-side error to whoever is currently
      // listening. This is the *only* path through which on-device
      // failure surfaces — swallowing it would mean the UI keeps the
      // mic enabled while the platform silently bails or worse.
      onError: (notification) {
        final sink = _activeOnError;
        if (sink != null) sink(notification.errorMsg);
      },
      onStatus: (_) {},
    );
    _initialized = ok;
    if (ok) {
      // speech_to_text v7 doesn't expose a direct "is on-device
      // supported" probe. We're conservative on a per-platform basis:
      //   * iOS / Android: claim support and let the per-listen
      //     `onDevice: true` flag enforce. Errors propagate via
      //     `_activeOnError` so the recognizer transitions to
      //     `error` and the UI disables the mic.
      //   * everything else (desktop builds that somehow load this
      //     backend, web): refuse outright.
      _onDevice = Platform.isIOS || Platform.isAndroid;
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
        listenOptions: SpeechListenOptions(
          onDevice: true,
          partialResults: true,
          cancelOnError: true,
        ),
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
