import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/vault/vault_change_bus.dart';

void main() {
  group('VaultChangeBus', () {
    test('instance is a singleton', () {
      final instance1 = VaultChangeBus.instance;
      final instance2 = VaultChangeBus.instance;

      expect(identical(instance1, instance2), isTrue);
    });

    test('changes stream emits event on notify', () async {
      final bus = VaultChangeBus.instance;

      final future = expectLater(bus.changes, emits(isNull));

      bus.notify();

      await future;
    });

    test('changes stream is a broadcast stream', () {
      final bus = VaultChangeBus.instance;

      expect(bus.changes.isBroadcast, isTrue);
    });

    test('multiple listeners can subscribe and receive events', () async {
      final bus = VaultChangeBus.instance;

      var count1 = 0;
      var count2 = 0;

      final sub1 = bus.changes.listen((_) => count1++);
      final sub2 = bus.changes.listen((_) => count2++);

      bus.notify();

      // Allow the event loop to process the microtask
      await Future<void>.delayed(Duration.zero);

      expect(count1, 1);
      expect(count2, 1);

      await sub1.cancel();
      await sub2.cancel();
    });
  });
}
