import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/observability/metric_poller.dart';

String _fixture(String name) =>
    File('test/fixtures/observability/$name').readAsStringSync();

void main() {
  group('MetricPoller capability detection', () {
    test('parses probe output into a HostCapabilities flag set', () async {
      final poller = MetricPoller(
        exec: (cmd) async {
          // Probe shell prints one token per available tool on its own line.
          return 'TOP\nFREE\nDF\nNETDEV\nLOADAVG\n';
        },
      );
      final caps = await poller.detectCapabilities();
      expect(caps.hasTop, isTrue);
      expect(caps.hasFree, isTrue);
      expect(caps.hasDf, isTrue);
      expect(caps.hasProcNetDev, isTrue);
      expect(caps.hasProcLoadavg, isTrue);
      expect(caps.any, isTrue);
    });

    test('partial capability sets are honoured', () async {
      final poller = MetricPoller(exec: (_) async => 'TOP\nLOADAVG\n');
      final caps = await poller.detectCapabilities();
      expect(caps.hasTop, isTrue);
      expect(caps.hasFree, isFalse);
      expect(caps.hasProcLoadavg, isTrue);
      expect(caps.hasDf, isFalse);
    });

    test('empty probe → caps.any false', () async {
      final poller = MetricPoller(exec: (_) async => '');
      final caps = await poller.detectCapabilities();
      expect(caps.any, isFalse);
    });
  });

  group('MetricPoller.watch', () {
    test('emits a snapshot built from section markers', () async {
      var calls = 0;
      final poller = MetricPoller(
        interval: const Duration(milliseconds: 50),
        exec: (cmd) async {
          calls++;
          if (calls == 1) {
            return 'TOP\nFREE\nDF\nLOADAVG\n';
          }
          // Build a valid sectioned response from fixtures.
          return [
            '===HAMMA-CPU===',
            _fixture('debian_top.txt'),
            '===HAMMA-MEM===',
            _fixture('debian_free.txt'),
            '===HAMMA-DISK===',
            _fixture('debian_df.txt'),
            '===HAMMA-LOAD===',
            _fixture('proc_loadavg.txt'),
          ].join('\n');
        },
      );

      final snap = await poller.watch().first;
      expect(snap.cpu, isNotNull);
      expect(snap.memory, isNotNull);
      expect(snap.disks, isNotEmpty);
      expect(snap.load, isNotNull);
      expect(snap.load!.oneMinute, 0.42);
      expect(snap.topByCpu, isNotEmpty);
    });

    test('errors during a poll are surfaced via stream errors, not thrown',
        () async {
      var calls = 0;
      final poller = MetricPoller(
        interval: const Duration(milliseconds: 50),
        exec: (cmd) async {
          calls++;
          if (calls == 1) return 'TOP\n';
          throw const SocketException('reset');
        },
      );
      // No synchronous throw must escape watch() — the test passes if
      // we can listen and cancel without an unhandled exception.
      final sub = poller.watch().listen((_) {}, onError: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      expect(calls, greaterThan(0));
    });

    test('setInterval rejects out-of-range values (allowed window: 2..30s)',
        () {
      final poller = MetricPoller(exec: (_) async => '');
      expect(
        () => poller.setInterval(const Duration(seconds: 1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => poller.setInterval(const Duration(seconds: 31)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => poller.setInterval(const Duration(seconds: 2)),
        returnsNormally,
      );
      expect(
        () => poller.setInterval(const Duration(seconds: 30)),
        returnsNormally,
      );
    });
  });
}
