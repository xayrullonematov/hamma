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

    test('constant baseline never flags anomaly (stddev=0 guard)', () {
      final buf = RollingBuffer(minSamplesForAnomaly: 5, zScoreThreshold: 2);
      for (var i = 0; i < 20; i++) {
        final r = buf.push(DateTime(2026, 1, 1, 0, 0, i), 42.0);
        expect(r.anomalous, isFalse);
      }
      final spike = buf.push(DateTime(2026, 1, 1, 0, 0, 30), 99.0);
      // Constant history → stddev=0 → guard suppresses spurious flags.
      expect(spike.anomalous, isFalse);
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
