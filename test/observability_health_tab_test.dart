import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/observability/rolling_buffer.dart';
import 'package:hamma/features/observability/health_tab.dart';

void main() {
  group('HealthTab.shellQuoteForTest (POSIX single-quote escape)', () {
    test('plain values get single-quoted', () {
      expect(HealthTab.shellQuoteForTest('/var/log'), "'/var/log'");
      expect(HealthTab.shellQuoteForTest('eth0'), "'eth0'");
    });

    test('embedded single quote is escaped via the standard `\\\'` trick', () {
      // The classic POSIX escape: end-quote, backslash-quote, re-open.
      expect(
        HealthTab.shellQuoteForTest("/mnt/it's a trap"),
        r"'/mnt/it'\''s a trap'",
      );
    });

    test('shell metacharacters and command substitution are NOT honoured', () {
      // Hostile mount or interface name from a parsed remote response —
      // must NOT result in command substitution / chained commands.
      const hostile = r"/mnt/foo'; rm -rf / ; echo 'pwn";
      final quoted = HealthTab.shellQuoteForTest(hostile);
      // The `'` between `foo` and `;` is escaped, so the entire
      // payload remains a single argument to `find`. There is no
      // unescaped `;`, `$(`, or backtick that could run on the host.
      expect(quoted.startsWith("'"), isTrue);
      expect(quoted.endsWith("'"), isTrue);
      // Hostile single-quotes must each be wrapped in `'\''`.
      expect(quoted, contains(r"'\''"));
      // The dangerous `'; rm -rf /` substring should not appear as a
      // bare (unescaped) sequence — it must be preceded by `\`.
      expect(quoted.contains(r"\'';"), isTrue);
    });
  });

  group('RollingBuffer.setCapacity', () {
    test('shrinking drops oldest samples first', () {
      final buf = RollingBuffer(capacity: 100, minSamplesForAnomaly: 5);
      final t0 = DateTime(2025, 1, 1);
      for (var i = 0; i < 50; i++) {
        buf.push(t0.add(Duration(seconds: i)), i.toDouble());
      }
      expect(buf.samples.length, 50);
      buf.setCapacity(10);
      expect(buf.samples.length, 10);
      // Newest must be retained.
      expect(buf.samples.last.v, 49);
      expect(buf.samples.first.v, 40);
    });

    test('growing preserves all current samples', () {
      final buf = RollingBuffer(capacity: 5, minSamplesForAnomaly: 3);
      final t0 = DateTime(2025, 1, 1);
      for (var i = 0; i < 5; i++) {
        buf.push(t0.add(Duration(seconds: i)), i.toDouble());
      }
      buf.setCapacity(20);
      expect(buf.samples.length, 5);
      expect(buf.capacity, 20);
    });

    test('rejects values < 2', () {
      final buf = RollingBuffer();
      expect(() => buf.setCapacity(1), throwsA(isA<ArgumentError>()));
      expect(() => buf.setCapacity(0), throwsA(isA<ArgumentError>()));
    });
  });
}
