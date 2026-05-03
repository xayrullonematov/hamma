import 'dart:async';

/// Process-wide broadcast bus that fires after the user mutates the
/// vault (add / edit / delete). [VaultSyncService] subscribes to drive
/// debounced cloud uploads; the redaction pipeline subscribes to
/// invalidate any cached redactor snapshots.
class VaultChangeBus {
  VaultChangeBus._();

  static final VaultChangeBus instance = VaultChangeBus._();

  final StreamController<void> _controller =
      StreamController<void>.broadcast();

  Stream<void> get changes => _controller.stream;

  void notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }
}
