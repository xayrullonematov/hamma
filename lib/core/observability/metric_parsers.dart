import 'metric_snapshot.dart';

/// Pure functions parsing the stdout of standard Linux tools into the
/// typed models in [metric_snapshot.dart]. Kept side-effect-free so
/// the parsers are exhaustively unit-testable against captured
/// fixtures.

class MetricParsers {
  /// Parse `top -b -n1` output. Reads the `%Cpu(s):` aggregate line
  /// and the per-process table that follows the COMMAND header.
  ///
  /// Returns ([CpuSample]?, top-N processes by the order top emitted).
  /// On unknown formats both are null/empty rather than throwing —
  /// the poller will simply skip those tiles for one round.
  static (CpuSample?, List<ProcessSample>) parseTop(String stdout, {int top = 5}) {
    CpuSample? cpu;
    final processes = <ProcessSample>[];
    final lines = const LineSplitter().split(stdout);

    for (final line in lines) {
      final t = line.trim();
      if (cpu == null &&
          (t.startsWith('%Cpu(s):') ||
              t.startsWith('Cpu(s):') ||
              t.startsWith('CPU:'))) {
        cpu = _parseTopCpuLine(t);
      }
    }

    final headerIndex = lines.indexWhere(
      (l) => l.contains('PID') && l.contains('COMMAND'),
    );
    if (headerIndex >= 0) {
      final cols = _topColumnIndex(lines[headerIndex]);
      for (var i = headerIndex + 1; i < lines.length; i++) {
        final p = _parseTopProcessLine(lines[i], cols);
        if (p != null) processes.add(p);
        if (processes.length >= top) break;
      }
    }
    return (cpu, processes);
  }

  /// Maps header column names ("PID", "USER", "%CPU", "%MEM", "COMMAND")
  /// to their token index. `top` versions vary wildly in column counts
  /// (NI, VIRT, SHR, S may or may not be present), so we never
  /// hard-code offsets — we read positions off the live header.
  static Map<String, int> _topColumnIndex(String headerLine) {
    final tokens = headerLine.trim().split(RegExp(r'\s+'));
    final map = <String, int>{};
    for (var i = 0; i < tokens.length; i++) {
      map[tokens[i].toUpperCase()] = i;
    }
    return map;
  }

  static CpuSample? _parseTopCpuLine(String line) {
    // Examples:
    //  %Cpu(s):  3.2 us,  1.1 sy,  0.0 ni, 95.4 id,  0.2 wa,  0.0 hi, ...
    //  Cpu(s): 12.5%us,  3.1%sy,  0.0%ni, 84.0%id, ...
    final idleRe = RegExp(r'(\d+(?:\.\d+)?)\s*%?\s*id(?:le)?\b');
    final m = idleRe.firstMatch(line);
    if (m == null) return null;
    final idle = double.tryParse(m.group(1)!);
    if (idle == null) return null;
    final usage = (100.0 - idle).clamp(0.0, 100.0);
    return CpuSample(usagePercent: usage);
  }

  static ProcessSample? _parseTopProcessLine(
    String line,
    Map<String, int> cols,
  ) {
    final parts = line.trim().split(RegExp(r'\s+'));
    final pidIdx = cols['PID'];
    final userIdx = cols['USER'];
    final cpuIdx = cols['%CPU'];
    final memIdx = cols['%MEM'];
    final cmdIdx = cols['COMMAND'];
    if (pidIdx == null || cpuIdx == null || memIdx == null || cmdIdx == null) {
      return null;
    }
    if (parts.length <= cmdIdx) return null;
    final pid = int.tryParse(parts[pidIdx]);
    final cpu = double.tryParse(parts[cpuIdx]);
    final mem = double.tryParse(parts[memIdx]);
    if (pid == null || cpu == null || mem == null) return null;
    final user = (userIdx != null && parts.length > userIdx)
        ? parts[userIdx]
        : '';
    final command = parts.sublist(cmdIdx).join(' ');
    return ProcessSample(
      pid: pid,
      user: user,
      command: command,
      cpuPercent: cpu,
      memPercent: mem,
    );
  }

