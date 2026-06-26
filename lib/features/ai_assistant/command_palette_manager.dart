import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/ai/ai_command_service.dart';
import '../../core/palette/palette_index.dart';
import 'global_command_palette.dart';

/// Owns the system-level Cmd-K / Ctrl-K hotkey and shows the
/// [GlobalCommandPalette] when it fires. Wraps the entire app so the
/// hotkey is registered for the lifetime of the process.
class CommandPaletteManager extends StatefulWidget {
  const CommandPaletteManager({
    super.key,
    required this.child,
    required this.navigatorKey,
    required this.aiCommandService,
    required this.availableServers,
    required this.onExecute,
    this.paletteIndex,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  final AiCommandService aiCommandService;
  final List<String> availableServers;
  final void Function(CommandIntent intent) onExecute;

  /// Optional multi-source index. When null, the palette falls back
  /// to AI-NLP only, preserving first-launch behaviour before sources
  /// are wired.
  final PaletteIndex? paletteIndex;

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
          _showPalette();
        }
      },
    );
  }

  @override
  void dispose() {
    hotKeyManager.unregister(_hotKey);
    super.dispose();
  }

  void _showPalette() {
    final context = widget.navigatorKey.currentContext;
    if (context == null) return;

    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder:
          (context) => GlobalCommandPalette(
            aiCommandService: widget.aiCommandService,
            availableServers: widget.availableServers,
            onExecute: widget.onExecute,
            paletteIndex: widget.paletteIndex,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
