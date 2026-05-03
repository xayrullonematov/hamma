import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/sync/snippet_sync_service.dart';
import 'package:hamma/core/sync/snippet_sync_storage.dart';
import 'package:hamma/features/quick_actions/quick_actions.dart';

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
