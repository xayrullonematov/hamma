import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/ai/command_risk_assessor.dart';
import '../../../core/theme/app_colors.dart';

class InteractiveCommandBlock extends StatefulWidget {
  const InteractiveCommandBlock({
    super.key,
    required this.analysis,
    required this.onRunCommand,
    required this.onExplainCommand,
  });

  final CommandAnalysis analysis;
  final Future<void> Function(String command) onRunCommand;
  final Future<void> Function(String command) onExplainCommand;

  @override
  State<InteractiveCommandBlock> createState() => _InteractiveCommandBlockState();
}

class _InteractiveCommandBlockState extends State<InteractiveCommandBlock> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.analysis.command);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isDangerous =>
      widget.analysis.riskLevel == CommandRiskLevel.high ||
      widget.analysis.riskLevel == CommandRiskLevel.critical;

  bool get _isModerate =>
      widget.analysis.riskLevel == CommandRiskLevel.moderate;

  /// Brutalist risk palette: white for safe, harsh red for any warning.
  Color _riskAccent() {
    if (_isDangerous || _isModerate) {
      return AppColors.danger;
    }
    return AppColors.textPrimary;
  }

  IconData _getRiskIcon() {
    switch (widget.analysis.riskLevel) {
      case CommandRiskLevel.low:
        return Icons.check_box_outline_blank;
      case CommandRiskLevel.moderate:
        return Icons.warning_amber_rounded;
      case CommandRiskLevel.high:
      case CommandRiskLevel.critical:
        return Icons.gpp_maybe_rounded;
    }
  }

  String _riskLabel() {
    switch (widget.analysis.riskLevel) {
      case CommandRiskLevel.low:
        return 'SAFE';
      case CommandRiskLevel.moderate:
        return 'CAUTION';
      case CommandRiskLevel.high:
        return 'HIGH RISK';
      case CommandRiskLevel.critical:
        return 'CRITICAL';
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _riskAccent();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: accent, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Risk header strip — solid red bar for dangerous commands.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _isDangerous ? AppColors.danger : AppColors.panel,
              border: Border(
                bottom: BorderSide(color: accent, width: 1),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _getRiskIcon(),
                  color: _isDangerous ? AppColors.onPrimary : accent,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(
                  _riskLabel(),
                  style: TextStyle(
                    color: _isDangerous ? AppColors.onPrimary : accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 2.0,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
                const SizedBox(width: 14),
                Container(width: 1, height: 14, color: _isDangerous ? AppColors.onPrimary : AppColors.border),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.analysis.explanation,
                    style: TextStyle(
                      color: _isDangerous
                          ? AppColors.onPrimary
                          : AppColors.textPrimary,
                      fontSize: 12,
                      height: 1.4,
                      fontFamily: AppColors.sansFamily,
                      fontFamilyFallback: AppColors.sansFallback,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Command Editor — strict monospace terminal block.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '\$',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    style: const TextStyle(
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                      fontSize: 14,
                      color: AppColors.textPrimary,
                      height: 1.5,
                    ),
                    decoration: const InputDecoration(
                      filled: false,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Action Row
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => widget.onExplainCommand(_controller.text),
                  icon: const Icon(Icons.info_outline, size: 16),
                  label: const Text('EXPLAIN'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textMuted,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    textStyle: const TextStyle(
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                      fontSize: 11,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _controller.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('COPIED TO CLIPBOARD'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  color: AppColors.textMuted,
                  tooltip: 'Copy',
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => widget.onRunCommand(_controller.text),
                  icon: Icon(
                    _isDangerous
                        ? Icons.warning_rounded
                        : Icons.terminal_rounded,
                    size: 16,
                  ),
                  label: Text(_isDangerous ? 'EXECUTE' : 'RUN'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isDangerous ? AppColors.danger : AppColors.primary,
                    foregroundColor: _isDangerous
                        ? AppColors.textPrimary
                        : AppColors.onPrimary,
                    elevation: 0,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    textStyle: const TextStyle(
                      fontFamily: AppColors.monoFamily,
                      fontFamilyFallback: AppColors.monoFallback,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
