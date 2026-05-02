import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/ai/ai_command_service.dart';
import '../../core/theme/app_colors.dart';

class CommandPaletteManager extends StatefulWidget {
  const CommandPaletteManager({
    super.key,
    required this.child,
    required this.aiCommandService,
    required this.availableServers,
    required this.onExecute,
  });

  final Widget child;
  final AiCommandService aiCommandService;
  final List<String> availableServers;
  final void Function(CommandIntent intent) onExecute;

  @override
  State<CommandPaletteManager> createState() => _CommandPaletteManagerState();
}

class _CommandPaletteManagerState extends State<CommandPaletteManager> {
  final _hotKey = HotKey(
    key: PhysicalKeyboardKey.keyK,
    modifiers: [
      defaultTargetPlatform == TargetPlatform.macOS
          ? HotKeyModifier.meta
          : HotKeyModifier.control,
    ],
    scope: HotKeyScope.system,
  );

  @override
  void initState() {
    super.initState();
    _initHotKey();
  }

  Future<void> _initHotKey() async {
    await hotKeyManager.register(
      _hotKey,
      keyDownHandler: (hotKey) async {
        await windowManager.show();
        await windowManager.focus();
        if (mounted) {
          _showPalette(context);
        }
      },
    );
  }

  @override
  void dispose() {
    hotKeyManager.unregister(_hotKey);
    super.dispose();
  }

  void _showPalette(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => GlobalCommandPalette(
        aiCommandService: widget.aiCommandService,
        availableServers: widget.availableServers,
        onExecute: widget.onExecute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class GlobalCommandPalette extends StatefulWidget {
  const GlobalCommandPalette({
    super.key,
    required this.aiCommandService,
    required this.availableServers,
    required this.onExecute,
  });

  final AiCommandService aiCommandService;
  final List<String> availableServers;
  final void Function(CommandIntent intent) onExecute;

  @override
  State<GlobalCommandPalette> createState() => _GlobalCommandPaletteState();
}

class _GlobalCommandPaletteState extends State<GlobalCommandPalette> {
  final TextEditingController _controller = TextEditingController();
  bool _isParsing = false;
  CommandIntent? _intent;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSubmitted(String value) async {
    if (value.trim().isEmpty || _isParsing) return;

    setState(() {
      _isParsing = true;
      _intent = null;
      _error = null;
    });

    try {
      final intent = await widget.aiCommandService.parseIntent(
        value,
        widget.availableServers,
      );
      if (mounted) {
        setState(() {
          _intent = intent;
          _isParsing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isParsing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Center(
        child: Container(
          width: 600,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.zero,
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  decoration: const InputDecoration(
                    hintText: "What do you want to do? (e.g. Restart nginx on production-db)",
                    hintStyle: TextStyle(color: AppColors.textMuted),
                    border: InputBorder.none,
                  ),
                  onSubmitted: _handleSubmitted,
                ),
              ),
              const Divider(color: AppColors.border, height: 1),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120, maxHeight: 400),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: _buildContent(),
                ),
              ),
              if (_intent != null) ...[
                const Divider(color: AppColors.border, height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text("Cancel", style: TextStyle(color: AppColors.textMuted)),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: () {
                          widget.onExecute(_intent!);
                          Navigator.of(context).pop();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.textPrimary,
                          foregroundColor: AppColors.scaffoldBackground,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                        ),
                        child: const Text("Execute"),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isParsing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(color: AppColors.textPrimary, strokeWidth: 3),
            SizedBox(height: 20),
            Text(
              "Parsing intent...",
              style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.danger, fontSize: 14),
            ),
          ),
        ],
      );
    }

    if (_intent != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.zero,
                ),
                child: const Icon(Icons.bolt_rounded, color: AppColors.danger, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _intent!.action,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          if (_intent!.targetServer != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.textPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.zero,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.dns_rounded, color: AppColors.textPrimary, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    "Target: ${_intent!.targetServer}",
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.zero,
              border: Border.all(color: AppColors.border),
            ),
            width: double.infinity,
            child: SelectableText(
              _intent!.command,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _intent!.explanation,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.keyboard_command_key_rounded, color: Color(0xFF475569), size: 32),
          SizedBox(height: 12),
          Text(
            "Type your request and press Enter",
            style: TextStyle(color: AppColors.textMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
