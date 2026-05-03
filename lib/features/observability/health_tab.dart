import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/observability/metric_poller.dart';
import '../../core/observability/metric_snapshot.dart';
import '../../core/observability/observability_explainer.dart';
import '../../core/observability/rolling_buffer.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/storage/api_key_storage.dart';
import '../../core/theme/app_colors.dart';
import '../logs/widgets/watch_with_ai_screen.dart';
import 'metric_chart_screen.dart';
import 'widgets/explanation_card.dart';
import 'widgets/metric_tile.dart';

/// Per-server **Health** tab — agentless metric grid with sparklines,
/// anomaly callouts, expandable charts, and one-tap "EXPLAIN" through
/// the local LLM.
class HealthTab extends StatefulWidget {
  const HealthTab({
    super.key,
    required this.sshService,
    required this.serverName,
    required this.aiSettings,
    this.poller,
  });

  final SshService sshService;
  final String serverName;
  final AiSettings aiSettings;

  /// Override for tests. Production path constructs one bound to
  /// [sshService.execute].
  final MetricPoller? poller;

  @override
  State<HealthTab> createState() => _HealthTabState();
}

class _HealthTabState extends State<HealthTab> {
  late final MetricPoller _poller;
  StreamSubscription<MetricSnapshot>? _sub;

  MetricSnapshot? _latest;
  HostCapabilities? _caps;
  String? _error;
  bool _booting = true;

  static const List<int> _intervalChoices = [2, 5, 10, 30];
  int _intervalSeconds = 5;

  // One buffer per surfaced metric. Disk uses a map keyed by mount.
  final RollingBuffer _cpuBuf = RollingBuffer();
  final RollingBuffer _memBuf = RollingBuffer();
  final RollingBuffer _loadBuf = RollingBuffer();
  final Map<String, RollingBuffer> _diskBufs = {};
  final Map<String, RollingBuffer> _netRxBufs = {};
  final Map<String, RollingBuffer> _netTxBufs = {};

  // Anomaly state per metric key, refreshed on every push.
  final Map<String, bool> _anomaly = {};

  // Active explanation cards keyed by metric id.
  final Map<String, ExplanationResult> _explanations = {};
  final Set<String> _explainingNow = {};

  @override
  void initState() {
    super.initState();
    _poller = widget.poller ??
        MetricPoller(exec: (cmd) => widget.sshService.execute(cmd));
    _intervalSeconds = _poller.interval.inSeconds.clamp(2, 30);
    _start();
  }

  Future<void> _start() async {
    try {
      _caps = await _poller.detectCapabilities();
      if (!mounted) return;
      setState(() => _booting = false);
      if (!_caps!.any) return;
      _sub = _poller.watch().listen(_onSnapshot, onError: (Object e, _) {
        if (!mounted) return;
        setState(() => _error = e.toString());
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _error = e.toString();
      });
    }
  }

