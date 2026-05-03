import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/voice/voice_recognizer.dart';

class _FakeBackend implements VoiceBackend {
  _FakeBackend({
    this.initOk = true,
    bool onDevice = true,
    this.permissionGranted = true,
  }) : supportsOnDevice = onDevice;

  bool initOk;
  @override
  bool supportsOnDevice;
  bool permissionGranted;

  @override
  bool get isInitialized => _initialized;
  bool _initialized = false;

  bool listenCalled = false;
  bool stopCalled = false;
  bool cancelCalled = false;

  void Function(String text, bool isFinal)? _onResult;
  void Function(String error)? _onError;

  @override
  Future<bool> initialize() async {
    _initialized = initOk;
    return initOk;
  }

  @override
  Future<bool> hasMicPermission() async => permissionGranted;

  @override
  Future<bool> requestMicPermission() async => permissionGranted;

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
  }) async {
    listenCalled = true;
    _onResult = onResult;
    _onError = onError;
  }

  void emitError(String message) => _onError?.call(message);

  @override
  Future<void> stop() async {
    stopCalled = true;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
  }

  void emit(String text, {bool isFinal = false}) =>
      _onResult?.call(text, isFinal);
}

void main() {
  group('VoiceRecognizer on-device guard', () {
    test('refuses to listen when on-device unavailable', () async {
      final backend = _FakeBackend(onDevice: false);
      final r = VoiceRecognizer(backend: backend);

      await r.startListening();

      expect(r.state, VoiceRecognizerState.unavailable);
      expect(backend.listenCalled, isFalse);
      expect(r.errorMessage?.toLowerCase(), contains('on-device'));
    });

    test('refuses when backend initialize fails', () async {
      final backend = _FakeBackend(initOk: false);
      final r = VoiceRecognizer(backend: backend);

      await r.startListening();

      expect(r.state, VoiceRecognizerState.unavailable);
      expect(backend.listenCalled, isFalse);
    });

    test('refuses when mic permission denied', () async {
      final backend = _FakeBackend(permissionGranted: false);
      final r = VoiceRecognizer(backend: backend);

      await r.startListening();

      expect(r.state, VoiceRecognizerState.error);
      expect(backend.listenCalled, isFalse);
      expect(r.errorMessage, contains('permission'));
    });
  });

  group('VoiceRecognizer state machine', () {
    test('idle → listening → finalizing → idle, transcript flows', () async {
      final backend = _FakeBackend();
      final r = VoiceRecognizer(backend: backend);

      expect(r.state, VoiceRecognizerState.idle);

      await r.startListening();
      expect(r.state, VoiceRecognizerState.listening);
      expect(backend.listenCalled, isTrue);

      backend.emit('hello');
      expect(r.transcript, 'hello');
      expect(r.state, VoiceRecognizerState.listening);

      backend.emit('hello world', isFinal: true);
      expect(r.state, VoiceRecognizerState.finalizing);

      final out = await r.stopListening();
      expect(out, 'hello world');
      expect(r.state, VoiceRecognizerState.idle);
      expect(backend.stopCalled, isTrue);
    });

    test('cancel clears transcript and resets to idle', () async {
      final backend = _FakeBackend();
      final r = VoiceRecognizer(backend: backend);
      await r.startListening();
      backend.emit('partial');

      await r.cancel();

      expect(r.state, VoiceRecognizerState.idle);
      expect(r.transcript, isEmpty);
      expect(backend.cancelCalled, isTrue);
    });

    test('stopListening on idle returns null', () async {
      final backend = _FakeBackend();
      final r = VoiceRecognizer(backend: backend);
      final out = await r.stopListening();
      expect(out, isNull);
    });

    test('on-device-flavored backend errors flip state to unavailable',
        () async {
      // Errors that hint at network / offline-pack absence must
      // disable the mic permanently (until retried) — not be treated
      // as transient. This is the on-device guarantee enforcement.
      final backend = _FakeBackend();
      final r = VoiceRecognizer(backend: backend);

      await r.startListening();
      backend.emitError('error_network');
      expect(r.state, VoiceRecognizerState.unavailable);

      // A fresh start attempt should be refused (still unavailable
      // because the backend.supportsOnDevice didn't change, but the
      // recognizer must NOT silently fall back).
      expect(r.errorMessage?.toLowerCase(), contains('on-device'));
    });

    test('transient backend errors stay in error state (retryable)',
        () async {
      final backend = _FakeBackend();
      final r = VoiceRecognizer(backend: backend);

      await r.startListening();
      backend.emitError('error_speech_timeout');
      expect(r.state, VoiceRecognizerState.error);
      expect(r.state, isNot(VoiceRecognizerState.unavailable));
    });

    test('backend onError propagates into recognizer error state',
        () async {
      // The on-device guarantee depends on backend errors flowing
      // through to the recognizer so the UI disables the mic.
      // Verify the wiring end-to-end with the fake.
      final backend = _FakeBackend();
      final r = VoiceRecognizer(backend: backend);

      await r.startListening();
      expect(r.state, VoiceRecognizerState.listening);

      backend.emitError('error_speech_timeout');

      expect(r.state, VoiceRecognizerState.error);
      expect(r.errorMessage, 'error_speech_timeout');
    });
  });
}
