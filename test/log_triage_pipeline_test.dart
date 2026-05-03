import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:hamma/core/ai/ai_command_service.dart';
import 'package:hamma/core/ai/ai_provider.dart';
import 'package:hamma/core/ai/log_triage/log_batcher.dart';
import 'package:hamma/core/ai/log_triage/log_triage_models.dart';
import 'package:hamma/core/ai/log_triage/log_triage_service.dart';
import 'package:hamma/core/storage/log_triage_prefs.dart';

/// Test double for [AiCommandService] that returns canned JSON responses
/// according to a per-call recipe, optionally with a delay so we can
/// exercise the sequential drain behaviour of [LogTriageService.watch].
class _FakeAiCommandService extends AiCommandService {
  _FakeAiCommandService(this._recipes)
      : super(
          config: AiApiConfig.forProvider(
            provider: AiProvider.local,
            apiKey: '',
            localEndpoint: 'http://127.0.0.1:11434',
            localModel: 'gemma3',
          ),
        );

  final List<_Recipe> _recipes;
  int _calls = 0;

  int get calls => _calls;

  @override
  Future<String> generateChatResponse(
    String prompt, {
    List<Map<String, String>> history = const [],
  }) async {
    final i = _calls++;
    final recipe = _recipes[i % _recipes.length];
    if (recipe.delay > Duration.zero) {
      await Future<void>.delayed(recipe.delay);
    }
    if (recipe.throwException != null) throw recipe.throwException!;
    return recipe.response;
  }
}

class _Recipe {
  const _Recipe(this.response, {this.delay = Duration.zero});
  final String response;
  final Duration delay;
  Object? get throwException => null;
}

LogBatch _batch(int id, [String? line]) => LogBatch(
      lines: [line ?? 'line-$id'],
      startedAt: DateTime.utc(2024, 1, 1, 0, 0, id),
      endedAt: DateTime.utc(2024, 1, 1, 0, 0, id + 1),
    );

String _insightJson({
  String severity = 'normal',
  String summary = 's',
  String? cmd,
}) {
  final cmdField = cmd == null ? 'null' : '"$cmd"';
  return '{"severity":"$severity","summary":"$summary",'
      '"suggestedCommand":$cmdField,"riskHints":[]}';
}

/// Mute prefs that live entirely in memory so the test doesn't need
/// platform channels. We bypass [FlutterSecureStorage] by overriding
/// load/save fingerprints via a custom subclass.
class _MemoryPrefs extends LogTriagePrefs {
  _MemoryPrefs([Set<String>? initial])
      : _muted = {...?initial},
        super(secureStorage: const FlutterSecureStorage());

  final Set<String> _muted;
  int batchSize = LogTriagePrefs.defaultBatchSize;

  @override
  Future<Set<String>> loadMutedFingerprints() async => {..._muted};

  @override
  Future<void> saveMutedFingerprints(Set<String> fps) async {
    _muted
      ..clear()
      ..addAll(fps);
  }

  @override
  Future<void> mute(String fp) async {
    _muted.add(fp);
  }

  @override
  Future<void> unmute(String fp) async {
    _muted.remove(fp);
  }

  @override
  Future<int> loadBatchSize() async => batchSize;

  @override
  Future<void> saveBatchSize(int size) async {
    batchSize = LogTriagePrefs.clampBatchSize(size);
  }
}

