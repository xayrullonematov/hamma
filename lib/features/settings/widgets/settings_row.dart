import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// A Termius-style settings row used inside [SettingsRowGroup].
///
/// Layout: colored icon tile, primary label, optional secondary value
/// subtitle, and a trailing slot (typically a [Switch], a chevron, or
/// any small widget). Brutalist: 1px borders, sharp corners.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    this.iconColor = AppColors.accent,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.searchKeywords = '',
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  /// Lowercased free-text used for row-granular search matching.
  final String searchKeywords;

  /// Convenience factory that renders a trailing chevron.
  factory SettingsRow.chevron({
    Key? key,
    required IconData icon,
    Color iconColor = AppColors.accent,
    required String label,
    String? value,
    VoidCallback? onTap,
    bool enabled = true,
    String searchKeywords = '',
  }) {
    return SettingsRow(
      key: key,
      icon: icon,
      iconColor: iconColor,
      label: label,
      value: value,
      enabled: enabled,
      onTap: onTap,
      searchKeywords: searchKeywords,
      trailing: const Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: AppColors.textMuted,
      ),
    );
  }

  /// Convenience factory that renders a trailing [Switch].
  factory SettingsRow.toggle({
    Key? key,
    required IconData icon,
    Color iconColor = AppColors.accent,
    required String label,
    String? value,
    required bool toggleValue,
    required ValueChanged<bool>? onToggle,
    bool enabled = true,
    String searchKeywords = '',
  }) {
    return SettingsRow(
      key: key,
      icon: icon,
      iconColor: iconColor,
      label: label,
      value: value,
      enabled: enabled,
      onTap: enabled && onToggle != null ? () => onToggle(!toggleValue) : null,
      searchKeywords: searchKeywords,
      trailing: Switch(
        value: toggleValue,
        onChanged: enabled ? onToggle : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabledColor = AppColors.textFaint;
    final labelColor = enabled ? AppColors.textPrimary : disabledColor;
    final valueColor = enabled ? AppColors.textMuted : disabledColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.18),
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.55),
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 16, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: labelColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (value != null && value!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        value!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: valueColor,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled group of [SettingsRow]s separated by 1px dividers, with an
/// uppercase mono header above and a 1px outer border. Pass any widget
/// as a child if you need to embed a non-row editor (slider, dropdown,
/// text field) inside the group while keeping the framing consistent.
class SettingsRowGroup extends StatelessWidget {
  const SettingsRowGroup({
    super.key,
    required this.header,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final String header;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final visible = children.where((c) => c is! _SettingsRowHidden).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final separated = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      if (i > 0) {
        separated.add(const Divider(
          height: 1,
          thickness: 1,
          color: AppColors.border,
        ));
      }
      separated.add(visible[i]);
    }

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
            child: Text(
              header.toUpperCase(),
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
                letterSpacing: 1.6,
                fontWeight: FontWeight.bold,
                color: AppColors.textMuted,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.panel,
              border: Border.all(color: AppColors.border, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: separated,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sentinel widget callers can use to hide a row conditionally without
/// inserting a dangling divider. Use [SettingsRowGroup.hidden].
class _SettingsRowHidden extends StatelessWidget {
  const _SettingsRowHidden();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

extension SettingsRowGroupHidden on SettingsRowGroup {
  static const Widget hidden = _SettingsRowHidden();
}
