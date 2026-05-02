/// A single entry in the curated catalog of GGUF models the bundled
/// engine knows how to download.
///
/// We keep the catalog small and opinionated — the goal is "five sane
/// choices" rather than the full HuggingFace index. Models are pulled
/// from their public HuggingFace mirrors over HTTPS at the user's
/// explicit request; the bundled engine never reaches the network on
/// its own.
class BundledModel {
  const BundledModel({
    required this.id,
    required this.displayName,
    required this.summary,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.parameterCount,
    required this.quantization,
    this.recommended = false,
  });

  /// Stable identifier, used as the on-disk filename (without extension)
  /// and as the model id in the OpenAI-compatible API the bundled
  /// engine exposes. URL-safe.
  final String id;

  /// Human label for the UI (e.g. "Gemma 3 1B (Q4_K_M)").
  final String displayName;

  /// One-line description shown under the model name.
  final String summary;

  /// HTTPS URL the file is fetched from. MUST be `https://`.
  final String downloadUrl;

  /// Approximate size on disk, in bytes. Used for the download progress
  /// bar and the disk-space warning.
  final int sizeBytes;

  /// "1B", "3B", "8B" — informational, displayed in the catalog row.
  final String parameterCount;

  /// "Q4_K_M", "Q8_0", … — informational.
  final String quantization;

  /// True for the single "default pick" the UI highlights.
  final bool recommended;

  /// On-disk filename used inside the bundled-engine model directory.
  String get filename => '$id.gguf';

  /// Validates this entry can actually be used. Returns `null` if OK,
  /// or a human-readable reason why not.
  String? validate() {
    if (id.trim().isEmpty) return 'id must not be empty';
    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(id)) {
      return 'id must be lowercase alphanumeric / dot / dash / underscore';
    }
    final uri = Uri.tryParse(downloadUrl);
    if (uri == null || uri.scheme != 'https') {
      return 'downloadUrl must be https://';
    }
    if (sizeBytes <= 0) return 'sizeBytes must be positive';
    return null;
  }
}

/// Curated list of GGUF builds the bundled engine ships first-class
/// support for. Order matters — [recommended] entries surface first in
/// the picker.
///
/// All URLs point at upstream HuggingFace mirrors. The values below are
/// approximations; the downloader verifies the actual size as it
/// streams the file.
class BundledModelCatalog {
  const BundledModelCatalog._();

  /// Fixed catalog. Returns a fresh list so callers can sort / filter
  /// without mutating shared state.
  static List<BundledModel> all() => List.unmodifiable(_entries);

  /// The single "default pick" the onboarding wizard auto-selects.
  static BundledModel get defaultPick =>
      _entries.firstWhere((m) => m.recommended, orElse: () => _entries.first);

  /// Lookup by [BundledModel.id]. Returns `null` when not found.
  static BundledModel? byId(String id) {
    final trimmed = id.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    for (final m in _entries) {
      if (m.id == trimmed) return m;
    }
    return null;
  }

  // ---- entries --------------------------------------------------------------

  static const List<BundledModel> _entries = [
    BundledModel(
      id: 'gemma3-1b-it-q4',
      displayName: 'Gemma 3 1B (Q4_K_M)',
      summary:
          'Tiny but capable instruction-tuned model from Google. Runs on '
          'almost any laptop. ~750 MB on disk.',
      downloadUrl:
          'https://huggingface.co/google/gemma-3-1b-it-qat-q4_0-gguf/'
          'resolve/main/gemma-3-1b-it-q4_0.gguf',
      sizeBytes: 750 * 1024 * 1024,
      parameterCount: '1B',
      quantization: 'Q4_K_M',
      recommended: true,
    ),
    BundledModel(
      id: 'qwen2.5-coder-3b-q4',
      displayName: 'Qwen2.5 Coder 3B (Q4_K_M)',
      summary:
          'Balanced coding model — good at shell, Python, and config '
          'files. ~1.9 GB on disk.',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/'
          'resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf',
      sizeBytes: 1900 * 1024 * 1024,
      parameterCount: '3B',
      quantization: 'Q4_K_M',
    ),
    BundledModel(
      id: 'llama3.2-3b-it-q4',
      displayName: 'Llama 3.2 3B Instruct (Q4_K_M)',
      summary:
          'Meta\'s general-purpose 3B model, good chat quality. '
          '~2.0 GB on disk.',
      downloadUrl:
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/'
          'resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      sizeBytes: 2000 * 1024 * 1024,
      parameterCount: '3B',
      quantization: 'Q4_K_M',
    ),
    BundledModel(
      id: 'phi3.5-mini-q4',
      displayName: 'Phi 3.5 Mini (Q4_K_M)',
      summary:
          'Microsoft\'s 3.8B reasoning model. Strong at structured '
          'output and JSON. ~2.4 GB on disk.',
      downloadUrl:
          'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/'
          'resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
      sizeBytes: 2400 * 1024 * 1024,
      parameterCount: '3.8B',
      quantization: 'Q4_K_M',
    ),
  ];
}
