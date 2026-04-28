import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/ai/command_risk_assessor.dart';

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

  Color _getRiskColor() {
    switch (widget.analysis.riskLevel) {
      case CommandRiskLevel.low:
        return Colors.green;
      case CommandRiskLevel.moderate:
        return Colors.orange;
      case CommandRiskLevel.high:
      case CommandRiskLevel.critical:
        return Colors.red;
    }
  }

  IconData _getRiskIcon() {
    switch (widget.analysis.riskLevel) {
      case CommandRiskLevel.low:
        return Icons.check_circle_outline;
      case CommandRiskLevel.moderate:
        return Icons.warning_amber_rounded;
      case CommandRiskLevel.high:
      case CommandRiskLevel.critical:
        return Icons.gpp_maybe_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final riskColor = _getRiskColor();
    final isDangerous = widget.analysis.riskLevel == CommandRiskLevel.high ||
        widget.analysis.riskLevel == CommandRiskLevel.critical;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B), // Slate-800
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: riskColor.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row
          Container(
            padding: const EdgeInsets.all(12.0),
            decoration: BoxDecoration(
              color: riskColor.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6.5)),
            ),
            child: Row(
              children: [
                Icon(_getRiskIcon(), color: riskColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  widget.analysis.riskLevel.name.toUpperCase(),
                  style: TextStyle(
                    color: riskColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.analysis.explanation,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Command Editor
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              controller: _controller,
              maxLines: null,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: Color(0xFFE2E8F0), // Slate-200
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),

          // Action Row
          Padding(
            padding: const EdgeInsets.fromLTRB(12.0, 0, 12.0, 12.0),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => widget.onExplainCommand(_controller.text),
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('Explain'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF94A3B8), // Slate-400
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _controller.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  color: const Color(0xFF94A3B8), // Slate-400
                  tooltip: 'Copy',
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => widget.onRunCommand(_controller.text),
                  icon: const Icon(Icons.terminal_rounded, size: 18),
                  label: const Text('Run in Terminal'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDangerous ? Colors.red : const Color(0xFF3B82F6), // Blue-500
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6.0),
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
