import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/voice/voice_disclosure_storage.dart';
import '../../../core/voice/voice_recognizer.dart';

/// Hold-to-talk microphone button used in the AI Assistant input row.
///
/// Behaviour:
///   * First tap shows the voice disclosure (on-device guarantee +
///     mic permission). The user must accept once per install.
///   * Long-press starts the recognizer; release stops it and
///     forwards the final transcript to [onTranscript].
///   * If on-device recognition is unavailable the button is
///     disabled with an explanatory tooltip — never silently routes
///     audio through a cloud service.
class VoiceInputButton extends StatefulWidget {
  const VoiceInputButton({
    super.key,
    required this.recognizer,
    required this.onTranscript,
    required this.onListeningChanged,
    this.disclosureStorage = const VoiceDisclosureStorage(),
  });

  final VoiceRecognizer recognizer;
  final ValueChanged<String> onTranscript;
  final ValueChanged<bool> onListeningChanged;
  final VoiceDisclosureStorage disclosureStorage;

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton> {
  // Pointer-down/up race guards: synchronous flips in the pointer
  // handlers let the async start chain detect a release that arrives
  // before listen() resolves, so the mic is never left hot.
  bool _pressActive = false;
  int _pressId = 0;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    widget.recognizer.addListener(_onRecognizerChanged);
  }

  @override
  void dispose() {
    widget.recognizer.removeListener(_onRecognizerChanged);
    super.dispose();
  }

  void _onRecognizerChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onListeningChanged(widget.recognizer.isListening);
  }

  Future<bool> _ensureDisclosure() async {
    if (await widget.disclosureStorage.hasAccepted()) return true;
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: const Text(
          'Voice mode — on-device only',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const SingleChildScrollView(
          child: Text(
            'Hamma transcribes your voice using your phone\'s built-in '
            'speech recognizer and asks the OS to keep it on-device.\n\n'
            '• iOS: Apple\'s SFSpeechRecognizer with '
            '`requiresOnDeviceRecognition` set — iOS hard-fails if the '
            'locale isn\'t installed on-device, so audio cannot be sent '
            'to Apple\'s servers.\n'
            '• Android: the system SpeechRecognizer with the offline '
            'preference flag. This is a strong preference but not an '
            'absolute hardware contract on every OEM — install your '
            'offline language pack in Settings → System → Languages & '
            'input → On-device speech recognition to be sure.\n\n'
            'If on-device recognition reports unavailable, the mic '
            'stays disabled — Hamma refuses to silently fall back to a '
            'cloud service.\n\n'
            'You\'ll be asked for microphone (and on iOS, speech-'
            'recognition) permission on first use.',
            style: TextStyle(color: AppColors.textPrimary, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.scaffoldBackground,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Enable voice'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await widget.disclosureStorage.markAccepted();
      return true;
    }
    return false;
  }

  Future<void> _start(int id) async {
    if (mounted) setState(() => _holding = true);

    final ok = await _ensureDisclosure();
    if (!_isStillThisPress(id)) {
      _resetHolding();
      return;
    }
    if (!ok) {
      _resetHolding();
      return;
    }

    await widget.recognizer.startListening();
    if (!_isStillThisPress(id)) {
      await widget.recognizer.cancel();
      _resetHolding();
      return;
    }

    if (widget.recognizer.state == VoiceRecognizerState.unavailable ||
        widget.recognizer.state == VoiceRecognizerState.error) {
      _resetHolding();
      _showErrorSnack(widget.recognizer.errorMessage ?? 'Voice unavailable');
    }
  }

  Future<void> _finish({bool cancel = false}) async {
    final wasHolding = _holding;
    _resetHolding();

    if (cancel) {
      await widget.recognizer.cancel();
      return;
    }

    if (!wasHolding) {
      if (widget.recognizer.isListening) {
        await widget.recognizer.cancel();
      }
      return;
    }
    final transcript = await widget.recognizer.stopListening();
    if (transcript != null && transcript.isNotEmpty) {
      widget.onTranscript(transcript);
    }
  }

  bool _isStillThisPress(int id) => mounted && _pressActive && _pressId == id;

  void _resetHolding() {
    if (mounted && _holding) setState(() => _holding = false);
  }

  void _showErrorSnack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.recognizer.state;
    final isUnavailable = state == VoiceRecognizerState.unavailable;
    final isActive = _holding || widget.recognizer.isListening;
    final tooltip = isUnavailable
        ? (widget.recognizer.errorMessage ?? 'On-device voice unavailable')
        : (isActive ? 'Release to send' : 'Hold to talk');

    return Tooltip(
      message: tooltip,
      child: Listener(
        onPointerDown: isUnavailable
            ? null
            : (_) {
                _pressActive = true;
                final id = ++_pressId;
                unawaited(_start(id));
              },
        onPointerUp: (_) {
          _pressActive = false;
          unawaited(_finish());
        },
        onPointerCancel: (_) {
          _pressActive = false;
          unawaited(_finish(cancel: true));
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isUnavailable
                ? AppColors.surface
                : (isActive ? AppColors.danger : AppColors.surface),
            border: Border.all(
              color: isUnavailable ? AppColors.border : AppColors.primary,
              width: 1,
            ),
          ),
          child: Icon(
            isActive ? Icons.mic : Icons.mic_none,
            color: isUnavailable
                ? AppColors.textMuted
                : (isActive ? Colors.white : AppColors.primary),
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// Tiny status pill rendered next to the local-engine pill while a
/// voice session is in progress. Communicates the on-device guarantee
/// at the moment audio is actually being captured or replayed.
class OnDeviceVoiceChip extends StatelessWidget {
  const OnDeviceVoiceChip({super.key, required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.primary, width: 1),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic, size: 12, color: AppColors.primary),
            SizedBox(width: 6),
            Text(
              'ON-DEVICE',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
