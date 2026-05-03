import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/runbooks/runbook.dart';
import 'package:hamma/core/runbooks/runbook_storage.dart';
import 'package:hamma/core/sync/runbook_sync_service.dart';

void main() {
  Runbook makeRb(String id, String name) => Runbook(
        id: id,
        name: name,
        team: true,
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'echo',
            type: RunbookStepType.command,
            command: 'echo ok',
          ),
        ],
      );

  final t0 = DateTime.utc(2026, 1, 1);
  final t1 = DateTime.utc(2026, 1, 2);
  final t2 = DateTime.utc(2026, 1, 3);

  test('union when ids are disjoint', () {
    final merged = mergeRunbooks(
      localRunbooks: [makeRb('a', 'A')],
      localMeta: RunbookSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
      remoteRunbooks: [makeRb('b', 'B')],
      remoteMeta: RunbookSyncMeta(updatedAt: {'b': t0}, tombstones: const {}),
    );
    expect(merged.runbooks.map((r) => r.id).toSet(), {'a', 'b'});
    expect(merged.meta.tombstones, isEmpty);
  });

  test('newer updatedAt wins on conflict', () {
    final merged = mergeRunbooks(
      localRunbooks: [makeRb('a', 'old')],
      localMeta: RunbookSyncMeta(updatedAt: {'a': t1}, tombstones: const {}),
      remoteRunbooks: [makeRb('a', 'new')],
      remoteMeta: RunbookSyncMeta(updatedAt: {'a': t2}, tombstones: const {}),
    );
    expect(merged.runbooks.single.name, 'new');
    expect(merged.meta.updatedAt['a'], t2);
  });

  test('newer tombstone deletes a stale remote entry', () {
    final merged = mergeRunbooks(
      localRunbooks: const [],
      localMeta: RunbookSyncMeta(
        updatedAt: const {},
        tombstones: {'a': t2},
      ),
      remoteRunbooks: [makeRb('a', 'stale')],
      remoteMeta: RunbookSyncMeta(updatedAt: {'a': t1}, tombstones: const {}),
    );
    expect(merged.runbooks, isEmpty);
    expect(merged.meta.tombstones['a'], t2);
  });

  test('blob round-trips through encode/decode', () {
    final blob = RunbookSyncBlob(
      runbooks: [makeRb('a', 'A')],
      meta: RunbookSyncMeta(updatedAt: {'a': t0}, tombstones: const {}),
      deviceId: 'dev-1',
      generatedAt: t0,
    );
    final decoded = RunbookSyncBlob.decode(blob.encode());
    expect(decoded.runbooks.single.name, 'A');
    expect(decoded.deviceId, 'dev-1');
    expect(decoded.meta.updatedAt['a'], t0);
  });
}