void main() {
  group('LogTriageService.watch — sequential drain', () {
    test('emits insights in batch order even when LLM latency varies', () async {
      // Slow first call, then fast — without sequential drain the
      // second insight could arrive before the first.
      final fake = _FakeAiCommandService([
        _Recipe(_insightJson(severity: 'warn', summary: 'first'),
            delay: const Duration(milliseconds: 60)),
        _Recipe(_insightJson(severity: 'normal', summary: 'second')),
        _Recipe(_insightJson(severity: 'critical', summary: 'third')),
      ]);
      final triage = await LogTriageService.create(
        aiService: fake,
        prefs: _MemoryPrefs(),
      );

      final source = StreamController<LogBatch>();
      final out = <InsightUpdate>[];
      final sub = triage.watch(source.stream).listen(out.add);

      source
        ..add(_batch(1))
        ..add(_batch(2))
        ..add(_batch(3));
      await source.close();
      // Allow the slowest pending future to resolve.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(out.map((u) => u.insight.summary).toList(),
          ['first', 'second', 'third']);
      expect(fake.calls, 3);
    });

    test('delivers the final batch insight before the stream closes', () async {
      final fake = _FakeAiCommandService([
        _Recipe(_insightJson(summary: 'only'),
            delay: const Duration(milliseconds: 40)),
      ]);
      final triage = await LogTriageService.create(
        aiService: fake,
        prefs: _MemoryPrefs(),
      );
      final source = StreamController<LogBatch>();
      final out = <InsightUpdate>[];
      final done = Completer<void>();
      triage.watch(source.stream).listen(
            out.add,
            onDone: done.complete,
          );

      source.add(_batch(1));
      await source.close();
      await done.future.timeout(const Duration(seconds: 2));

      expect(out, hasLength(1));
      expect(out.first.insight.summary, 'only');
    });

    test('cancellation stops further emissions and drains in-flight work',
        () async {
      var emittedAfterCancel = false;
      final fake = _FakeAiCommandService([
        _Recipe(_insightJson(summary: 'one')),
        _Recipe(_insightJson(summary: 'two'),
            delay: const Duration(milliseconds: 80)),
        _Recipe(_insightJson(summary: 'three')),
      ]);
      final triage = await LogTriageService.create(
        aiService: fake,
        prefs: _MemoryPrefs(),
      );
      final source = StreamController<LogBatch>();
      final out = <InsightUpdate>[];
      late final StreamSubscription<InsightUpdate> sub;
      sub = triage.watch(source.stream).listen((u) {
        out.add(u);
      });

      source.add(_batch(1));
      // Wait for the first insight to land.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(out.map((u) => u.insight.summary), ['one']);

      // Now queue a slow second batch and immediately cancel.
      source.add(_batch(2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();
      // Add a batch after cancel — it must NOT be processed.
      source.add(_batch(3));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await source.close();

      emittedAfterCancel = out.length > 1;
      expect(emittedAfterCancel, isFalse,
          reason: 'no insight may be emitted after the subscription is cancelled');
    });
  });

  group('LogTriageService.watch — mute suppression', () {
    test('muted fingerprints stop firing on subsequent batches', () async {
      // Same summary every batch → same fingerprint → after the user
      // mutes it, it should never appear again.
      final fake = _FakeAiCommandService([
        _Recipe(_insightJson(severity: 'warn', summary: 'noisy auth fail')),
      ]);
      final prefs = _MemoryPrefs();
      final triage = await LogTriageService.create(
        aiService: fake,
        prefs: prefs,
      );

      final source = StreamController<LogBatch>();
      final out = <InsightUpdate>[];
      final sub = triage.watch(source.stream).listen(out.add);

      source.add(_batch(1));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(out, hasLength(1));

      // User mutes the surfaced pattern.
      await triage.mute(out.first.insight.fingerprint);

      // Three more batches with the same fingerprint should be suppressed.
      source
        ..add(_batch(2))
        ..add(_batch(3))
        ..add(_batch(4));
      await source.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(out, hasLength(1),
          reason: 'muted insights must not be re-emitted');
      expect(triage.isMuted(out.first.insight.fingerprint), isTrue);
    });
  });

  group('LogTriageService construction', () {
    test('refuses non-local providers (zero-trust guard)', () async {
      final cloud = AiCommandService.forProvider(
        provider: AiProvider.openAi,
        apiKey: 'sk-fake',
      );
      expect(
        () => LogTriageService.create(aiService: cloud, prefs: _MemoryPrefs()),
        throwsA(isA<LogTriageException>()),
      );
    });
  });

  group('LogTriageService.triageBatch — risk gating', () {
    test('marks dangerous suggestion as critical', () async {
      final fake = _FakeAiCommandService([
        _Recipe(_insightJson(
          severity: 'warn',
          summary: 'cleanup',
          cmd: 'rm -rf /',
        )),
      ]);
      final triage = await LogTriageService.create(
        aiService: fake,
        prefs: _MemoryPrefs(),
      );
      final update = await triage.triageBatch(_batch(1));
      expect(update.suggestedCommandIsCritical, isTrue);
    });

    test('throws on non-JSON response', () async {
      final fake = _FakeAiCommandService([
        const _Recipe('this is not json at all'),
      ]);
      final triage = await LogTriageService.create(
        aiService: fake,
        prefs: _MemoryPrefs(),
      );
      expect(
        () => triage.triageBatch(_batch(1)),
        throwsA(isA<LogTriageException>()),
      );
    });
  });
}
