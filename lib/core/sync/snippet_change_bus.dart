import 'dart:async';

/// Process-wide broadcast bus that fires after the user mutates the
/// custom snippets list (add / edit / delete / clear).
///
/// [SnippetSyncService] subscribes to this so a debounced upload kicks
/// off automatically — without coupling the storage layer to the sync
/// layer. Other listeners (e.g. UI cards) can also subscribe.
class SnippetChangeBus {
  SnippetChangeBus._();

  static final SnippetChangeBus instance = SnippetChangeBus._();

  final StreamController<void> _controller =
      StreamController<void>.broadcast();

  Stream<void> get changes => _controller.stream;

  void notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }
}
