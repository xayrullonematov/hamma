import 'dart:async';

import 'metric_parsers.dart';
import 'metric_snapshot.dart';

/// Function the poller calls to execute a one-shot SSH command and
/// receive its stdout. Modeled as a callback (rather than depending on
/// [SshService] directly) so the poller is fully unit-testable against
/// a fake.
typedef MetricExecCallback = Future<String> Function(String command);

/// Standalone, per-server, agentless metric poller.
///
/// Owns a single periodic SSH command batch — feature-detected on
/// first start so we don't waste round-trips asking for tools that
/// aren't installed. Emits one [MetricSnapshot] per tick; bad rounds
/// are surfaced as `addError` events so the UI can show a banner
/// without tearing down the stream.
class MetricPoller {
  MetricPoller({
    required MetricExecCallback exec,
    Duration interval = const Duration(seconds: 5),
    DateTime Function()? clock,
  })  : _exec = exec,
        _interval = interval,
        _clock = clock ?? DateTime.now;

  final MetricExecCallback _exec;
  Duration _interval;
  final DateTime Function() _clock;

  HostCapabilities? _caps;
  Map<String, (int rx, int tx)> _previousNet = const {};
  DateTime? _previousNetAt;

  Timer? _tickTimer;
  StreamController<MetricSnapshot>? _controller;
  bool _polling = false;
  bool _started = false;

  Duration get interval => _interval;
  HostCapabilities? get capabilities => _caps;

  /// Reconfigure the poll interval. Takes effect on the next tick.
  void setInterval(Duration value) {
    if (value < const Duration(seconds: 2)) {
      throw ArgumentError.value(value, 'interval', 'must be >= 2s');
    }
    if (value > const Duration(seconds: 30)) {
      throw ArgumentError.value(value, 'interval', 'must be <= 30s');
    }
    _interval = value;
    if (_started) {
      _tickTimer?.cancel();
      _scheduleTick();
    }
  }

  /// Probe which tools exist on the host. Cached for the poller's
  /// lifetime; call [resetCapabilities] after a reconnect if you want
  /// to re-detect.
  Future<HostCapabilities> detectCapabilities() async {
    if (_caps != null) return _caps!;
    final probe = await _exec(_capabilityProbe);
    final tokens = probe.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toSet();
    _caps = HostCapabilities(
      hasTop: tokens.contains('TOP'),
      hasFree: tokens.contains('FREE'),
      hasDf: tokens.contains('DF'),
      hasProcNetDev: tokens.contains('NETDEV'),
      hasProcLoadavg: tokens.contains('LOADAVG'),
    );
    return _caps!;
  }

  void resetCapabilities() {
    _caps = null;
    _previousNet = const {};
    _previousNetAt = null;
  }

  /// Subscribe to the snapshot stream. Polling starts on first listen
  /// and stops when the last subscriber cancels.
  Stream<MetricSnapshot> watch() {
    final controller = StreamController<MetricSnapshot>(
      onListen: _onListen,
      onCancel: _onCancel,
      onPause: () => _tickTimer?.cancel(),
      onResume: _scheduleTick,
    );
    _controller = controller;
    return controller.stream;
  }

  Future<void> _onListen() async {
    _started = true;
    try {
      await detectCapabilities();
    } catch (e, st) {
      _controller?.addError(e, st);
    }
    // Fire one immediate poll so the UI has data to render right
    // away rather than waiting a full interval.
    unawaited(_pollOnce());
    _scheduleTick();
  }

  Future<void> _onCancel() async {
    _started = false;
    _tickTimer?.cancel();
    _tickTimer = null;
    await _controller?.close();
    _controller = null;
  }

