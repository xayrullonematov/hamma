import 'dart:async';

import 'package:flutter/foundation.dart';

/// On-device-only speech-to-text state machine.
///
/// The recognizer never falls back to a cloud service. If on-device
/// recognition is unavailable on the host OS the state transitions to
/// [VoiceRecognizerState.unavailable] and listening is refused. This
/// is the central guarantee surfaced in the AI Assistant disclosure.
///
/// The class is intentionally backed by an injectable [VoiceBackend]
/// so unit tests can exercise the on-device guard without booting the
/// `speech_to_text` platform plugin.
enum VoiceRecognizerState {
  idle,
  listening,
  finalizing,
  error,
  unavailable,
}

/// Thin contract over the platform speech recognizer. Production
/// implementation lives in `voice_backend_speech_to_text.dart`; tests
/// supply a fake.
abstract class VoiceBackend {
  Future<bool> initialize();
  bool get isInitialized;

  /// Whether the host OS can perform speech recognition WITHOUT
  /// sending audio off-device. Implementations MUST return false if
  /// they cannot prove this — silent cloud fallback is forbidden.
  bool get supportsOnDevice;

  Future<bool> hasMicPermission();
  Future<bool> requestMicPermission();

  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
  });

  Future<void> stop();
  Future<void> cancel();
}

class VoiceRecognizer extends ChangeNotifier {
  VoiceRecognizer({required VoiceBackend backend}) : _backend = backend;

  final VoiceBackend _backend;
  VoiceRecognizerState _state = VoiceRecognizerState.idle;
  String _transcript = '';
  String? _errorMessage;

  VoiceRecognizerState get state => _state;
  String get transcript => _transcript;
  String? get errorMessage => _errorMessage;
  bool get isOnDeviceAvailable => _backend.supportsOnDevice;
  bool get isListening => _state == VoiceRecognizerState.listening;

  /// Confirms the backend is initialized, on-device recognition is
  /// available, and the mic permission is granted. Returns false and
  /// sets an explanatory [errorMessage] on any failure.
  Future<bool> ensureReady() async {
    if (!_backend.isInitialized) {
      final ok = await _backend.initialize();
      if (!ok) {
        _setState(
          VoiceRecognizerState.unavailable,
          error: 'Speech recognition is unavailable on this device.',
        );
        return false;
      }
    }
    if (!_backend.supportsOnDevice) {
      _setState(
        VoiceRecognizerState.unavailable,
        error:
            'On-device speech recognition is not available. Hamma will not '
            'send audio off-device, so the microphone is disabled.',
      );
      return false;
    }
    final has = await _backend.hasMicPermission();
    if (!has) {
      final granted = await _backend.requestMicPermission();
      if (!granted) {
        _setState(
          VoiceRecognizerState.error,
          error: 'Microphone permission denied.',
        );
        return false;
      }
    }
    return true;
  }

  Future<void> startListening() async {
    if (_state == VoiceRecognizerState.listening) return;
    final ready = await ensureReady();
    if (!ready) return;
    _transcript = '';
    _errorMessage = null;
    _setState(VoiceRecognizerState.listening);
    try {
      await _backend.listen(
        onResult: (text, isFinal) {
          _transcript = text;
          if (isFinal) {
            _setState(VoiceRecognizerState.finalizing);
          } else {
            notifyListeners();
          }
        },
        onError: (err) {
          // Classify the plugin error: anything that suggests the
          // platform fell back to (or required) network — or that
          // on-device support is structurally missing — flips the
          // recognizer to `unavailable`, which the UI uses to disable
          // the mic with the explanatory tooltip. Transient errors
          // (timeouts, no-match) stay as `error` so the user can
          // simply press the mic again.
          if (_isUnavailable(err)) {
            _setState(
              VoiceRecognizerState.unavailable,
              error:
                  'On-device speech recognition is not available '
                  '($err). Hamma will not send audio off-device, so '
                  'the microphone is disabled. Install your offline '
                  'language pack in system settings to enable voice.',
            );
          } else {
            _setState(VoiceRecognizerState.error, error: err);
          }
        },
      );
    } catch (e) {
      _setState(VoiceRecognizerState.error, error: e.toString());
    }
  }

  /// Stops listening and returns the final transcript (trimmed) or
  /// `null` if nothing was captured.
  Future<String?> stopListening() async {
    if (_state != VoiceRecognizerState.listening &&
        _state != VoiceRecognizerState.finalizing) {
      final t = _transcript.trim();
      return t.isEmpty ? null : t;
    }
    try {
      await _backend.stop();
    } catch (_) {
      // Best-effort: even if the backend errors on stop we still want
      // the buffered transcript to flow into the AI Assistant.
    }
    final out = _transcript.trim();
    _setState(VoiceRecognizerState.idle);
    return out.isEmpty ? null : out;
  }

  Future<void> cancel() async {
    try {
      await _backend.cancel();
    } catch (_) {}
    _transcript = '';
    _setState(VoiceRecognizerState.idle);
  }

  /// Heuristic over plugin error codes that distinguish "on-device
  /// recognition is not available on this device" from "speech wasn't
  /// captured this time". The match is intentionally loose because
  /// `speech_to_text` forwards platform-specific strings verbatim and
  /// they vary across OEMs and OS versions; we err on the side of
  /// disabling the mic when in doubt about the on-device guarantee.
  bool _isUnavailable(String err) {
    final e = err.toLowerCase();
    return e.contains('network') ||
        e.contains('server') ||
        e.contains('language_not_supported') ||
        e.contains('not supported') ||
        e.contains('on-device') ||
        e.contains('on_device') ||
        e.contains('offline') ||
        e.contains('unavailable');
  }

  void _setState(VoiceRecognizerState s, {String? error}) {
    _state = s;
    _errorMessage = error;
    notifyListeners();
  }
}
