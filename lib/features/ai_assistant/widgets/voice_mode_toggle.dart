import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/voice/voice_session.dart';

/// Cycles the AI Assistant between off → push-to-talk → conversational.
/// Lives in the app bar so the user can flip into hands-free mode
/// without diving into settings.
class VoiceModeToggle extends StatelessWidget {
  const VoiceModeToggle({
    super.key,
    required this.session,
    required this.onChanged,
  });

  final VoiceSession session;
  final ValueChanged<VoiceMode> onChanged;

  static const _order = [
    VoiceMode.off,
    VoiceMode.pushToTalk,
    VoiceMode.conversational,
  ];

  IconData _iconFor(VoiceMode mode) {
    switch (mode) {
      case VoiceMode.off:
        return Icons.mic_off_outlined;
      case VoiceMode.pushToTalk:
        return Icons.mic_none_outlined;
      case VoiceMode.conversational:
        return Icons.record_voice_over_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final mode = session.mode;
        return Tooltip(
          message: '${mode.label} (tap to change)',
          child: TextButton.icon(
            onPressed: () {
              final next = _order[(_order.indexOf(mode) + 1) % _order.length];
              onChanged(next);
            },
            icon: Icon(
              _iconFor(mode),
              size: 16,
              color: mode == VoiceMode.off
                  ? AppColors.textMuted
                  : AppColors.primary,
            ),
            label: Text(
              mode.label,
              style: TextStyle(
                color: mode == VoiceMode.off
                    ? AppColors.textMuted
                    : AppColors.primary,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
                side: BorderSide(color: AppColors.border),
              ),
            ),
          ),
        );
      },
    );
  }
}
