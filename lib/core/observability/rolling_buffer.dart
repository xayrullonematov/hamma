import 'dart:math' as math;

/// Fixed-capacity ring buffer of `(timestamp, value)` samples per
/// metric. Exposes a z-score-based anomaly score with hysteresis so a
/// single noisy sample doesn't flap the banner.
///
/// Anomaly contract:
///   * `score = (latest - mean) / stddev`, computed over the prior
///     N-1 samples (excluding the latest). This is how `latest` is
///     compared to its own recent history.
///   * Returns NORMAL until the buffer is at least [minSamplesForAnomaly]
///     full — early on, stddev is meaningless.
///   * Hysteresis: once the buffer has flagged anomaly at threshold T,
///     it stays anomalous until the score drops below `T - hysteresis`.
class RollingBuffer {
  RollingBuffer({
    this.capacity = 720, // 60 min @ 5 s
    this.minSamplesForAnomaly = 12,
    this.zScoreThreshold = 3.0,
    this.hysteresis = 1.0,
  })  : assert(capacity > 1),
        assert(minSamplesForAnomaly >= 3),
        assert(zScoreThreshold > 0),
        assert(hysteresis >= 0 && hysteresis < zScoreThreshold);

  final int capacity;
  final int minSamplesForAnomaly;
  final double zScoreThreshold;
  final double hysteresis;

  final List<({DateTime t, double v})> _samples = [];
  bool _anomalous = false;

  /// Add a new sample and return the current anomaly state. The
  /// returned score is `null` until the buffer is warm enough.
  ({bool anomalous, double? score, double mean, double stddev}) push(
    DateTime t,
    double v,
  ) {
    _samples.add((t: t, v: v));
    while (_samples.length > capacity) {
      _samples.removeAt(0);
    }

    if (_samples.length < minSamplesForAnomaly) {
      return (anomalous: false, score: null, mean: 0, stddev: 0);
    }

    final priors = _samples.sublist(0, _samples.length - 1);
    final mean = priors.fold<double>(0, (a, s) => a + s.v) / priors.length;
    final variance = priors.fold<double>(
          0,
          (a, s) => a + (s.v - mean) * (s.v - mean),
        ) /
        priors.length;
    final stddev = math.sqrt(variance);
    if (stddev == 0) {
      // Constant history → only flag if the new value is non-equal AND
      // we have a meaningful baseline. We deliberately do not flag here
      // to avoid trivial tile flutter on idle hosts.
      _anomalous = false;
      return (anomalous: false, score: 0, mean: mean, stddev: 0);
    }

    final z = (v - mean) / stddev;
    final absZ = z.abs();

    if (_anomalous) {
      if (absZ < zScoreThreshold - hysteresis) {
        _anomalous = false;
      }
    } else {
      if (absZ >= zScoreThreshold) {
        _anomalous = true;
      }
    }

    return (anomalous: _anomalous, score: z, mean: mean, stddev: stddev);
  }

  /// Read-only access to the buffered samples (oldest → newest).
  List<({DateTime t, double v})> get samples => List.unmodifiable(_samples);

  /// Last [window] samples (or fewer if the buffer isn't full yet).
  List<({DateTime t, double v})> tail(int window) {
    if (_samples.length <= window) return List.unmodifiable(_samples);
    return List.unmodifiable(
      _samples.sublist(_samples.length - window, _samples.length),
    );
  }

  /// Test/diag helper.
  bool get isAnomalous => _anomalous;

  /// Drop everything (used when the SSH session reconnects and the
  /// caller wants a fresh baseline).
  void clear() {
    _samples.clear();
    _anomalous = false;
  }
}
