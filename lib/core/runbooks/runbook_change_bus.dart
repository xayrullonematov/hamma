import 'dart:async';

/// Broadcast bus fired on any runbook create/edit/delete.
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
