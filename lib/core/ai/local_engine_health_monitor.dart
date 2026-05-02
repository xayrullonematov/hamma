import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ollama_client.dart';

/// Coarse health states the UI cares about.
///
/// Note the distinction between [loading] (we are still establishing
/// whether the engine is reachable) and [loadingModel] (the engine is
/// reachable but no model is currently warm in RAM, so the next
/// inference call will pay a cold-start cost).
enum LocalEngineHealthStatus {
  /// We have not yet contacted the engine on this monitor instance.
  loading,

  /// Engine answered but no model is currently loaded in RAM. The next
  /// chat call will trigger a (potentially slow) model warmup. UI
  /// should render this in an amber "warming up" style.
  loadingModel,

  /// The most recent ping reached the engine and it answered successfully.
  online,

  /// The most recent ping failed (offline, wrong port, timeout, error).
  offline,
}

/// Snapshot returned by [LocalEngineHealthMonitor].
class LocalEngineHealth {
  const LocalEngineHealth({
    required this.status,
    required this.checkedAt,
    this.version,
    this.error,
    this.loadedModels = const <String>[],
  });

  final LocalEngineHealthStatus status;
  final DateTime checkedAt;
  final String? version;
  final String? error;
  final List<String> loadedModels;

  bool get isOnline => status == LocalEngineHealthStatus.online;
  bool get isOffline => status == LocalEngineHealthStatus.offline;
  bool get isLoading => status == LocalEngineHealthStatus.loading;
  bool get isLoadingModel => status == LocalEngineHealthStatus.loadingModel;

  /// True when the engine is reachable in any form (model loaded or
  /// warming). Convenience for callers that just want a "green light".
  bool get isReachable => isOnline || isLoadingModel;
}

/// Periodically pings a local AI engine and reports its health.
/// Designed to back a "status pill" in the AI surfaces.
///
/// The probe is two-tier:
///   1. **Ollama native API** (`/api/version` + `/api/ps`) — gives us
///      the engine version *and* the list of warm models, so the UI can
///      show "Online · gemma3" or "Loading model…" when the engine is
///      up but no model is in RAM yet.
///   2. **OpenAI-compatible fallback** (`/v1/models`) — used for engines
///      that don't speak Ollama (LM Studio, llama.cpp server, Jan,
///      vLLM, etc.). When this succeeds we report `online`; we do not
///      report `loadingModel` here because OpenAI-compat APIs don't
///      expose a "warm vs cold" model list.
///
/// Construction does **not** start ticking. Call [watch] to subscribe.
/// All listeners share a single timer; the timer stops when no
/// listeners remain (via stream controller `onCancel`).
class LocalEngineHealthMonitor {
  LocalEngineHealthMonitor({
    required this.endpoint,
    Duration interval = const Duration(seconds: 15),
    Duration probeTimeout = const Duration(seconds: 3),
    OllamaClient? client,
    HttpClient Function()? httpClientFactory,
  })  : _interval = interval,
        _probeTimeout = probeTimeout,
        _client = client ?? OllamaClient(endpoint: endpoint),
        _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Base URL of the engine, with no trailing slash. Used both to issue
  /// the OpenAI-compat fallback probe and to label error messages.
  final String endpoint;
  final Duration _interval;
  final Duration _probeTimeout;
  final OllamaClient _client;
  final HttpClient Function() _httpClientFactory;

  Timer? _timer;
  StreamController<LocalEngineHealth>? _controller;
  LocalEngineHealth? _last;
  Future<LocalEngineHealth>? _inflight;

  /// Most recent observation, or `null` until the first probe completes.
  LocalEngineHealth? get last => _last;

  /// Subscribe for periodic health snapshots. The first event is a
  /// `loading` placeholder (so the pill can render immediately),
  /// followed by an immediate probe and then one probe per [_interval].
  Stream<LocalEngineHealth> watch() {
    _controller ??= StreamController<LocalEngineHealth>.broadcast(
      onListen: _onListen,
      onCancel: _onCancel,
    );
    return _controller!.stream;
  }

