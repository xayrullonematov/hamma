import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/observability/metric_parsers.dart';

String _read(String name) =>
    File('test/fixtures/observability/$name').readAsStringSync();

void main() {
  group('parseTop', () {
    test('Debian-style top yields cpu usage and process list', () {
      final (cpu, procs) = MetricParsers.parseTop(_read('debian_top.txt'));
      expect(cpu, isNotNull);
      // 100 - 95.4 idle = 4.6
      expect(cpu!.usagePercent, closeTo(4.6, 0.01));
      expect(procs, isNotEmpty);
      expect(procs.first.command, 'postgres');
      expect(procs.first.pid, 1234);
      expect(procs.first.cpuPercent, closeTo(18.6, 0.01));
      expect(procs.first.memPercent, closeTo(4.8, 0.01));
    });

    test('busybox/alpine top idle line still parses', () {
      final (cpu, _) = MetricParsers.parseTop(_read('alpine_top.txt'));
      expect(cpu, isNotNull);
      // 100 - 84.0 = 16.0
      expect(cpu!.usagePercent, closeTo(16.0, 0.01));
    });

    test('garbage input yields nulls / empty list, never throws', () {
      final (cpu, procs) = MetricParsers.parseTop('not top output\nat all\n');
      expect(cpu, isNull);
      expect(procs, isEmpty);
    });
  });

  group('parseFree', () {
    test('Debian free -k', () {
      final mem = MetricParsers.parseFree(_read('debian_free.txt'));
      expect(mem, isNotNull);
      expect(mem!.totalBytes, 2027712 * 1024);
      expect(mem.usedBytes, 905404 * 1024);
      expect(mem.usagePercent, greaterThan(40));
      expect(mem.usagePercent, lessThan(50));
    });

    test('missing Mem: row returns null', () {
      expect(MetricParsers.parseFree('garbage\n'), isNull);
    });
  });

  group('parseDf', () {
    test('df -P with mounts and pseudo filesystems filtered', () {
      final mounts = MetricParsers.parseDf(_read('debian_df.txt'));
      // tmpfs + overlay filtered out, /dev/sda1 + /dev/sda2 kept
      expect(mounts.map((m) => m.mountPoint), ['/', '/var/log']);
      expect(mounts.first.totalBytes, 62914560 * 1024);
      expect(mounts.first.usagePercent, closeTo(28.93, 0.5));
    });
  });

  group('parseProcNetDev + netRate', () {
    test('cumulative parse skips lo and headers', () {
      final stats = MetricParsers.parseProcNetDev(_read('proc_net_dev.txt'));
      expect(stats.containsKey('lo'), isFalse);
      expect(stats['eth0']!.$1, 9876543210);
      expect(stats['eth0']!.$2, 1234567890);
    });

    test('netRate computes bytes/sec from two snapshots', () {
      final prev = {'eth0': (1000, 500)};
      final cur = {'eth0': (3000, 1500)};
      final r = MetricParsers.netRate(
        previous: prev,
        current: cur,
        interval: const Duration(seconds: 2),
      );
      expect(r, hasLength(1));
      expect(r.single.rxBytesPerSecond, closeTo(1000, 0.001));
      expect(r.single.txBytesPerSecond, closeTo(500, 0.001));
    });

    test('netRate handles counter wrap by clamping at zero', () {
      final r = MetricParsers.netRate(
        previous: {'eth0': (5000, 5000)},
        current: {'eth0': (1000, 1000)},
        interval: const Duration(seconds: 1),
      );
      expect(r.single.rxBytesPerSecond, 0);
      expect(r.single.txBytesPerSecond, 0);
    });
  });

  group('parseLoadavg', () {
    test('valid /proc/loadavg', () {
      final l = MetricParsers.parseLoadavg(_read('proc_loadavg.txt'));
      expect(l, isNotNull);
      expect(l!.oneMinute, 0.42);
      expect(l.fiveMinute, 0.55);
      expect(l.fifteenMinute, 0.61);
    });

    test('blank input returns null', () {
      expect(MetricParsers.parseLoadavg(''), isNull);
    });
  });
}
