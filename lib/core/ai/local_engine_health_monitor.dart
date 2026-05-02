import 'dart:async';

import 'ollama_client.dart';

/// Three coarse health states the UI cares about.
enum LocalEngineHealthStatus {
  /// We have not yet contacted the engine on this monitor instance.
  loading,

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
}

/// Periodically pings a local OpenAI-compatible engine and reports its
/// health. Designed to back a "status pill" in the AI surfaces.
///
/// Currently uses the native Ollama API (`/api/version` + `/api/ps`)
/// because that is the only engine for which we have a typed client.
/// Other OpenAI-compat engines (LM Studio, llama.cpp, Jan) still report
/// as offline through this monitor — the pill UI degrades gracefully.
///
/// Construction does **not** start ticking. Call [watch] to subscribe.
/// All listeners share a single timer; the timer stops when no listeners
/// remain (via stream controller `onCancel`).
class LocalEngineHealthMonitor {
  LocalEngineHealthMonitor({
    required this.endpoint,
    Duration interval = const Duration(seconds: 15),
    OllamaClient? client,
  })  : _interval = interval,
        _client = client ?? OllamaClient(endpoint: endpoint);

  /// Base URL of the engine, with no trailing slash. Used only for display
  /// in error messages — the actual probes go through [_client].
  final String endpoint;
  final Duration _interval;
  final OllamaClient _client;

  Timer? _timer;
  StreamController<LocalEngineHealth>? _controller;
  LocalEngineHealth? _last;
  Future<LocalEngineHealth>? _inflight;

  /// Most recent observation, or `null` until the first probe completes.
  LocalEngineHealth? get last => _last;

  /// Subscribe for periodic health snapshots. The first event is a
  /// `loading` placeholder (so the pill can render immediately), followed
  /// by an immediate probe and then one probe per [_interval].
  Stream<LocalEngineHealth> watch() {
    _controller ??= StreamController<LocalEngineHealth>.broadcast(
      onListen: _onListen,
      onCancel: _onCancel,
    );
    return _controller!.stream;
  }

  void _onListen() {
    // Emit a loading event right away so the pill never renders blank,
    // then run an initial probe immediately rather than waiting a full
    // interval.
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

  /// Force an out-of-band probe. Useful for "Retry" buttons. Returns the
  /// snapshot it produced. If a probe is already in flight (e.g. the
  /// periodic timer just fired), the caller piggy-backs on that future
  /// instead of stacking a second concurrent probe.
  Future<LocalEngineHealth> probeNow() {
    return _runProbe();
  }

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
      final version = await _client.version();
      List<String> loaded = const [];
      try {
        final loadedModels = await _client.listLoadedModels();
        loaded = loadedModels.map((m) => m.name).toList(growable: false);
      } catch (_) {
        // listLoadedModels can fail on engines that aren't Ollama; that's
        // not a hard error — we still consider the engine "online" if
        // /api/version responded.
      }
      result = LocalEngineHealth(
        status: LocalEngineHealthStatus.online,
        version: version,
        loadedModels: loaded,
        checkedAt: DateTime.now(),
      );
    } on OllamaUnavailableException catch (e) {
      result = LocalEngineHealth(
        status: LocalEngineHealthStatus.offline,
        error: e.message,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      result = LocalEngineHealth(
        status: LocalEngineHealthStatus.offline,
        error: e.toString(),
        checkedAt: DateTime.now(),
      );
    }
    _last = result;
    if (!(_controller?.isClosed ?? true)) {
      _controller?.add(result);
    }
    return result;
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
