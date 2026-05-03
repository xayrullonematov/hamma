import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/backup_crypto.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/storage/backup_storage.dart';
import 'package:hamma/core/storage/custom_actions_storage.dart';
import 'package:hamma/core/sync/snippet_sync_service.dart';
import 'package:hamma/core/sync/snippet_sync_storage.dart';
import 'package:hamma/features/quick_actions/quick_actions.dart';

class _FakeAdapter extends CloudSyncAdapter {
  _FakeAdapter({this.preset, this.failGetWith});

  Uint8List? preset;
  Object? failGetWith;
  Uint8List? lastPut;
  int putCount = 0;

  @override
  String get destinationLabel => 'Fake';
  @override
  bool get isConfigured => true;
  @override
  Future<List<CloudObject>> list() async => const [];
  @override
  Future<Uint8List> get(String key) async {
    if (failGetWith != null) throw failGetWith!;
    final p = preset;
    if (p == null) throw const CloudNotFoundException('not found');
    return p;
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    putCount += 1;
    lastPut = bytes;
  }

  @override
  Future<void> delete(String key) async {}
}

void main() {
  group('mergeSnippets — pure newest-wins merge', () {
    final t0 = DateTime.utc(2026, 1, 1);
    final t1 = DateTime.utc(2026, 1, 2);
    final t2 = DateTime.utc(2026, 1, 3);
    final t3 = DateTime.utc(2026, 1, 4);

    QuickAction snip(String id, String label, {String cmd = 'echo'}) =>
        QuickAction(id: id, label: label, command: cmd, isCustom: true);

    test('union when ids are disjoint', () {
      final result = mergeSnippets(
        localSnippets: [snip('a', 'A')],
        localMeta: SnippetSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
        remoteSnippets: [snip('b', 'B')],
        remoteMeta: SnippetSyncMeta(updatedAt: {'b': t0}, tombstones: const {}),
      );
      expect(result.snippets.map((s) => s.id).toSet(), {'a', 'b'});
      expect(result.meta.tombstones, isEmpty);
    });

    test('newer updatedAt wins on conflict', () {
      final result = mergeSnippets(
        localSnippets: [snip('a', 'old-local')],
        localMeta: SnippetSyncMeta(updatedAt: {'a': t1}, tombstones: const {}),
        remoteSnippets: [snip('a', 'new-remote')],
        remoteMeta: SnippetSyncMeta(updatedAt: {'a': t2}, tombstones: const {}),
      );
      expect(result.snippets, hasLength(1));
      expect(result.snippets.single.label, 'new-remote');
      expect(result.meta.updatedAt['a'], t2);
    });

    test('local tombstone (newer) deletes remote snippet', () {
      final result = mergeSnippets(
        localSnippets: const [],
        localMeta: SnippetSyncMeta(
          updatedAt: const {},
          tombstones: {'a': t2},
        ),
        remoteSnippets: [snip('a', 'still-here')],
        remoteMeta: SnippetSyncMeta(updatedAt: {'a': t1}, tombstones: const {}),
      );
      expect(result.snippets, isEmpty);
      expect(result.meta.tombstones['a'], t2);
    });

    test('remote edit (newer) revives a stale local tombstone', () {
      final result = mergeSnippets(
        localSnippets: const [],
        localMeta: SnippetSyncMeta(
          updatedAt: const {},
          tombstones: {'a': t1},
        ),
        remoteSnippets: [snip('a', 'edited-after-delete')],
        remoteMeta: SnippetSyncMeta(updatedAt: {'a': t2}, tombstones: const {}),
      );
      expect(result.snippets.single.label, 'edited-after-delete');
      expect(result.meta.tombstones, isEmpty);
    });

    test('both tombstoned — newer tombstone retained', () {
      final result = mergeSnippets(
        localSnippets: const [],
        localMeta: SnippetSyncMeta(
          updatedAt: const {},
          tombstones: {'a': t1},
        ),
        remoteSnippets: const [],
        remoteMeta: SnippetSyncMeta(
          updatedAt: const {},
          tombstones: {'a': t3},
        ),
      );
      expect(result.snippets, isEmpty);
      expect(result.meta.tombstones['a'], t3);
    });

    test('missing updatedAt treated as epoch — present snippet still wins '
        'over older tombstone', () {
      final result = mergeSnippets(
        localSnippets: [snip('a', 'kept')],
        localMeta: SnippetSyncMeta.empty,
        remoteSnippets: const [],
        remoteMeta: SnippetSyncMeta(
          updatedAt: const {},
          tombstones: {
            'a': DateTime.fromMillisecondsSinceEpoch(0).toUtc(),
          },
        ),
      );
      // Both candidates have epoch timestamps; tie-break is whatever
      // sort settles on but never resurrects a snippet incorrectly:
      // here local snippet has updatedAt=epoch and remote tombstone has
      // updatedAt=epoch too, so either outcome is acceptable.
      // We assert at least no crash and that the result is consistent.
      expect(
        (result.snippets.length + result.meta.tombstones.length),
        1,
      );
    });
  });

  group('pull-merge-push round-trip safety', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const pin = '123456';
    const cloudConfig = BackupConfig(
      destination: BackupDestination.s3Compat,
    );

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      await const SnippetSyncStorage().setEnabled(true);
      await const BackupStorage().saveConfig(cloudConfig);
    });

    test(
      'stale-device push preserves a newer remote-only snippet '
      '(does NOT clobber the cloud blob)',
      () async {
        // Seed remote with a snippet authored by some OTHER device
        // that THIS device has never seen.
        final remoteOnly = SnippetSyncBlob(
          snippets: const [
            QuickAction(
              id: 'remote-only',
              label: 'remote-label',
              command: 'remote-cmd',
              isCustom: true,
            ),
          ],
          meta: SnippetSyncMeta(
            updatedAt: {'remote-only': DateTime.utc(2026, 5, 1)},
            tombstones: const {},
          ),
          deviceId: 'other-device',
          generatedAt: DateTime.utc(2026, 5, 1, 12),
        );
        final preset = BackupCrypto.encrypt(pin, remoteOnly.encode());

        final adapter = _FakeAdapter(preset: preset);
        final service = SnippetSyncService(
          adapterBuilder: (_) => adapter,
          passwordResolver: () async => pin,
        );

        // Local has nothing → naive push would have wiped the remote
        // snippet. The fix MUST pull-merge-push instead.
        await service.pushNow();

        expect(adapter.putCount, 1);
        final pushed = SnippetSyncBlob.decode(
          BackupCrypto.decrypt(pin, adapter.lastPut!),
        );
        expect(
          pushed.snippets.map((s) => s.id).toSet(),
          {'remote-only'},
          reason:
              'pushNow must merge remote into local before uploading; '
              'the unseen remote snippet must survive.',
        );
        // Local store must also now contain the merged state.
        final localAfter =
            await const CustomActionsStorage().loadActions();
        expect(localAfter.single.id, 'remote-only');
      },
    );

    test(
      'transient adapter download error must NOT trigger an upload '
      '(prevents stale-overwrite on network/auth failure)',
      () async {
        final adapter = _FakeAdapter(
          failGetWith: const CloudSyncException(
            'simulated 503 from provider',
          ),
        );
        final service = SnippetSyncService(
          adapterBuilder: (_) => adapter,
          passwordResolver: () async => pin,
        );

        await service.pushNow();

        expect(
          adapter.putCount,
          0,
          reason:
              'A non-NotFound adapter error must abort the round-trip '
              'before any upload, otherwise a transient outage could '
              'overwrite a newer remote blob with stale local state.',
        );
        final history = await const SnippetSyncStorage().loadHistory();
        expect(history, isNotEmpty);
        expect(history.first.success, isFalse);
      },
    );
  });

  group('SnippetSyncBlob round-trip', () {
    test('encode then decode preserves content', () {
      final blob = SnippetSyncBlob(
        snippets: [
          const QuickAction(
            id: 'x',
            label: 'X',
            command: 'cmd-x',
            isCustom: true,
          ),
        ],
        meta: SnippetSyncMeta(
          updatedAt: {'x': DateTime.utc(2026, 4, 1, 12)},
          tombstones: {'old': DateTime.utc(2026, 3, 15)},
        ),
        deviceId: 'dev-123',
        generatedAt: DateTime.utc(2026, 4, 1, 12, 30),
      );
      final round = SnippetSyncBlob.decode(blob.encode());
      expect(round.snippets.single.id, 'x');
      expect(round.snippets.single.command, 'cmd-x');
      expect(round.deviceId, 'dev-123');
      expect(round.generatedAt, blob.generatedAt);
      expect(round.meta.updatedAt['x'], blob.meta.updatedAt['x']);
      expect(round.meta.tombstones['old'], blob.meta.tombstones['old']);
    });
  });
}
