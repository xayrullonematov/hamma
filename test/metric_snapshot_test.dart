import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/observability/metric_snapshot.dart';

void main() {
  group('MemorySample', () {
    test('usagePercent handles division by zero when totalBytes is 0', () {
      const sample = MemorySample(totalBytes: 0, usedBytes: 0);
      expect(sample.usagePercent, 0.0);
    });

    test('usagePercent correctly calculates percentage', () {
      const sample = MemorySample(totalBytes: 100, usedBytes: 25);
      expect(sample.usagePercent, 25.0);
    });
  });

  group('DiskMount', () {
    test('usagePercent handles division by zero when totalBytes is 0', () {
      const sample = DiskMount(mountPoint: '/', totalBytes: 0, usedBytes: 0);
      expect(sample.usagePercent, 0.0);
    });

    test('usagePercent correctly calculates percentage', () {
      const sample = DiskMount(mountPoint: '/', totalBytes: 200, usedBytes: 50);
      expect(sample.usagePercent, 25.0);
    });
  });
}
