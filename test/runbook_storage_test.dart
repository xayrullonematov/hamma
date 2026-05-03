import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/runbooks/runbook.dart';
import 'package:hamma/core/runbooks/runbook_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RunbookStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const RunbookStorage();
  });

  Runbook makeRb({
    String id = 'rb-1',
    String name = 'Test',
    String? serverId,
    bool team = false,
    List<RunbookStep> steps = const [],
  }) {
    return Runbook(
      id: id,
      name: name,
      serverId: serverId,
      team: team,
      steps: steps.isEmpty
          ? const [
              RunbookStep(
                id: 's1',
                label: 'echo',
                type: RunbookStepType.command,
                command: 'echo ok',
              ),
            ]
          : steps,
    );
  }

  group('round-trip', () {
    test('saveAll then loadAll returns the same runbooks', () async {
      await storage.saveAll([makeRb()]);
      final loaded = await storage.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'rb-1');
      expect(loaded.first.steps.first.command, 'echo ok');
    });

    test('upsert inserts then replaces by id', () async {
      await storage.upsert(makeRb(name: 'first'));
      await storage.upsert(makeRb(name: 'second'));
      final loaded = await storage.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.first.name, 'second');
    });

    test('delete removes by id and writes a tombstone', () async {
      await storage.upsert(makeRb(id: 'rb-keep'));
      await storage.upsert(makeRb(id: 'rb-drop'));
      await storage.delete('rb-drop');
      final loaded = await storage.loadAll();
      expect(loaded.map((r) => r.id), ['rb-keep']);
      final meta = await storage.loadMeta();
      expect(meta.tombstones.containsKey('rb-drop'), isTrue);
      expect(meta.updatedAt.containsKey('rb-drop'), isFalse);
    });
  });

  group('per-server scoping', () {
    test('loadForServer returns the global + server-pinned runbooks', () async {
      await storage.saveAll([
        makeRb(id: 'g'),
        makeRb(id: 'srv-a', serverId: 'a'),
        makeRb(id: 'srv-b', serverId: 'b'),
      ]);
      final forA = await storage.loadForServer('a');
      expect(forA.map((r) => r.id).toSet(), {'g', 'srv-a'});
    });
  });

  group('schema validation', () {
    test('rejects steps with unknown type at decode time', () {
      expect(
        () => Runbook.fromJson({
          'id': 'x',
          'name': 'x',
          'steps': [
            {'id': 's1', 'label': 'l', 'type': 'nope'},
          ],
        }),
        throwsA(isA<RunbookSchemaException>()),
      );
    });

    test('reports missing command on a command step', () {
      final rb = Runbook(
        id: 'x',
        name: 'x',
        steps: const [
          RunbookStep(id: 's1', label: 'l', type: RunbookStepType.command),
        ],
      );
      expect(rb.validate(), contains(predicate<String>(
        (p) => p.contains('command step needs a non-empty "command"'),
      )));
    });

    test('reports duplicate step ids', () {
      final rb = Runbook(
        id: 'x',
        name: 'x',
        steps: const [
          RunbookStep(
              id: 's1',
              label: 'a',
              type: RunbookStepType.command,
              command: 'true'),
          RunbookStep(
              id: 's1',
              label: 'b',
              type: RunbookStepType.command,
              command: 'true'),
        ],
      );
      expect(rb.validate(),
          contains(predicate<String>((p) => p.contains('duplicate step id'))));
    });

    test('regex waitFor needs a parseable pattern', () {
      final rb = Runbook(
        id: 'x',
        name: 'x',
        steps: const [
          RunbookStep(
            id: 's1',
            label: 'wait',
            type: RunbookStepType.waitFor,
            waitMode: 'regex',
            waitRegex: '[unterminated',
          ),
        ],
      );
      expect(rb.validate(),
          contains(predicate<String>((p) => p.contains('waitRegex'))));
    });
  });
}
