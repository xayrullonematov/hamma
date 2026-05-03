import 'dart:async';

/// A window of log lines collected by [LogBatcher].
///
/// `startedAt` is the timestamp of the first line in the batch;
/// `endedAt` is the timestamp the batch was emitted (either because
/// the line cap was hit or the time cap fired).
class LogBatch {
  const LogBatch({
    required this.lines,
    required this.startedAt,
    required this.endedAt,
  });

  final List<String> lines;
  final DateTime startedAt;
  final DateTime endedAt;

  int get lineCount => lines.length;
  Duration get duration => endedAt.difference(startedAt);
}

/// Batches an arbitrary `Stream<String>` of log lines into [LogBatch]es.
///
/// A batch is emitted when EITHER:
///   - [maxLines] lines have accumulated, OR
///   - [maxWait] elapsed since the first buffered line in the current
///     batch.
///
/// Both bounds are required so that quiet streams still get inspected
/// (time bound) and noisy streams don't grow unbounded (line bound).
///
/// The output stream is single-subscription. Cancelling it cancels the
/// upstream subscription and any pending flush timer. If the upstream
/// closes with a partial buffer, that buffer is flushed as the final
/// batch before the stream is closed.
///
/// `maxLines` is clamped to `[1, hardCap]` (default hardCap = 500) so a
/// misconfigured setting can never starve the LLM with one giant
/// prompt.
class LogBatcher {
  LogBatcher({
    this.maxLines = 50,
    this.maxWait = const Duration(seconds: 5),
    this.hardLineCap = 500,
    DateTime Function()? clock,
  })  : assert(maxLines > 0, 'maxLines must be positive'),
        assert(hardLineCap > 0, 'hardLineCap must be positive'),
        assert(!maxWait.isNegative, 'maxWait must be non-negative'),
        _clock = clock ?? DateTime.now;

  final int maxLines;
  final Duration maxWait;
  final int hardLineCap;
  final DateTime Function() _clock;

  int get effectiveMaxLines =>
      maxLines.clamp(1, hardLineCap);

  /// Wraps [source] and emits one [LogBatch] per `maxLines` lines or
  /// per `maxWait`, whichever comes first.
  Stream<LogBatch> batch(Stream<String> source) {
    final controller = StreamController<LogBatch>();
    final cap = effectiveMaxLines;

    final buffer = <String>[];
    DateTime? bufferStartedAt;
    Timer? flushTimer;
    StreamSubscription<String>? upstream;
    var closed = false;

    void flush() {
      if (buffer.isEmpty) return;
      final started = bufferStartedAt ?? _clock();
      final batch = LogBatch(
        lines: List<String>.unmodifiable(buffer),
        startedAt: started,
        endedAt: _clock(),
      );
      buffer.clear();
      bufferStartedAt = null;
      flushTimer?.cancel();
      flushTimer = null;
      if (!controller.isClosed) controller.add(batch);
    }

    void scheduleFlushTimer() {
      if (maxWait == Duration.zero) return;
      flushTimer ??= Timer(maxWait, flush);
    }

    Future<void> shutdown({Object? error, StackTrace? stack}) async {
      if (closed) return;
      closed = true;
      flushTimer?.cancel();
      flushTimer = null;
      flush(); // emit any partial buffer as the terminal batch
      if (error != null && !controller.isClosed) {
        controller.addError(error, stack);
      }
      await upstream?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller.onListen = () {
      upstream = source.listen(
        (line) {
          if (closed) return;
          if (buffer.isEmpty) {
            bufferStartedAt = _clock();
            scheduleFlushTimer();
          }
          buffer.add(line);
          if (buffer.length >= cap) flush();
        },
        onError: (Object e, StackTrace st) {
          if (!controller.isClosed) controller.addError(e, st);
        },
        onDone: () => shutdown(),
        cancelOnError: false,
      );
    };
    controller.onCancel = () async {
      await shutdown();
    };
    controller.onPause = () => upstream?.pause();
    controller.onResume = () => upstream?.resume();

    return controller.stream;
  }
}
