import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/ai/bundled_engine.dart';
import '../../core/ai/bundled_engine_controller.dart';
import '../../core/ai/bundled_model_catalog.dart';
import '../../core/ai/bundled_model_downloader.dart';
import '../../core/ai/local_engine_detector.dart';
import '../../core/theme/app_colors.dart';

/// First-run onboarding for the **Local AI** provider.
///
/// Two paths, picked on the first screen:
///
///   1. **Built-in engine** (recommended, zero setup) — downloads a
///      curated GGUF model into the app data dir and starts the
///      bundled inference server on a loopback port. The user is
///      done in two clicks.
///   2. **Connect to existing engine** (Ollama / LM Studio / llama.cpp
///      / Jan) — the original 3-step wizard with copy-paste install
///      snippets and a final "detect engines" step.
///
/// Either path returns to the caller via `Navigator.pop<String?>(...)`
/// with the endpoint URL the rest of the app should talk to (or
/// `null` if the user skipped). Settings uses that to pre-fill the
/// endpoint field.
class LocalAiOnboardingScreen extends StatefulWidget {
  const LocalAiOnboardingScreen({super.key, this.engine});

  /// Engine to start when the user picks "Built-in". Defaults to the
  /// process-wide [BundledEngineController] singleton; tests inject a
  /// fake engine here so the wizard can be exercised without touching
  /// the filesystem or FFI.
  final BundledEngine? engine;

  @override
  State<LocalAiOnboardingScreen> createState() =>
      _LocalAiOnboardingScreenState();
}

enum _OnboardingPath { unset, builtIn, external }

class _LocalAiOnboardingScreenState extends State<LocalAiOnboardingScreen> {
  static const Color _zeroTrustGreen = Color(0xFF00FF88);

  _OnboardingPath _path = _OnboardingPath.unset;
  int _step = 0; // step within the chosen path
  bool _isDetecting = false;
  DetectedEngine? _detected;
  String? _detectError;

  // Built-in engine state
  BundledModel _selectedModel = BundledModelCatalog.defaultPick;
  bool _isDownloading = false;
  bool _isStartingEngine = false;
  StreamSubscription<BundledModelDownloadProgress>? _downloadSub;
  double? _downloadFraction;
  int _downloadedBytes = 0;
  int _downloadTotalBytes = 0;
  String? _builtInError;
  String? _builtInEndpoint;

  BundledEngine get _engine =>
      widget.engine ?? BundledEngineController.instance;

  String get _osLabel {
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'your OS';
  }

  bool get _builtInSupportedOnThisOs {
    // We now support the built-in engine on mobile via the FFI path.
    return _engine.isAvailable;
  }