  void _onSnapshot(MetricSnapshot snap) {
    if (!mounted) return;
    setState(() {
      _latest = snap;
      _error = null;

      if (snap.cpu != null) {
        _anomaly['cpu'] =
            _cpuBuf.push(snap.timestamp, snap.cpu!.usagePercent).anomalous;
      }
      if (snap.memory != null) {
        _anomaly['mem'] =
            _memBuf.push(snap.timestamp, snap.memory!.usagePercent).anomalous;
      }
      if (snap.load != null) {
        _anomaly['load'] =
            _loadBuf.push(snap.timestamp, snap.load!.oneMinute).anomalous;
      }
      // Track the live keys so transient mounts / interfaces (think
      // Docker volumes, bond-up-down events on K8s nodes) don't leak
      // ring buffers forever — anything not present this round is
      // dropped from the per-key maps below.
      final liveDisks = <String>{};
      final liveIfs = <String>{};
      for (final d in snap.disks) {
        liveDisks.add(d.mountPoint);
        final buf = _diskBufs.putIfAbsent(d.mountPoint, RollingBuffer.new);
        // Disk fills slowly; z-score baseline rarely fires meaningfully
        // and would be noisy on logrotate cycles. We track the trend
        // for the sparkline but suppress the anomaly badge on disk.
        buf.push(snap.timestamp, d.usagePercent);
        _anomaly['disk:${d.mountPoint}'] = false;
      }
      for (final n in snap.network) {
        liveIfs.add(n.name);
        final rx = _netRxBufs.putIfAbsent(n.name, RollingBuffer.new);
        final tx = _netTxBufs.putIfAbsent(n.name, RollingBuffer.new);
        final rxAnom = rx.push(snap.timestamp, n.rxBytesPerSecond).anomalous;
        final txAnom = tx.push(snap.timestamp, n.txBytesPerSecond).anomalous;
        _anomaly['net:${n.name}'] = rxAnom || txAnom;
      }
      _diskBufs.removeWhere((k, _) => !liveDisks.contains(k));
      _netRxBufs.removeWhere((k, _) => !liveIfs.contains(k));
      _netTxBufs.removeWhere((k, _) => !liveIfs.contains(k));
      _anomaly.removeWhere((k, _) {
        if (k.startsWith('disk:')) {
          return !liveDisks.contains(k.substring('disk:'.length));
        }
        if (k.startsWith('net:')) {
          return !liveIfs.contains(k.substring('net:'.length));
        }
        return false;
      });
    });
  }

  Future<void> _explain({
    required String key,
    required String displayName,
    required RollingBuffer buffer,
    required String unit,
  }) async {
    if (widget.aiSettings.provider != AiProvider.local) {
      _toast('Local AI required to use Explain.');
      return;
    }
    if (_explainingNow.contains(key)) return;
    setState(() => _explainingNow.add(key));
    try {
      final ai = AiCommandService.forProvider(
        provider: AiProvider.local,
        apiKey: '',
        localEndpoint: widget.aiSettings.localEndpoint,
        localModel: widget.aiSettings.localModel,
      );
      final explainer = ObservabilityExplainer(
        ai: ai,
        provider: AiProvider.local,
        sshService: widget.sshService,
      );
      final result = await explainer.explain(
        metricName: displayName,
        buffer: buffer,
        unit: unit,
        capabilities: _caps,
      );
      if (!mounted) return;
      setState(() => _explanations[key] = result);
    } catch (e) {
      if (!mounted) return;
      _toast('Explain failed: $e');
    } finally {
      if (mounted) setState(() => _explainingNow.remove(key));
    }
  }

