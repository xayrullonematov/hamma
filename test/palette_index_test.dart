import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/palette/palette_index.dart';
import 'package:hamma/core/palette/palette_source.dart';
import 'package:hamma/core/storage/frecency_storage.dart';

/// Stub source — returns the canned rows it was constructed with,
/// filtered by a contains check on the label so tests can exercise
/// match-vs-frecency interactions deterministically.
class _StubSource extends PaletteSource {
  _StubSource({required this.sourceId, required this.rows});

  final String sourceId;
  final List<({String id, String label, double matchScore})> rows;

  @override
  String get id => sourceId;
  @override
  String get displayName => sourceId;

  @override
  Future<List<PaletteResult>> query(String input) async {
    return [
      for (final r in rows)
        if (input.isEmpty ||
            r.label.toLowerCase().contains(input.toLowerCase()))
          PaletteResult(
            id: r.id,
            sourceId: sourceId,
            label: r.label,
            icon: const IconData(0),
            matchScore: r.matchScore,
            onInvoke: (_) async {},
          ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('query blends sources and sorts by match * (1 + frecency)', () async {
    final frecency = FrecencyStorage();
    // Touch B twice so it has a frecency lift.
    await frecency.record('servers', 'B');
    await frecency.record('servers', 'B');

    final index = PaletteIndex(
      sources: [
        _StubSource(
          sourceId: 'servers',
          rows: [
            (id: 'A', label: 'alpha', matchScore: 0.9),
            (id: 'B', label: 'alpha-beta', matchScore: 0.7),
          ],
        ),
      ],
      frecency: frecency,
    );

    final results = await index.query('alpha');
    // A: 0.9 * 1 = 0.9
    // B: 0.7 * (1 + ~1.1) ≈ 1.47
    expect(results.first.id, 'B');
  });

  test(
    'zero match score never reaches results even with frecency boost',
    () async {
      final frecency = FrecencyStorage();
      for (var i = 0; i < 10; i++) {
        await frecency.record('servers', 'C');
      }

      final index = PaletteIndex(
        sources: [
          _StubSource(
            sourceId: 'servers',
            rows: [
              (id: 'C', label: 'something-else', matchScore: 0.0),
              (id: 'D', label: 'alpha', matchScore: 0.9),
            ],
          ),
        ],
        frecency: frecency,
      );

      final results = await index.query('alpha');
      expect(results.map((r) => r.id), ['D']);
    },
  );

  test('perSourceCap and totalCap bound the result set', () async {
    final frecency = FrecencyStorage();
    final lots = [
      for (var i = 0; i < 50; i++) (id: 's$i', label: 's$i', matchScore: 0.9),
    ];
    final index = PaletteIndex(
      sources: [_StubSource(sourceId: 'servers', rows: lots)],
      frecency: frecency,
      perSourceCap: 5,
      totalCap: 3,
    );
    final results = await index.query('');
    expect(results, hasLength(3));
  });

  test('queryScoped narrows to one source', () async {
    final frecency = FrecencyStorage();
    final index = PaletteIndex(
      sources: [
        _StubSource(
          sourceId: 'servers',
          rows: [(id: 'A', label: 'alpha', matchScore: 0.9)],
        ),
        _StubSource(
          sourceId: 'screens',
          rows: [(id: 'B', label: 'alpha', matchScore: 0.9)],
        ),
      ],
      frecency: frecency,
    );
    final scoped = await index.queryScoped('servers', 'alpha');
    expect(scoped.map((r) => r.sourceId), ['servers']);
  });

  test('queryScoped throws on unknown sourceId', () async {
    final index = PaletteIndex(sources: [], frecency: FrecencyStorage());
    expect(() => index.queryScoped('nope', ''), throwsArgumentError);
  });

  test('recordInvocation records frecency under sourceId', () async {
    final frecency = FrecencyStorage();
    final index = PaletteIndex(
      sources: [
        _StubSource(
          sourceId: 'servers',
          rows: [(id: 'X', label: 'x', matchScore: 0.9)],
        ),
      ],
      frecency: frecency,
    );
    final results = await index.query('x');
    await index.recordInvocation(results.single);
    expect(await frecency.countFor('servers', 'X'), 1);
  });
}
