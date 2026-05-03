import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Thin wrapper over `flutter_tts` configured for on-device synthesis.
///
/// On iOS the system uses `AVSpeechSynthesizer`, which is on-device by
/// default. On Android we set the audio context appropriately and let
/// the user's installed TTS engine handle synthesis (Google Speech
/// Services ships an offline pack on most devices).
///
/// The reply text is lightly stripped of markdown noise before being
/// spoken so users don't hear "asterisk asterisk" for **bold** runs.
class VoiceSpeaker {
  VoiceSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _initialized = false;
  Completer<void>? _activeUtterance;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {
      // Plugin throws on unsupported desktop platforms; the rest of
      // the app keeps working with TTS disabled.
    }
    _initialized = true;
  }

  /// Strips markdown formatting and code fences so the synthesizer
  /// reads the assistant's reply naturally.
  static String sanitize(String input) {
    var text = input;
    // Drop fenced code blocks entirely — reading raw shell aloud is
    // worse than silence.
    text = text.replaceAll(
      RegExp(r'```[\s\S]*?```', multiLine: true),
      ' (code block) ',
    );
    text = text.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1)!);
    text = text.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => m.group(1)!,
    );
    text = text.replaceAllMapped(
      RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'),
      (m) => m.group(1)!,
    );
    text = text.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  Future<void> speak(String text) async {
    final clean = sanitize(text);
    if (clean.isEmpty) return;
    await initialize();
    await stop();
    final completer = Completer<void>();
    _activeUtterance = completer;
    try {
      await _tts.speak(clean);
    } catch (_) {
      // ignore — TTS unavailable on host platform
    } finally {
      if (!completer.isCompleted) completer.complete();
      if (identical(_activeUtterance, completer)) _activeUtterance = null;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    final pending = _activeUtterance;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _activeUtterance = null;
  }
}