  void _watch(String command, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchWithAiScreen(
          sshService: widget.sshService,
          command: command,
          title: title,
          aiSettings: widget.aiSettings,
        ),
      ),
    );
  }

  void _expand({
    required String title,
    required String unit,
    required RollingBuffer buffer,
    double? yMax,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetricChartScreen(
          title: title,
          unit: unit,
          samples: buffer.samples
              .map((s) => (t: s.t, v: s.v))
              .toList(growable: false),
          yMax: yMax,
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _setInterval(int seconds) {
    if (seconds == _intervalSeconds) return;
    try {
      _poller.setInterval(Duration(seconds: seconds));
      setState(() => _intervalSeconds = seconds);
    } on ArgumentError catch (e) {
      _toast('Bad interval: ${e.message}');
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final caps = _caps;
    if (caps == null || !caps.any) {
      return _Banner(
        icon: Icons.block,
        color: AppColors.textMuted,
        title: 'METRIC TOOLS NOT AVAILABLE',
        body:
            'None of top, free, df, /proc/net/dev or /proc/loadavg were found '
            'on this host. Install one of those, then reopen the Health tab.',
      );
    }

    final isLocal = widget.aiSettings.provider == AiProvider.local;
    final activeAnomalies = _activeAnomalyLabels();

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverToBoxAdapter(child: _header(isLocal)),
        ),
        if (activeAnomalies.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverToBoxAdapter(
              child: _Banner(
                icon: Icons.warning_amber_rounded,
                color: AppColors.danger,
                title: 'ANOMALY DETECTED',
                body:
                    '${activeAnomalies.join(", ")} crossed the z-score '
                    'threshold. Tap EXPLAIN on the affected tile to ask the '
                    'local AI for a likely cause.',
              ),
            ),
          ),
        if (_error != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverToBoxAdapter(
              child: _Banner(
                icon: Icons.warning_amber_rounded,
                color: AppColors.danger,
                title: 'POLL ERROR',
                body: _error!,
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 320,
              mainAxisExtent: 200,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            delegate: SliverChildListDelegate(_buildTiles(isLocal)),
          ),
        ),
        if (_explanations.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            sliver: SliverList.list(
              children: [
                for (final entry in _explanations.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: ExplanationCard(
                      result: entry.value,
                      metricName: entry.key,
                      onClose: () =>
                          setState(() => _explanations.remove(entry.key)),
                    ),
                  ),
              ],
            ),
          ),
        if (_latest != null &&
            (_latest!.topByCpu.isNotEmpty || _latest!.topByMemory.isNotEmpty))
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            sliver: SliverToBoxAdapter(child: _processLists(_latest!)),
          ),
      ],
    );
  }

  List<String> _activeAnomalyLabels() {
    final out = <String>[];
    if (_anomaly['cpu'] == true) out.add('CPU');
    if (_anomaly['mem'] == true) out.add('Memory');
    if (_anomaly['load'] == true) out.add('Load');
    for (final entry in _anomaly.entries) {
      if (entry.value && entry.key.startsWith('net:')) {
        out.add('Network ${entry.key.substring(4)}');
      }
    }
    return out;
  }

  Widget _header(bool isLocal) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 6,
      children: [
        const Text(
          'HEALTH',
          style: TextStyle(
            color: AppColors.textPrimary,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(
              color: isLocal ? AppColors.accent : AppColors.textMuted,
            ),
          ),
          child: Text(
            isLocal ? 'LOCAL AI ON' : 'LOCAL AI REQUIRED FOR EXPLAIN',
            style: TextStyle(
              color: isLocal ? AppColors.accent : AppColors.textMuted,
              fontSize: 9,
              letterSpacing: 1.4,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _intervalSelector(),
        if (_latest?.timestamp != null)
          Text(
            'LAST ${_fmt(_latest!.timestamp)}',
            style: const TextStyle(
              color: AppColors.textFaint,
              fontSize: 10,
              letterSpacing: 1.4,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
            ),
          ),
      ],
    );
  }

  Widget _intervalSelector() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'POLL ',
          style: TextStyle(
            color: AppColors.textFaint,
            fontSize: 10,
            letterSpacing: 1.4,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
        ),
        for (final s in _intervalChoices)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: InkWell(
              onTap: () => _setInterval(s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: s == _intervalSeconds
                        ? AppColors.textPrimary
                        : AppColors.border,
                  ),
                  color: s == _intervalSeconds
                      ? AppColors.textPrimary
                      : Colors.transparent,
                ),
                child: Text(
                  '${s}S',
                  style: TextStyle(
                    color: s == _intervalSeconds
                        ? AppColors.scaffoldBackground
                        : AppColors.textMuted,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Choose a metric-aware command for WATCH WITH AI so the user
  /// lands on logs / live output that's actually relevant to the
  /// spike, not a generic journal tail. Each command is read-only;
  /// `WatchWithAiScreen` re-runs the local-AI guard before sending.
  String _watchCommandFor(String key, {String? mountPoint, String? iface}) {
    switch (key) {
      case 'cpu':
        return 'top -b -d 2';
      case 'mem':
        // `top -o %MEM` re-sorts the live view by memory consumption.
        return 'top -b -d 2 -o %MEM';
      case 'load':
        return 'uptime; ps -eo pid,user,pri,ni,pcpu,pmem,stat,comm '
            '--sort=-pcpu | head';
      default:
        if (key.startsWith('disk:') && mountPoint != null) {
          // Most-recent file growth on the affected mount, refreshed.
          return "find '$mountPoint' -xdev -type f -printf "
              "'%T@ %s %p\\n' 2>/dev/null | sort -nr | head -n 30";
        }
        if (key.startsWith('net:') && iface != null) {
          // Per-socket bytes — works on systemd + busybox boxes.
          return "ss -tunp 2>/dev/null | head -n 30; "
              "echo '---'; ip -s link show $iface 2>/dev/null";
        }
        return 'journalctl -f -n 50';
    }
  }

  String _watchTitleFor(String key, {String? mountPoint, String? iface}) {
    switch (key) {
      case 'cpu':
        return 'top (CPU)';
      case 'mem':
        return 'top (memory)';
      case 'load':
        return 'load + top processes';
      default:
        if (key.startsWith('disk:')) return 'disk: ${mountPoint ?? "?"}';
        if (key.startsWith('net:')) return 'net: ${iface ?? "?"}';
        return 'journalctl';
    }
  }

  List<Widget> _buildTiles(bool isLocal) {
    final tiles = <Widget>[];
    final snap = _latest;
    final caps = _caps!;

    if (caps.hasTop) {
      final cpu = snap?.cpu;
      tiles.add(MetricTile(
        label: 'CPU',
        value: cpu != null ? cpu.usagePercent.toStringAsFixed(1) : '—',
        unit: '%',
        history: _cpuBuf.samples.map((s) => s.v).toList(),
        anomalous: _anomaly['cpu'] == true,
        yMax: 100,
        explainBusy: _explainingNow.contains('cpu'),
        onExpand: _cpuBuf.samples.length >= 2
            ? () => _expand(
                  title: 'CPU',
                  unit: '%',
                  buffer: _cpuBuf,
                  yMax: 100,
                )
            : null,
        onExplain: isLocal
            ? () => _explain(
                  key: 'cpu',
                  displayName: 'CPU usage',
                  buffer: _cpuBuf,
                  unit: '%',
                )
            : null,
        onWatch: () => _watch(
          _watchCommandFor('cpu'),
          _watchTitleFor('cpu'),
        ),
      ));
    }
    if (caps.hasFree) {
      final mem = snap?.memory;
      tiles.add(MetricTile(
        label: 'MEMORY',
        value: mem != null ? mem.usagePercent.toStringAsFixed(1) : '—',
        unit: '%',
        subtitle: mem != null
            ? '${_bytes(mem.usedBytes)} / ${_bytes(mem.totalBytes)}'
            : null,
        history: _memBuf.samples.map((s) => s.v).toList(),
        anomalous: _anomaly['mem'] == true,
        yMax: 100,
        explainBusy: _explainingNow.contains('mem'),
        onExpand: _memBuf.samples.length >= 2
            ? () => _expand(
                  title: 'Memory',
                  unit: '%',
                  buffer: _memBuf,
                  yMax: 100,
                )
            : null,
        onExplain: isLocal
            ? () => _explain(
                  key: 'mem',
                  displayName: 'Memory usage',
                  buffer: _memBuf,
                  unit: '%',
                )
            : null,
        onWatch: () => _watch(
          _watchCommandFor('mem'),
          _watchTitleFor('mem'),
        ),
      ));
    }
    if (caps.hasProcLoadavg) {
      final load = snap?.load;
      tiles.add(MetricTile(
        label: 'LOAD 1m',
        value: load != null ? load.oneMinute.toStringAsFixed(2) : '—',
        unit: '',
        subtitle: load != null
            ? '5m ${load.fiveMinute.toStringAsFixed(2)}  '
                '15m ${load.fifteenMinute.toStringAsFixed(2)}'
            : null,
        history: _loadBuf.samples.map((s) => s.v).toList(),
        anomalous: _anomaly['load'] == true,
        explainBusy: _explainingNow.contains('load'),
        onExpand: _loadBuf.samples.length >= 2
            ? () => _expand(title: 'Load 1m', unit: 'load', buffer: _loadBuf)
            : null,
        onExplain: isLocal
            ? () => _explain(
                  key: 'load',
                  displayName: '1-minute load average',
                  buffer: _loadBuf,
                  unit: 'load',
                )
            : null,
        onWatch: () => _watch(
          _watchCommandFor('load'),
          _watchTitleFor('load'),
        ),
      ));
    }
    if (caps.hasDf) {
      for (final disk in snap?.disks ?? const <DiskMount>[]) {
        final buf = _diskBufs[disk.mountPoint];
        final key = 'disk:${disk.mountPoint}';
        tiles.add(MetricTile(
          label: 'DISK ${disk.mountPoint}',
          value: disk.usagePercent.toStringAsFixed(1),
          unit: '%',
          subtitle:
              '${_bytes(disk.usedBytes)} / ${_bytes(disk.totalBytes)}',
          history: buf?.samples.map((s) => s.v).toList() ?? const [],
          anomalous: false,
          yMax: 100,
          onExpand: (buf != null && buf.samples.length >= 2)
              ? () => _expand(
                    title: 'Disk ${disk.mountPoint}',
                    unit: '%',
                    buffer: buf,
                    yMax: 100,
                  )
              : null,
          onWatch: () => _watch(
            _watchCommandFor(key, mountPoint: disk.mountPoint),
            _watchTitleFor(key, mountPoint: disk.mountPoint),
          ),
        ));
      }
    }
    if (caps.hasProcNetDev) {
      for (final net in snap?.network ?? const <NetInterfaceSample>[]) {
        final rx = _netRxBufs[net.name];
        final key = 'net:${net.name}';
        tiles.add(MetricTile(
          label: 'NET ${net.name}',
          value: _bytesPerSec(net.rxBytesPerSecond + net.txBytesPerSecond),
          unit: '/s',
          subtitle:
              'RX ${_bytesPerSec(net.rxBytesPerSecond)}/s  '
              'TX ${_bytesPerSec(net.txBytesPerSecond)}/s',
          history: rx?.samples.map((s) => s.v).toList() ?? const [],
          anomalous: _anomaly[key] == true,
          explainBusy: _explainingNow.contains(key),
          onExpand: (rx != null && rx.samples.length >= 2)
              ? () => _expand(
                    title: 'Net RX ${net.name}',
                    unit: 'B/s',
                    buffer: rx,
                  )
              : null,
          onExplain: isLocal && rx != null
              ? () => _explain(
                    key: key,
                    displayName: 'Network RX on ${net.name}',
                    buffer: rx,
                    unit: 'bytes/s',
                  )
              : null,
          onWatch: () => _watch(
            _watchCommandFor(key, iface: net.name),
            _watchTitleFor(key, iface: net.name),
          ),
        ));
      }
    }
    return tiles;
  }

  Widget _processLists(MetricSnapshot snap) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (snap.topByCpu.isNotEmpty)
          Expanded(child: _processList('TOP PROCESSES BY CPU',
              snap.topByCpu, _ProcessSortKey.cpu)),
        if (snap.topByCpu.isNotEmpty && snap.topByMemory.isNotEmpty)
          const SizedBox(width: 10),
        if (snap.topByMemory.isNotEmpty)
          Expanded(child: _processList('TOP PROCESSES BY RAM',
              snap.topByMemory, _ProcessSortKey.mem)),
      ],
    );
  }

  Widget _processList(
    String title,
    List<ProcessSample> rows,
    _ProcessSortKey sortKey,
  ) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        color: AppColors.surface,
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textMuted,
              letterSpacing: 1.4,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
            ),
          ),
          const SizedBox(height: 8),
          for (final p in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      sortKey == _ProcessSortKey.cpu
                          ? '${p.cpuPercent.toStringAsFixed(1)}%'
                          : '${p.memPercent.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: Text(
                      'PID ${p.pid}',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      p.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _bytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  static String _bytesPerSec(double bps) => _bytes(bps.round());
}

enum _ProcessSortKey { cpu, mem }

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: color),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