  void _scheduleTick() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(_interval, (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (_polling) return; // skip overlap; previous poll still in flight
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    _polling = true;
    try {
      final caps = _caps ?? await detectCapabilities();
      if (!caps.any) return;

      final cmd = _buildBatch(caps);
      final raw = await _exec(cmd);
      final sections = _splitSections(raw);
      final now = _clock();

      CpuSample? cpu;
      List<ProcessSample> topByCpu = const [];
      List<ProcessSample> topByMem = const [];
      if (caps.hasTop && sections.containsKey('CPU')) {
        final (cpuSample, procs) =
            MetricParsers.parseTop(sections['CPU']!, top: 30);
        cpu = cpuSample;
        topByCpu = procs.length > 5 ? procs.sublist(0, 5) : procs;
        // Order the wider sample window by mem descending so the
        // by-memory tile actually shows different processes than
        // the by-CPU tile.
        topByMem = [...procs]
          ..sort((a, b) => b.memPercent.compareTo(a.memPercent));
        if (topByMem.length > 5) topByMem = topByMem.sublist(0, 5);
      }

      MemorySample? mem;
      if (caps.hasFree && sections.containsKey('MEM')) {
        mem = MetricParsers.parseFree(sections['MEM']!);
      }

      List<DiskMount> disks = const [];
      if (caps.hasDf && sections.containsKey('DISK')) {
        disks = MetricParsers.parseDf(sections['DISK']!);
      }

      List<NetInterfaceSample> net = const [];
      if (caps.hasProcNetDev && sections.containsKey('NET')) {
        final cur = MetricParsers.parseProcNetDev(sections['NET']!);
        if (_previousNet.isNotEmpty && _previousNetAt != null) {
          net = MetricParsers.netRate(
            previous: _previousNet,
            current: cur,
            interval: now.difference(_previousNetAt ?? now),
          );
        }
        _previousNet = cur;
        _previousNetAt = now;
      }

      LoadSample? load;
      if (caps.hasProcLoadavg && sections.containsKey('LOAD')) {
        load = MetricParsers.parseLoadavg(sections['LOAD']!);
      }

      controller.add(MetricSnapshot(
        timestamp: now,
        cpu: cpu,
        memory: mem,
        disks: disks,
        network: net,
        load: load,
        topByCpu: topByCpu,
        topByMemory: topByMem,
      ));
    } catch (e, st) {
      _controller?.addError(e, st);
    } finally {
      _polling = false;
    }
  }

  /// Probe shell. Echoes a token per tool that's on the PATH or proc
  /// path, so the parser is just a `Set.contains` check. Designed to
  /// succeed on dash / busybox shells (no `[[ ]]`, no arrays).
  static const String _capabilityProbe = '''
command -v top >/dev/null 2>&1 && echo TOP
command -v free >/dev/null 2>&1 && echo FREE
command -v df >/dev/null 2>&1 && echo DF
[ -r /proc/net/dev ] && echo NETDEV
[ -r /proc/loadavg ] && echo LOADAVG
''';

  String _buildBatch(HostCapabilities caps) {
    final buf = StringBuffer();
    void section(String name, String body) {
      buf.writeln('echo "===HAMMA-$name==="');
      buf.writeln(body);
    }
    // We grab a wider top window (30 process rows) so the by-mem
    // sort below has real data to work with — `top` ships the rows
    // pre-sorted by CPU, so without the wider grab the by-RAM tile
    // would just re-shuffle the top CPU consumers.
    if (caps.hasTop) section('CPU', 'top -b -n1 | head -n 40');
    if (caps.hasFree) section('MEM', 'free -k');
    if (caps.hasDf) section('DISK', 'df -P');
    if (caps.hasProcNetDev) section('NET', 'cat /proc/net/dev');
    if (caps.hasProcLoadavg) section('LOAD', 'cat /proc/loadavg');
    return buf.toString();
  }

  static final RegExp _markerRe = RegExp(r'^===HAMMA-([A-Z]+)===\s*$');

  static Map<String, String> _splitSections(String raw) {
    final out = <String, String>{};
    String? current;
    final buffer = <String>[];
    void flush() {
      final key = current;
      if (key != null) {
        out[key] = buffer.join('\n');
      }
      buffer.clear();
    }
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final m = _markerRe.firstMatch(line);
      if (m != null) {
        flush();
        current = m.group(1);
      } else if (current is String) {
        buffer.add(line);
      }
    }
    flush();
    return out;
  }
}
