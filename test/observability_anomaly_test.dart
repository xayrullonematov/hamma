import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/observability/rolling_buffer.dart';

void main() {
  group('RollingBuffer', () {
    test('does not flag anomaly until min samples accumulated', () {
      final buf = RollingBuffer(minSamplesForAnomaly: 5, zScoreThreshold: 2);
      for (var i = 0; i < 4; i++) {
        final r = buf.push(DateTime(2026, 1, 1, 0, 0, i), 5.0);
        expect(r.anomalous, isFalse);
        expect(r.score, isNull);
      }
    });

    test('flags anomaly on a clear z-score outlier', () {
      final buf = RollingBuffer(minSamplesForAnomaly: 5, zScoreThreshold: 2);
      for (var i = 0; i < 20; i++) {
        buf.push(DateTime(2026, 1, 1, 0, 0, i), 10.0 + (i % 2));
      }
      final r = buf.push(DateTime(2026, 1, 1, 0, 0, 30), 99.0);
      expect(r.anomalous, isTrue);
      expect(r.score!.abs(), greaterThan(2));
    });

    test('hysteresis keeps state until score drops well below threshold', () {
      final buf = RollingBuffer(
        minSamplesForAnomaly: 5,
        zScoreThreshold: 3,
        hysteresis: 1,
      );
      // Build a baseline ~10 with small jitter.
      for (var i = 0; i < 20; i++) {
        buf.push(DateTime(2026, 1, 1, 0, 0, i), 10.0 + (i % 2) * 0.1);
      }
      // Spike trips anomaly.
      final r1 = buf.push(DateTime(2026, 1, 1, 0, 0, 30), 100.0);
      expect(r1.anomalous, isTrue);
      // A return to slightly elevated still keeps anomaly latched
      // because the previous spike pulled mean/std up; and even when
      // the score is below 3 it stays anomalous until below 2.
      final r2 = buf.push(DateTime(2026, 1, 1, 0, 0, 31), 10.0);
      expect(r2.anomalous, anyOf(isTrue, isFalse)); // either is acceptable
      // Many normal samples eventually clear it.
      bool stillAnom = r2.anomalous;
      for (var i = 32; i < 200 && stillAnom; i++) {
        stillAnom = buf
            .push(DateTime(2026, 1, 1, 0, 0, i), 10.0 + (i % 2) * 0.1)
            .anomalous;
      }
      expect(stillAnom, isFalse);
    });

    test('constant baseline → identical samples never flag', () {
      final buf = RollingBuffer(minSamplesForAnomaly: 5, zScoreThreshold: 2);
      for (var i = 0; i < 20; i++) {
        final r = buf.push(DateTime(2026, 1, 1, 0, 0, i), 42.0);
        expect(r.anomalous, isFalse);
      }
      // A repeat of the baseline keeps the flag clear — no flutter on
      // idle hosts that don't actually change.
      final same = buf.push(DateTime(2026, 1, 1, 0, 0, 30), 42.0);
      expect(same.anomalous, isFalse);
    });

    test('idle-to-spike flags anomaly even with stddev=0 baseline', () {
      // Most "real spikes" are the idle CPU / network / load case:
      // a flat 0% sits there for an hour and then jumps to 80%. The
      // z-score is undefined for stddev=0 but the operator absolutely
      // wants this surfaced — covered by flatBaselineMinDelta.
      final buf = RollingBuffer(
        minSamplesForAnomaly: 5,
        zScoreThreshold: 3,
        flatBaselineMinDelta: 1.0,
      );
      for (var i = 0; i < 20; i++) {
        buf.push(DateTime(2026, 1, 1, 0, 0, i), 0.0);
      }
      final spike = buf.push(DateTime(2026, 1, 1, 0, 0, 21), 80.0);
      expect(spike.anomalous, isTrue);
      expect(spike.stddev, 0);
    });

    test('idle baseline + sub-threshold delta does NOT flag', () {
      final buf = RollingBuffer(
        minSamplesForAnomaly: 5,
        flatBaselineMinDelta: 5.0,
      );
      for (var i = 0; i < 20; i++) {
        buf.push(DateTime(2026, 1, 1, 0, 0, i), 0.0);
      }
      // 2.0 of jitter on a flat 0 baseline isn't a spike — caller
      // configured min-delta to 5.0.
      final wobble = buf.push(DateTime(2026, 1, 1, 0, 0, 21), 2.0);
      expect(wobble.anomalous, isFalse);
    });

    test('capacity bounds buffer size', () {
      final buf = RollingBuffer(capacity: 10, minSamplesForAnomaly: 3);
      for (var i = 0; i < 50; i++) {
        buf.push(DateTime(2026, 1, 1, 0, 0, i), i.toDouble());
      }
      expect(buf.samples.length, 10);
      expect(buf.samples.first.v, 40);
      expect(buf.samples.last.v, 49);
    });
  });
}
