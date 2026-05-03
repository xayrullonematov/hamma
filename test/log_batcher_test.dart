import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/ai/log_triage/log_batcher.dart';

void main() {
  group('LogBatcher — line-count flush', () {
    test('emits a batch every maxLines lines', () async {
      final source = StreamController<String>();
      final batcher = LogBatcher(maxLines: 3, maxWait: const Duration(hours: 1));

      final out = batcher.batch(source.stream);
      final batches = <LogBatch>[];
      final sub = out.listen(batches.add);

      for (var i = 0; i < 7; i++) {
        source.add('line $i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(batches.length, 2, reason: '7 lines / 3 = 2 full batches');
      expect(batches[0].lines, ['line 0', 'line 1', 'line 2']);
      expect(batches[1].lines, ['line 3', 'line 4', 'line 5']);

      await source.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(batches.length, 3, reason: 'remaining buffer flushed on done');
      expect(batches.last.lines, ['line 6']);

      await sub.cancel();
    });

    test('hardLineCap clamps an oversized maxLines setting', () {
      final batcher = LogBatcher(maxLines: 9999, hardLineCap: 500);
      expect(batcher.effectiveMaxLines, 500);
    });

    test('a single oversized burst flushes only one batch at the cap', () async {
      final source = StreamController<String>();
      final batcher = LogBatcher(maxLines: 5, maxWait: const Duration(hours: 1));
      final batches = <LogBatch>[];
      batcher.batch(source.stream).listen(batches.add);
      for (var i = 0; i < 12; i++) {
        source.add('l$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(batches.length, 2);
      expect(batches[0].lines.length, 5);
      expect(batches[1].lines.length, 5);
      await source.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(batches.length, 3);
      expect(batches[2].lines, ['l10', 'l11']);
    });
  });

  group('LogBatcher — time flush', () {
    test('flushes a partial buffer once maxWait elapses', () {
      FakeAsync().run((async) {
        final source = StreamController<String>();
        final batcher = LogBatcher(
          maxLines: 100,
          maxWait: const Duration(seconds: 2),
        );

        final batches = <LogBatch>[];
        batcher.batch(source.stream).listen(batches.add);
        async.flushMicrotasks();

        source.add('a');
        source.add('b');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(batches, isEmpty,
            reason: 'no flush before maxWait elapses');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(batches.length, 1);
        expect(batches.first.lines, ['a', 'b']);
      });
    });

    test('time-flush timer resets across consecutive batches', () {
      FakeAsync().run((async) {
        final source = StreamController<String>();
        final batcher = LogBatcher(
          maxLines: 100,
          maxWait: const Duration(seconds: 2),
        );

        final batches = <LogBatch>[];
        batcher.batch(source.stream).listen(batches.add);
        async.flushMicrotasks();

        source.add('a');
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(batches.length, 1);

        source.add('b');
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(batches.length, 2);
        expect(batches[1].lines, ['b']);
      });
    });
  });
}
