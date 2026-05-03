import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/backup/icloud_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ICloudAdapter on non-Apple platforms', () {
    test('isConfigured is false even with a container id', () {
      final adapter = ICloudAdapter(
        containerId: 'iCloud.com.hamma.app',
        isAppleOverride: false,
      );
      expect(adapter.isConfigured, isFalse);
    });

    test('list throws UnsupportedError-ish CloudSyncException', () async {
      final adapter = ICloudAdapter(
        containerId: 'iCloud.com.hamma.app',
        isAppleOverride: false,
      );
      expect(
        () => adapter.list(),
        throwsA(isA<CloudSyncException>()),
      );
    });
  });

  group('ICloudAdapter on Apple platforms (mocked channel)', () {
    const channel = MethodChannel(ICloudAdapter.channelName);
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'list':
            return [
              {
                'key': 'snapshot.aes',
                'size': 1024,
                'lastModifiedMs': 1717245600000,
              },
            ];
          case 'get':
            return Uint8List.fromList([0x48, 0x4D, 0x42, 0x4B, 0x02]);
          case 'put':
          case 'delete':
          case 'rename':
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('list calls into the platform channel and parses entries', () async {
      final adapter = ICloudAdapter(
        containerId: 'iCloud.com.hamma.app',
        isAppleOverride: true,
      );
      final objects = await adapter.list();
      expect(calls, hasLength(1));
      expect(calls.first.method, 'list');
      expect(calls.first.arguments['container'], 'iCloud.com.hamma.app');
      expect(objects, hasLength(1));
      expect(objects.first.key, 'snapshot.aes');
      expect(objects.first.size, 1024);
    });

    test('put forwards bytes verbatim', () async {
      final adapter = ICloudAdapter(
        containerId: 'iCloud.com.hamma.app',
        isAppleOverride: true,
      );
      await adapter.put('snapshot.aes', Uint8List.fromList([1, 2, 3]));
      expect(calls.first.method, 'put');
      expect(calls.first.arguments['key'], 'snapshot.aes');
      expect(calls.first.arguments['bytes'], [1, 2, 3]);
    });

    test('get returns native bytes', () async {
      final adapter = ICloudAdapter(
        containerId: 'iCloud.com.hamma.app',
        isAppleOverride: true,
      );
      final bytes = await adapter.get('snapshot.aes');
      expect(bytes, [0x48, 0x4D, 0x42, 0x4B, 0x02]);
    });
  });
}
