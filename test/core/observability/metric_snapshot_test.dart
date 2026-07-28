import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/observability/metric_snapshot.dart';

void main() {
  group('MemorySample', () {
    test('computes usagePercent correctly', () {
      const sample = MemorySample(totalBytes: 1000, usedBytes: 500);
      expect(sample.usagePercent, 50.0);
    });

    test('avoids division by zero when totalBytes is 0', () {
      const sample = MemorySample(totalBytes: 0, usedBytes: 0);
      expect(sample.usagePercent, 0.0);
    });
  });

  group('DiskMount', () {
    test('computes usagePercent correctly', () {
      const mount = DiskMount(
        mountPoint: '/',
        totalBytes: 2000,
        usedBytes: 500,
      );
      expect(mount.usagePercent, 25.0);
      expect(mount.mountPoint, '/');
      expect(mount.totalBytes, 2000);
      expect(mount.usedBytes, 500);
    });

    test('avoids division by zero when totalBytes is 0', () {
      const mount = DiskMount(
        mountPoint: '/dev/null',
        totalBytes: 0,
        usedBytes: 0,
      );
      expect(mount.usagePercent, 0.0);
    });
  });
}
