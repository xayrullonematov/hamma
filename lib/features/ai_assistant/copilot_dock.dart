import 'package:flutter/material.dart';

import 'ai_copilot_sheet.dart';

/// InheritedNotifier surfaced by the desktop dashboard so descendant
/// widgets can dock the AI Copilot as a side pane instead of a modal.
/// When absent, callers fall back to `showModalBottomSheet`.
class CopilotDock extends InheritedNotifier<CopilotDockController> {
  const CopilotDock({
    super.key,
    required CopilotDockController controller,
    required super.child,
  }) : super(notifier: controller);

  static CopilotDockController? maybeOf(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<CopilotDock>();
    return widget?.notifier;
  }
}

class CopilotDockRequest {
  CopilotDockRequest({required this.title, required this.builder})
      : key = UniqueKey();

  final String title;
  final WidgetBuilder builder;

  /// Per-request key — forces [AiCopilotSheet] to remount between
  /// surfaces so chat / voice state does not leak across opens.
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
