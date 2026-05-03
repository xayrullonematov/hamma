// Typed models for one round of host-metrics sampling. All values are
// normalised to consistent units so the UI never has to second-guess
// what the source tool emitted: memory/disk in bytes, CPU/disk usage
// in 0..100 percent, network in bytes-per-second deltas, load as the
// raw 1m/5m/15m doubles from /proc/loadavg.

class CpuSample {
  const CpuSample({required this.usagePercent});
  final double usagePercent;
}

class MemorySample {
  const MemorySample({
    required this.totalBytes,
    required this.usedBytes,
  });
  final int totalBytes;
  final int usedBytes;
  double get usagePercent =>
      totalBytes == 0 ? 0 : (usedBytes / totalBytes) * 100.0;
}

class DiskMount {
  const DiskMount({
    required this.mountPoint,
    required this.totalBytes,
    required this.usedBytes,
  });
  final String mountPoint;
  final int totalBytes;
  final int usedBytes;
  double get usagePercent =>
      totalBytes == 0 ? 0 : (usedBytes / totalBytes) * 100.0;
}

class NetInterfaceSample {
  const NetInterfaceSample({
    required this.name,
    required this.rxBytesPerSecond,
    required this.txBytesPerSecond,
  });
  final String name;
  final double rxBytesPerSecond;
  final double txBytesPerSecond;
}

class LoadSample {
  const LoadSample({
    required this.oneMinute,
    required this.fiveMinute,
    required this.fifteenMinute,
  });
  final double oneMinute;
  final double fiveMinute;
  final double fifteenMinute;
}

class ProcessSample {
  const ProcessSample({
    required this.pid,
    required this.user,
    required this.command,
    required this.cpuPercent,
    required this.memPercent,
  });
  final int pid;
  final String user;
  final String command;
  final double cpuPercent;
  final double memPercent;
}

/// One full round of metrics polled at the same instant. Any field
/// can be null if the corresponding tool wasn't available on the box
/// (caught by feature detection at first connect).
class MetricSnapshot {
  const MetricSnapshot({
    required this.timestamp,
    this.cpu,
    this.memory,
    this.disks = const [],
    this.network = const [],
    this.load,
    this.topByCpu = const [],
    this.topByMemory = const [],
  });

  final DateTime timestamp;
  final CpuSample? cpu;
  final MemorySample? memory;
  final List<DiskMount> disks;
  final List<NetInterfaceSample> network;
  final LoadSample? load;
  final List<ProcessSample> topByCpu;
  final List<ProcessSample> topByMemory;
}

/// Per-server feature detection result. Built once on first connect
/// and cached for the lifetime of the SSH session.
class HostCapabilities {
  const HostCapabilities({
    required this.hasTop,
    required this.hasFree,
    required this.hasDf,
    required this.hasProcNetDev,
    required this.hasProcLoadavg,
  });
  final bool hasTop;
  final bool hasFree;
  final bool hasDf;
  final bool hasProcNetDev;
  final bool hasProcLoadavg;

  /// True when at least one metric source is wired up — otherwise the
  /// Health tab renders an "unsupported" banner instead of empty tiles.
  bool get any =>
      hasTop || hasFree || hasDf || hasProcNetDev || hasProcLoadavg;
}
