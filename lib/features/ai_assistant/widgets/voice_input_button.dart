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
  // True only between pointer-down and pointer-up. Used to detect the
  // race where the user releases the mic *before* the async start
  // chain (disclosure → permission → backend.initialize → listen) has
  // finished — without this guard the recognizer would begin
  // listening after release, leaving the microphone hot.
  bool _pressActive = false;
  // Monotonic id incremented on every pointer-down. _start() captures
  // its id and bails out if a newer press has begun (or the same
  // press has ended) before the async chain completes.
  int _pressId = 0;
  // Reflects whether the user is currently pressing the button (for
  // the visual state). Distinct from `recognizer.isListening` so the
  // button can show the held-down style during the brief window
  // between pointer-down and the recognizer actually entering the
  // listening state.
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
            'Hamma transcribes your voice using your phone\'s on-device '
            'speech recognizer. Audio never leaves this device.\n\n'
            '• iOS uses Apple\'s on-device SFSpeechRecognizer.\n'
            '• Android uses the system SpeechRecognizer with the offline '
            'preference flag.\n\n'
            'If on-device recognition isn\'t available, the mic stays '
            'disabled — Hamma refuses to fall back to a cloud service.\n\n'
            'You\'ll be asked for microphone (and on iOS, speech-recognition) '
            'permission on first use.',
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
    // Visual feedback: show the held-down style immediately so the
    // user sees the press registered even while disclosure /
    // permission / initialize is still running.
    if (mounted) setState(() => _holding = true);

    final ok = await _ensureDisclosure();
    if (!_isStillThisPress(id)) {
      // User released (or started a new press) during the disclosure
      // dialog. Never start the backend.
      _resetHolding();
      return;
    }
    if (!ok) {
      _resetHolding();
      return;
    }

    await widget.recognizer.startListening();
    if (!_isStillThisPress(id)) {
      // The async start chain crossed the pointer-up boundary. The
      // recognizer may now be listening — cancel it immediately so
      // the microphone never stays hot after release.
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
    // _pressActive is flipped by the pointer handlers *before* this
    // is called, so any concurrent _start() will see the press is no
    // longer active and bail before invoking listen.
    final wasHolding = _holding;
    _resetHolding();

    if (cancel) {
      // Always attempt cancel — covers the case where the recognizer
      // started listening just before / during finish.
      await widget.recognizer.cancel();
      return;
    }

    // Only forward a transcript if we ever actually held the button
    // (avoids forwarding empty transcripts for a no-op tap).
    if (!wasHolding) {
      // Defensive: still ask the recognizer to stop in case _start
      // raced past the guard.
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
        // Pointer handlers flip _pressActive / _pressId synchronously
        // so the async _start chain can detect a release that arrives
        // before listen() completes.
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
