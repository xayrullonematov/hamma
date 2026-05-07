import 'dart:io';

/// Hardware capabilities that influence the choice of inference runner.
enum HardwareFeature {
  metal,
  cuda,
  rocm,
  avx2,
  avx512,
}

/// Detects the system's hardware capabilities at runtime, mirroring
/// Ollama's discovery strategy.
class HardwareDetector {
  HardwareDetector._();

  /// Returns the set of detected hardware features.
  ///
  /// This is a best-effort detection used to select the optimal
  /// llama.cpp runner (e.g. preferring a CUDA-optimized binary over
  /// a basic CPU one).
  static Future<Set<HardwareFeature>> detect() async {
    final features = <HardwareFeature>{};

    if (Platform.isMacOS || Platform.isIOS) {
      // Apple Silicon and recent Intel Macs almost always support Metal.
      features.add(HardwareFeature.metal);
    }

    if (Platform.isLinux || Platform.isWindows) {
      // On desktop, we'd typically check for nvidia-smi or the presence
      // of CUDA libraries. For this architectural task, we check for
      // environment hints or standard library locations.
      if (Platform.environment.containsKey('CUDA_VISIBLE_DEVICES') ||
          _hasCudaDriver()) {
        features.add(HardwareFeature.cuda);
      }
    }

    // CPU feature detection (AVX2/AVX512) typically requires native
    // calls or parsing /proc/cpuinfo.
    if (Platform.isLinux) {
      final cpuinfo = await File('/proc/cpuinfo').readAsString().catchError((_) => '');
      if (cpuinfo.contains('avx512')) features.add(HardwareFeature.avx512);
      if (cpuinfo.contains('avx2')) features.add(HardwareFeature.avx2);
    }

    return features;
  }

  static bool _hasCudaDriver() {
    if (Platform.isWindows) {
      return File('C:\\Windows\\System32\\nvcuda.dll').existsSync();
    }
    if (Platform.isLinux) {
      return File('/usr/lib/x86_64-linux-gnu/libcuda.so').existsSync() ||
             File('/usr/lib/libcuda.so').existsSync();
    }
    return false;
  }
}

/// Strategies for selecting the best inference engine, inspired by
/// Ollama's runner management.
class RunnerStrategy {
  const RunnerStrategy({
    required this.name,
    required this.binaryCandidates,
    required this.libraryCandidates,
    this.requiredFeature,
  });

  final String name;
  final List<String> binaryCandidates;
  final List<String> libraryCandidates;
  final HardwareFeature? requiredFeature;

  /// Returns the best available strategies for the current hardware.
  static List<RunnerStrategy> getApplicable(Set<HardwareFeature> features) {
    final all = <RunnerStrategy>[
      // Metal Strategy (Apple)
      RunnerStrategy(
        name: 'METAL',
        requiredFeature: HardwareFeature.metal,
        binaryCandidates: ['llama-server-metal', 'llama-server'],
        libraryCandidates: ['libllama-metal.dylib', 'libllama.dylib'],
      ),
      // CUDA Strategy (NVIDIA)
      RunnerStrategy(
        name: 'CUDA',
        requiredFeature: HardwareFeature.cuda,
        binaryCandidates: ['llama-server-cuda', 'llama-server'],
        libraryCandidates: ['libllama-cuda.so', 'libllama.so', 'llama-cuda.dll', 'llama.dll'],
      ),
      // High-performance CPU (AVX2)
      RunnerStrategy(
        name: 'CPU-AVX2',
        requiredFeature: HardwareFeature.avx2,
        binaryCandidates: ['llama-server-avx2', 'llama-server'],
        libraryCandidates: ['libllama-avx2.so', 'libllama.so'],
      ),
      // Baseline CPU
      const RunnerStrategy(
        name: 'CPU-GENERIC',
        binaryCandidates: ['llama-server'],
        libraryCandidates: ['libllama.so', 'libllama.dylib', 'llama.dll'],
      ),
    ];

    return all.where((s) => s.requiredFeature == null || features.contains(s.requiredFeature)).toList();
  }
}