  String get _installSnippet {
    if (Platform.isMacOS || Platform.isLinux) {
      return 'curl -fsSL https://ollama.com/install.sh | sh';
    }
    if (Platform.isWindows) {
      return 'winget install Ollama.Ollama';
    }
    return '# Ollama is desktop-only. Run it on a server you trust\n'
        '# and point Hamma at that endpoint.';
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _detect() async {
    setState(() {
      _isDetecting = true;
      _detectError = null;
    });
    try {
      final engines = await LocalEngineDetector().detect();
      if (!mounted) return;
      final ollama =
          engines.where((e) => e.kind == LocalEngineKind.ollama).toList();
      setState(() {
        _detected = engines.isEmpty
            ? null
            : (ollama.isNotEmpty ? ollama.first : engines.first);
        _isDetecting = false;
        _detectError = engines.isEmpty
            ? 'No local engines responded on the usual ports.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDetecting = false;
        _detectError = e.toString();
      });
    }
  }

  Future<String> _modelDirectory() async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'bundled_models');
  }

  Future<void> _runBuiltInFlow() async {
    setState(() {
      _builtInError = null;
      _isDownloading = true;
      _downloadedBytes = 0;
      _downloadTotalBytes = _selectedModel.sizeBytes;
      _downloadFraction = 0;
    });
    String modelPath;
    try {
      final dir = await _modelDirectory();
      modelPath =
          BundledModelDownloader.resolvePath(_selectedModel, dir);
      if (!BundledModelDownloader.isCached(_selectedModel, dir)) {
        await _downloadSub?.cancel();
        final downloader = BundledModelDownloader();
        final completer = Completer<void>();
        _downloadSub = downloader
            .download(model: _selectedModel, destinationDir: dir)
            .listen(
          (event) {
            if (!mounted) return;
            setState(() {
              _downloadedBytes = event.completedBytes;
              _downloadTotalBytes = event.totalBytes;
              _downloadFraction = event.fraction;
            });
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
        await completer.future;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _builtInError = 'Download failed: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _isDownloading = false;
      _isStartingEngine = true;
    });
    try {
      await _engine.start(modelPath: modelPath, modelId: _selectedModel.id);
      if (!mounted) return;
      setState(() {
        _isStartingEngine = false;
        _builtInEndpoint = _engine.endpoint;
        _step = 2; // success step
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isStartingEngine = false;
        _builtInError = 'Engine failed to start: $e';
      });
    }
  }

  Future<void> _cancelDownload() async {
    await _downloadSub?.cancel();
    _downloadSub = null;
    if (!mounted) return;
    setState(() {
      _isDownloading = false;
      _builtInError = 'Download cancelled.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text('Local AI Setup'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop<String?>(null),
            child: const Text('SKIP'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildStepperHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _buildBody(),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_path == _OnboardingPath.unset) return _buildPathPicker();
    if (_path == _OnboardingPath.builtIn) {
      return switch (_step) {
        0 => _buildBuiltInPicker(),
        1 => _buildBuiltInProgress(),
        _ => _buildBuiltInDone(),
      };
    }
    // External path
    return switch (_step) {
      0 => _buildInstallStep(),
      1 => _buildPullStep(),
      _ => _buildExternalDoneStep(),
    };
  }

  // ---- Stepper header -------------------------------------------------------

  Widget _buildStepperHeader() {
    final List<String> labels;
    if (_path == _OnboardingPath.builtIn) {
      labels = const ['CHOOSE', 'DOWNLOAD', 'DONE'];
    } else if (_path == _OnboardingPath.external) {
      labels = const ['INSTALL', 'PULL', 'DONE'];
    } else {
      labels = const ['CHOOSE PATH'];
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: List<Widget>.generate(labels.length, (i) {
          final isActive = i == _step;
          final isDone = i < _step;
          final color = isActive
              ? _zeroTrustGreen
              : (isDone ? AppColors.textPrimary : AppColors.textMuted);
          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: color, width: 1),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: color,
                      fontFamily: AppColors.monoFamily,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  labels[i],
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 11,
                    color: color,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (i < labels.length - 1)
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      height: 1,
                      color: AppColors.border,
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ---- Path picker ----------------------------------------------------------

  Widget _buildPathPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        const Text(
          'Choose how to run Local AI',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        _PathOptionTile(
          label: 'BUILT-IN ENGINE',
          subtitle: _builtInSupportedOnThisOs
              ? 'Recommended. Hamma downloads a small model and runs '
                  'inference inside the app — no external daemon, no '
                  'extra installs.'
              : 'Not available — the bundled engine requires the '
                  'native libllama component to be present in this build. '
                  'Use the external option instead.',

          recommended: _builtInSupportedOnThisOs,
          enabled: _builtInSupportedOnThisOs,
          onTap: _builtInSupportedOnThisOs
              ? () => setState(() {
                    _path = _OnboardingPath.builtIn;
                    _step = 0;
                  })
              : null,
        ),
        const SizedBox(height: 12),
        _PathOptionTile(
          label: 'CONNECT TO EXISTING',
          subtitle:
              'Already running Ollama, LM Studio, llama.cpp or Jan? '
              'Point Hamma at it. Best for power users with a curated '
              'model library.',
          onTap: () => setState(() {
            _path = _OnboardingPath.external;
            _step = 0;
          }),
        ),
      ],
    );
  }

  // ---- Built-in path --------------------------------------------------------

  Widget _buildBuiltInPicker() {
    final catalog = BundledModelCatalog.all();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        const Text(
          'Pick a starter model',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'These models are downloaded directly from the official '
          'HuggingFace mirrors and stored in your local app data '
          'directory. Nothing is sent off-device after download.',
          style: TextStyle(color: AppColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        for (final m in catalog) ...[
          _ModelRow(
            model: m,
            isSelected: m.id == _selectedModel.id,
            onTap: () => setState(() => _selectedModel = m),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildBuiltInProgress() {
    final pct = _downloadFraction == null
        ? '—'
        : '${(_downloadFraction! * 100).toStringAsFixed(1)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        Text(
          _isStartingEngine
              ? 'Starting engine…'
              : 'Downloading ${_selectedModel.displayName}',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_isStartingEngine)
          const LinearProgressIndicator(
            color: _zeroTrustGreen,
            backgroundColor: AppColors.border,
          )
        else ...[
          LinearProgressIndicator(
            value: _downloadFraction,
            color: _zeroTrustGreen,
            backgroundColor: AppColors.border,
          ),
          const SizedBox(height: 8),
          Text(
            '$pct  ·  '
            '${_formatBytes(_downloadedBytes)} / '
            '${_formatBytes(_downloadTotalBytes)}',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              color: AppColors.textMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
            ),
            onPressed: _cancelDownload,
            child: const Text('CANCEL'),
          ),
        ],
        if (_builtInError != null) ...[
          const SizedBox(height: 16),
          _ErrorBox(message: _builtInError!),
        ],
      ],
    );
  }

  Widget _buildBuiltInDone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        const Text(
          'Built-in engine is online',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_selectedModel.displayName} is loaded and serving locally.',
          style: const TextStyle(color: AppColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(
              left: BorderSide(color: _zeroTrustGreen, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ENDPOINT',
                style: TextStyle(
                  fontFamily: AppColors.monoFamily,
                  color: _zeroTrustGreen,
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                _builtInEndpoint ?? '(starting…)',
                style: const TextStyle(
                  fontFamily: AppColors.monoFamily,
                  color: AppColors.textPrimary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- External path (existing 3-step wizard) -------------------------------

  Widget _buildBadgeRow() {
    return Row(
      children: [
        _Badge(text: 'ZERO TRUST', color: _zeroTrustGreen),
        const SizedBox(width: 8),
        _Badge(text: 'OFFLINE CAPABLE', color: _zeroTrustGreen),
      ],
    );
  }

  Widget _buildInstallStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        Text(
          'Install Ollama on $_osLabel',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Ollama is a small, free local inference engine. It runs entirely '
          'on your machine — no cloud, no API key, no traffic leaves '
          'localhost.',
          style: TextStyle(color: AppColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        _CodeBlock(snippet: _installSnippet),
        const SizedBox(height: 16),
        const Text(
          'Once installed, the engine usually starts automatically. On Linux '
          'and macOS you can verify with `ollama --version`.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildPullStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        const Text(
          'Pull a model',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Download a small starter model. Gemma 3 is a good default — '
          'about 5 GB on disk.',
          style: TextStyle(color: AppColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        const _CodeBlock(snippet: 'ollama pull gemma3'),
        const SizedBox(height: 12),
        const Text(
          'You can also use the in-app model manager later (Settings → '
          'Manage Models) to browse the curated catalog.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildExternalDoneStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBadgeRow(),
        const SizedBox(height: 12),
        const Text(
          'Verify the engine',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Tap "Detect engines" to scan localhost. We will use whichever '
          'engine answers first.',
          style: TextStyle(color: AppColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            side: const BorderSide(color: _zeroTrustGreen),
            foregroundColor: _zeroTrustGreen,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          ),
          onPressed: _isDetecting ? null : _detect,
          icon: _isDetecting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _zeroTrustGreen,
                  ),
                )
              : const Icon(Icons.radar_rounded, size: 16),
          label: Text(
            _isDetecting ? 'SCANNING…' : 'DETECT ENGINES',
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (_detected != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(
                left: BorderSide(color: _zeroTrustGreen, width: 3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FOUND: ${_detected!.displayLabel}',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    color: _zeroTrustGreen,
                    fontSize: 12,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _detected!.endpoint,
                  style: const TextStyle(
                    fontFamily: AppColors.monoFamily,
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_detectError != null) ...[
          const SizedBox(height: 16),
          _ErrorBox(message: _detectError!),
        ],
      ],
    );
  }

  // ---- Bottom bar -----------------------------------------------------------

  Widget _buildBottomBar() {
    if (_path == _OnboardingPath.unset) {
      return const SizedBox(height: 0);
    }
    final isExternalLast =
        _path == _OnboardingPath.external && _step == 2;
    final isBuiltInLast = _path == _OnboardingPath.builtIn && _step == 2;
    final isLast = isExternalLast || isBuiltInLast;

    String nextLabel;
    if (_path == _OnboardingPath.builtIn) {
      if (_step == 0) {
        nextLabel = 'DOWNLOAD & START';
      } else if (_step == 1) {
        nextLabel = _isDownloading
            ? 'DOWNLOADING…'
            : (_isStartingEngine ? 'STARTING…' : 'RETRY');
      } else {
        nextLabel = 'USE BUILT-IN ENGINE';
      }
    } else {
      nextLabel = isLast
          ? (_detected != null ? 'USE THIS ENGINE' : 'FINISH')
          : 'NEXT';
    }

    final canTapNext = !(_isDownloading || _isStartingEngine);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
            onPressed: canTapNext
                ? () {
                    if (_step == 0) {
                      // Back from first step → return to path picker.
                      setState(() {
                        _path = _OnboardingPath.unset;
                        _step = 0;
                      });
                    } else {
                      setState(() => _step -= 1);
                    }
                  }
                : null,
            child: const Text('BACK'),
          ),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _zeroTrustGreen,
              foregroundColor: Colors.black,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 14,
              ),
            ),
            onPressed: canTapNext
                ? () async {
                    if (_path == _OnboardingPath.builtIn) {
                      if (_step == 0) {
                        setState(() => _step = 1);
                        await _runBuiltInFlow();
                      } else if (_step == 1) {
                        // Retry
                        await _runBuiltInFlow();
                      } else {
                        if (!mounted) return;
                        Navigator.of(context).pop<String?>(_builtInEndpoint);
                      }
                    } else {
                      if (isLast) {
                        Navigator.of(context).pop<String?>(_detected?.endpoint);
                      } else {
                        setState(() => _step += 1);
                      }
                    }
                  }
                : null,
            child: Text(
              nextLabel,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                letterSpacing: 1.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final fixed = size >= 100 ? 0 : (size >= 10 ? 1 : 2);
    return '${size.toStringAsFixed(fixed)} ${units[unit]}';
  }
}

class _PathOptionTile extends StatelessWidget {
  const _PathOptionTile({
    required this.label,
    required this.subtitle,
    this.recommended = false,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final String subtitle;
  final bool recommended;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? (recommended
            ? const Color(0xFF00FF88)
            : AppColors.textPrimary)
        : AppColors.textMuted;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(
            color: color,
            width: recommended ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 13,
                    color: color,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (recommended) ...[
                  const SizedBox(width: 8),
                  _Badge(
                    text: 'RECOMMENDED',
                    color: color,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(
                color: enabled ? AppColors.textMuted : AppColors.textFaint,
                height: 1.4,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.isSelected,
    required this.onTap,
  });

  final BundledModel model;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(
            color: isSelected
                ? const Color(0xFF00FF88)
                : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected
                  ? const Color(0xFF00FF88)
                  : AppColors.textMuted,
              size: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          model.displayName,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '${(model.sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB',
                        style: TextStyle(
                          fontFamily: AppColors.monoFamily,
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    model.summary,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          left: BorderSide(color: AppColors.danger, width: 3),
        ),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontFamily: AppColors.monoFamily,
          color: AppColors.danger,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AppColors.monoFamily,
          fontSize: 10,
          color: color,
          letterSpacing: 2,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.snippet});
  final String snippet;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              snippet,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 12,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: snippet));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
          ),
        ],
      ),
    );
  }
}
