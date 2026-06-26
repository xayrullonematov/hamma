import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/frecency_storage.dart';

/// Test clock so we can advance time without sleeping in real life.
class _FakeClock implements Clock {
  _FakeClock(this._now);
  int _now;

  void advance(Duration d) => _now += d.inMilliseconds;

  @override
  int nowMs() => _now;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FrecencyStorage storage;
  late _FakeClock clock;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    clock = _FakeClock(DateTime(2026, 1, 1).millisecondsSinceEpoch);
    storage = FrecencyStorage(clock: clock);
  });

  group('FrecencyEntry.scoreAt', () {
    test('first hit produces a non-zero score', () {
      final e = FrecencyEntry(
        category: 'servers',
        itemId: 'a',
        count: 1,
        lastAccessedMs: clock.nowMs(),
      );
      // log(2) ≈ 0.693 / sqrt(1) = 0.693
      expect(e.scoreAt(clock.nowMs()), closeTo(math.log(2), 1e-9));
    });

    test('score grows monotonically with count', () {
      final low = FrecencyEntry(
        category: 'servers',
        itemId: 'a',
        count: 2,
        lastAccessedMs: clock.nowMs(),
      ).scoreAt(clock.nowMs());
      final high = FrecencyEntry(
        category: 'servers',
        itemId: 'b',
        count: 50,
        lastAccessedMs: clock.nowMs(),
      ).scoreAt(clock.nowMs());
      expect(high, greaterThan(low));
    });

    test('score decays as ageDays grows', () {
      final fresh = FrecencyEntry(
        category: 'servers',
        itemId: 'a',
        count: 10,
        lastAccessedMs: clock.nowMs(),
      );
      final ageMs = clock.nowMs() + const Duration(days: 99).inMilliseconds;
      expect(fresh.scoreAt(clock.nowMs()), greaterThan(fresh.scoreAt(ageMs)));
    });

    test('future-dated lastAccessedMs is clamped (no negative ageDays)', () {
      final future = FrecencyEntry(
        category: 'servers',
        itemId: 'a',
        count: 3,
        lastAccessedMs: clock.nowMs() + const Duration(days: 5).inMilliseconds,
      );
      // Treated as ageDays == 0; would otherwise produce nan/inf.
      expect(future.scoreAt(clock.nowMs()), math.log(4));
    });
  });

  group('record + scoreFor', () {
    test('unrecorded items score 0', () async {
      expect(await storage.scoreFor('servers', 'unknown'), 0.0);
    });

    test('record bumps count + lastAccessedMs', () async {
      await storage.record('servers', 'prod-1');
      expect(await storage.countFor('servers', 'prod-1'), 1);

      clock.advance(const Duration(minutes: 5));
      await storage.record('servers', 'prod-1');
      expect(await storage.countFor('servers', 'prod-1'), 2);
    });

    test('ignores empty category or item id', () async {
      await storage.record('', 'x');
      await storage.record('servers', '');
      expect(await storage.countFor('', 'x'), 0);
      expect(await storage.countFor('servers', ''), 0);
    });
  });

  group('scoresForCategory + topItems', () {
    test('isolates categories by namespace', () async {
      await storage.record('servers', 'a');
      await storage.record('runbooks', 'a');
      final servers = await storage.scoresForCategory('servers');
      final runbooks = await storage.scoresForCategory('runbooks');
      expect(servers.keys, ['a']);
      expect(runbooks.keys, ['a']);
      // Same id in two categories is two separate entries.
      expect(servers['a'], runbooks['a']);
    });

    test('higher count + more recent wins', () async {
      // A: touched 4 times yesterday
      for (var i = 0; i < 4; i++) {
        await storage.record('servers', 'A');
      }
      // B: touched once just now
      clock.advance(const Duration(days: 1));
      await storage.record('servers', 'B');

      final top = await storage.topItems('servers');
      // log(5)/sqrt(2) ≈ 1.14, log(2)/sqrt(1) ≈ 0.69 → A still leads.
      expect(top.first, 'A');
    });

    test('age decay can flip ranking', () async {
      await storage.record('servers', 'A');
      // A ages out over a year.
      clock.advance(const Duration(days: 365));
      await storage.record('servers', 'B');
      final top = await storage.topItems('servers');
      expect(top.first, 'B');
    });
  });

  group('persistence', () {
    test('round-trips through secure storage', () async {
      await storage.record('servers', 'persisted-1');
      await storage.record('servers', 'persisted-1');

      // Rebuild from raw storage, same clock.
      final rehydrated = FrecencyStorage(clock: clock);
      expect(await rehydrated.countFor('servers', 'persisted-1'), 2);
    });

    test('corrupt blob falls back to empty', () async {
      const storage = FlutterSecureStorage();
      await storage.write(key: 'frecency_v1', value: '{not json');
      final fresh = FrecencyStorage(clock: _FakeClock(0));
      expect(await fresh.scoreFor('servers', 'anything'), 0.0);
      // And we can still record after recovering from corruption.
      await fresh.record('servers', 'x');
      expect(await fresh.countFor('servers', 'x'), 1);
    });

    test('clear(category) removes only that category', () async {
      await storage.record('servers', 'a');
      await storage.record('runbooks', 'b');
      await storage.clear(category: 'servers');
      expect(await storage.countFor('servers', 'a'), 0);
      expect(await storage.countFor('runbooks', 'b'), 1);
    });

    test('clear() removes everything', () async {
      await storage.record('servers', 'a');
      await storage.record('runbooks', 'b');
      await storage.clear();
      expect(await storage.countFor('servers', 'a'), 0);
      expect(await storage.countFor('runbooks', 'b'), 0);
    });
  });
}