  void _onListen() {
    final now = DateTime.now();
    final loading = LocalEngineHealth(
      status: LocalEngineHealthStatus.loading,
      checkedAt: now,
    );
    _last = loading;
    _controller?.add(loading);
    unawaited(_runProbe());
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => unawaited(_runProbe()));
  }

  void _onCancel() {
    if (_controller?.hasListener ?? false) return;
    _timer?.cancel();
    _timer = null;
  }

  /// Force an out-of-band probe. Useful for "Retry" buttons. Returns
  /// the snapshot it produced. If a probe is already in flight (e.g.
  /// the periodic timer just fired), the caller piggy-backs on that
  /// future instead of stacking a second concurrent probe.
  Future<LocalEngineHealth> probeNow() => _runProbe();

  Future<LocalEngineHealth> _runProbe() {
    final existing = _inflight;
    if (existing != null) return existing;
    final future = _doProbe();
    _inflight = future;
    return future.whenComplete(() {
      if (identical(_inflight, future)) _inflight = null;
    });
  }

  Future<LocalEngineHealth> _doProbe() async {
    LocalEngineHealth result;
    try {
      // Tier 1: native Ollama probe.
      final version = await _client.version();
      List<String> loaded = const [];
      try {
        final loadedModels = await _client.listLoadedModels();
        loaded = loadedModels.map((m) => m.name).toList(growable: false);
      } catch (_) {
        // /api/ps can fail on stripped-down builds; not fatal — we
        // still consider the engine "online" because /api/version
        // responded. We just won't show a model name in the pill.
      }
      // If the engine is up but no model is currently loaded, surface
      // that as an explicit "warming up" state so the pill can render
      // amber "Loading model…" instead of green "Online".
      final status = loaded.isEmpty
          ? LocalEngineHealthStatus.loadingModel
          : LocalEngineHealthStatus.online;
      result = LocalEngineHealth(
        status: status,
        version: version,
        loadedModels: loaded,
        checkedAt: DateTime.now(),
      );
    } on OllamaUnavailableException catch (e) {
      // Tier 2: OpenAI-compatible fallback (LM Studio, llama.cpp, Jan).
      final compat = await _probeOpenAiCompat();
      if (compat != null) {
        result = compat;
      } else {
        result = LocalEngineHealth(
          status: LocalEngineHealthStatus.offline,
          error: e.message,
          checkedAt: DateTime.now(),
        );
      }
    } catch (e) {
      final compat = await _probeOpenAiCompat();
      if (compat != null) {
        result = compat;
      } else {
        result = LocalEngineHealth(
          status: LocalEngineHealthStatus.offline,
          error: e.toString(),
          checkedAt: DateTime.now(),
        );
      }
    }
    _last = result;
    if (!(_controller?.isClosed ?? true)) {
      _controller?.add(result);
    }
    return result;
  }

  /// Probe the OpenAI-compatible `/v1/models` endpoint. Returns a
  /// snapshot when the engine answers, or `null` when nothing is
  /// listening / the request times out.
  ///
  /// We only mark the engine `online` here; OpenAI-compat servers do
  /// not expose a "warm models" list, so we cannot distinguish
  /// `online` from `loadingModel`. We do try to surface the first
  /// model id in [LocalEngineHealth.loadedModels] so the pill can
  /// still render "Online · {model}" when that data is available.
  Future<LocalEngineHealth?> _probeOpenAiCompat() async {
    final client = _httpClientFactory();
    client.connectionTimeout = _probeTimeout;
    try {
      final req = await client
          .getUrl(Uri.parse('$endpoint/v1/models'))
          .timeout(_probeTimeout);
      final resp = await req.close().timeout(_probeTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      List<String> models = const [];
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          final data = decoded['data'];
          if (data is List) {
            models = data
                .whereType<Map<String, dynamic>>()
                .map((m) => (m['id'] as String?)?.trim() ?? '')
                .where((id) => id.isNotEmpty)
                .toList(growable: false);
          }
        }
      } catch (_) {
        // Body wasn't JSON / wasn't OpenAI-shaped — that's still proof
        // the port is open and serving HTTP, so we treat it as online.
      }
      return LocalEngineHealth(
        status: LocalEngineHealthStatus.online,
        loadedModels: models,
        checkedAt: DateTime.now(),
      );
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Tear down the timer and close the broadcast stream. Safe to call
  /// multiple times.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) {
      await c.close();
    }
  }
}
