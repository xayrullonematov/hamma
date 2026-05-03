import 'package:flutter/material.dart';

import 'ai_copilot_sheet.dart';

/// Inherited entry point that lets descendant widgets (the terminal,
/// log viewer, etc.) ask the dashboard to *dock* the AI Copilot as a
/// right-hand pane instead of opening it as a modal bottom sheet.
///
/// Only the desktop dashboard (≥1100px) installs a [CopilotDock]. On
/// smaller widths callers find no dock and fall back to the existing
/// `showModalBottomSheet` behavior — so the same call site works on
/// every form factor.
///
/// The dock owns a single live copilot at a time. Re-opening with a
/// different request replaces the previous content; the underlying
/// [AiCopilotSheet] state is reset because [CopilotDockRequest.key]
/// changes per call.
class CopilotDock extends InheritedNotifier<CopilotDockController> {
  const CopilotDock({
    super.key,
    required CopilotDockController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Returns the dock when one is installed in the tree, or `null` on
  /// mobile/tablet where the modal sheet should be used instead.
  static CopilotDockController? maybeOf(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<CopilotDock>();
    return widget?.notifier;
  }
}

/// What to render inside the docked pane. The dashboard receives this
/// from [CopilotDockController] and is responsible for the chrome
/// (close button, panel borders, header).
class CopilotDockRequest {
  CopilotDockRequest({required this.title, required this.builder})
      : key = UniqueKey();

  final String title;
  final WidgetBuilder builder;

  /// Forces [AiCopilotSheet] (or any other docked widget) to be
  /// re-mounted between dock requests so per-session state — the
  /// chat history, voice mode, prompt buffer — starts fresh whenever
  /// the user opens the copilot from a different surface.
  final Key key;
}

class CopilotDockController extends ChangeNotifier {
  CopilotDockRequest? _request;

  CopilotDockRequest? get request => _request;
  bool get isOpen => _request != null;

  void open(CopilotDockRequest request) {
    _request = request;
    notifyListeners();
  }

  void close() {
    if (_request == null) return;
    _request = null;
    notifyListeners();
  }
}
