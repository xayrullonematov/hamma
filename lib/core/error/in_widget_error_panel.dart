import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'error_scrubber.dart';

/// Brutalist replacement for Flutter's default red-on-yellow error
/// widget. Rendered in place of any single widget that throws during
/// build/layout/paint.
///
/// Visible aesthetic:
///  - Pure-black background, white-on-red `RENDER ERROR` header
///  - Monospace body in the existing brutalist palette
///  - Compact (does not assume a full-screen viewport — e.g., it may
///    render inside a list cell or a small card)
///  - Debug builds show file/line and stack frames; release builds show
///    only the scrubbed exception message.
class InWidgetErrorPanel extends StatelessWidget {
  const InWidgetErrorPanel({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final scrubbed = ErrorScrubber.scrub(details.exceptionAsString());

    // Use a low-level Container + Text to avoid depending on the app's
    // theme — that theme might itself be the source of the error.
    return Container(
      padding: const EdgeInsets.all(8),
      color: AppColors.scaffoldBackground,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: AppColors.danger,
            child: const Text(
              'RENDER ERROR',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontFamily: AppColors.monoFamily,
                fontWeight: FontWeight.w700,
                fontSize: 10,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              scrubbed.isEmpty ? 'Widget failed to render.' : scrubbed,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
                height: 1.3,
              ),
              maxLines: kDebugMode ? 12 : 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (kDebugMode && details.context != null) ...[
            const SizedBox(height: 4),
            Text(
              details.context.toString(),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontFamily: AppColors.monoFamily,
                fontSize: 10,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
