import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/keymap/keymap.dart';
import '../../core/theme/app_colors.dart';

/// Modal that lists every keyboard shortcut active in the current
/// scope. Wired to the `?` global binding via `Shortcuts`/`Actions` at
/// the app root, so pressing `?` anywhere outside a text field opens
/// it.
///
/// Visuals match the command palette: zero-radius, dark surface,
/// black scrim. Reusing the palette's scaffold keeps the
/// "system-overlay" feel consistent — both modals are app-wide tools
/// the user pops over whatever screen they're on.
class ShortcutCheatsheet extends StatelessWidget {
  const ShortcutCheatsheet({
    super.key,
    this.scope = KeymapScope.global,
    @visibleForTesting this.platformOverride,
  });

  /// Scope to filter entries by. Global entries are always shown on
  /// top of the scoped ones.
  final KeymapScope scope;

  /// Test seam — pins the platform used to render chord glyphs so
  /// widget tests can assert against deterministic strings instead of
  /// the host platform.
  final TargetPlatform? platformOverride;

  /// Convenience helper to open the cheatsheet from anywhere with
  /// access to a [BuildContext]. Used by the root `?` binding.
  static Future<void> show(
    BuildContext context, {
    KeymapScope scope = KeymapScope.global,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => ShortcutCheatsheet(scope: scope),
    );
  }

  @override
  Widget build(BuildContext context) {
    final platform = platformOverride ?? defaultTargetPlatform;
    final entries = Keymap.forScope(scope);
    final grouped = Keymap.grouped(entries);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Center(
        child: Container(
          width: 600,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: AppColors.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Header(),
              const Divider(color: AppColors.border, height: 1),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 120,
                  maxHeight: 480,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final group in grouped.entries) ...[
                        _GroupHeader(label: group.key),
                        const SizedBox(height: 8),
                        for (final entry in group.value)
                          _ShortcutRow(entry: entry, platform: platform),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(color: AppColors.border, height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Close',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            Icons.keyboard_alt_outlined,
            color: AppColors.textPrimary,
            size: 20,
          ),
          SizedBox(width: 10),
          Text(
            'Keyboard shortcuts',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: AppColors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.entry, required this.platform});

  final KeymapEntry entry;
  final TargetPlatform platform;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          const SizedBox(width: 16),
          _ChordBadge(text: entry.chord.displayFor(platform)),
        ],
      ),
    );
  }
}

class _ChordBadge extends StatelessWidget {
  const _ChordBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontFamily: AppColors.monoFamily,
          fontFamilyFallback: AppColors.monoFallback,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
