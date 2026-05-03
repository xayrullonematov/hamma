import 'dart:async';

/// Process-wide broadcast bus that fires whenever a runbook is
/// created, edited, or deleted. The list/editor screens subscribe
/// for live refresh; [RunbookSyncService] subscribes to debounce a
/// cloud push (mirrors the snippet sync architecture).
class RunbookChangeBus {
  RunbookChangeBus._();

  static final RunbookChangeBus instance = RunbookChangeBus._();

  final StreamController<void> _controller =
      StreamController<void>.broadcast();

  Stream<void> get changes => _controller.stream;

  void notify() {
    if (!_controller.isClosed) _controller.add(null);
  }
}