  /// Parse `free -k` output. Uses the `Mem:` row's total + used columns.
  static MemorySample? parseFree(String stdout) {
    for (final line in const LineSplitter().split(stdout)) {
      final t = line.trim();
      if (!t.startsWith('Mem:')) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 3) return null;
      final total = int.tryParse(parts[1]);
      final used = int.tryParse(parts[2]);
      if (total == null || used == null) return null;
      // free -k reports kilobytes; normalise to bytes.
      return MemorySample(totalBytes: total * 1024, usedBytes: used * 1024);
    }
    return null;
  }

  /// Parse `df -P` (POSIX-portable) output. Yields one [DiskMount] per
  /// row, skipping pseudo filesystems like `tmpfs` / `devtmpfs` which
  /// would clutter the tile.
  static List<DiskMount> parseDf(String stdout) {
    final out = <DiskMount>[];
    final lines = const LineSplitter().split(stdout);
    if (lines.length < 2) return out;
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].trim().split(RegExp(r'\s+'));
      if (parts.length < 6) continue;
      final fs = parts[0];
      if (fs == 'tmpfs' || fs == 'devtmpfs' || fs == 'overlay') continue;
      // df -P columns: Filesystem 1024-blocks Used Available Capacity Mounted
      final blocks = int.tryParse(parts[1]);
      final used = int.tryParse(parts[2]);
      if (blocks == null || used == null) continue;
      final mount = parts.sublist(5).join(' ');
      out.add(DiskMount(
        mountPoint: mount,
        totalBytes: blocks * 1024,
        usedBytes: used * 1024,
      ));
    }
    return out;
  }

  /// Parse /proc/net/dev cumulative byte counters. Returned as a map
  /// of `iface -> (rxBytes, txBytes)` so the poller can subtract the
  /// previous reading to get a per-second rate.
  static Map<String, (int rx, int tx)> parseProcNetDev(String stdout) {
    final out = <String, (int, int)>{};
    final lines = const LineSplitter().split(stdout);
    for (final line in lines) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).trim();
      if (name == 'Inter-' || name == 'face' || name.isEmpty) continue;
      if (name == 'lo') continue; // loopback noise
      final parts = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
      if (parts.length < 9) continue;
      final rx = int.tryParse(parts[0]);
      final tx = int.tryParse(parts[8]);
      if (rx == null || tx == null) continue;
      out[name] = (rx, tx);
    }
    return out;
  }

  /// Compute byte-per-second rates from two raw /proc/net/dev snapshots.
  static List<NetInterfaceSample> netRate({
    required Map<String, (int rx, int tx)> previous,
    required Map<String, (int rx, int tx)> current,
    required Duration interval,
  }) {
    final secs = interval.inMilliseconds / 1000.0;
    if (secs <= 0) return const [];
    final out = <NetInterfaceSample>[];
    for (final entry in current.entries) {
      final prev = previous[entry.key];
      if (prev == null) continue;
      final dRx = (entry.value.$1 - prev.$1).clamp(0, 1 << 62);
      final dTx = (entry.value.$2 - prev.$2).clamp(0, 1 << 62);
      out.add(NetInterfaceSample(
        name: entry.key,
        rxBytesPerSecond: dRx / secs,
        txBytesPerSecond: dTx / secs,
      ));
    }
    return out;
  }

  /// Parse /proc/loadavg.
  static LoadSample? parseLoadavg(String stdout) {
    final t = stdout.trim();
    if (t.isEmpty) return null;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 3) return null;
    final one = double.tryParse(parts[0]);
    final five = double.tryParse(parts[1]);
    final fifteen = double.tryParse(parts[2]);
    if (one == null || five == null || fifteen == null) return null;
    return LoadSample(
      oneMinute: one,
      fiveMinute: five,
      fifteenMinute: fifteen,
    );
  }
}

class LineSplitter {
  const LineSplitter();
  List<String> split(String s) => s.split(RegExp(r'\r?\n'));
}
