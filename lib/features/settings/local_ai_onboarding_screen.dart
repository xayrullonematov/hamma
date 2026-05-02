import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ai/local_engine_detector.dart';
import '../../core/theme/app_colors.dart';

/// First-run onboarding for the **Local AI** provider.
///
/// Three steps:
///   1. **Install** — OS-aware install command for Ollama (the most common
///      and easiest local engine).
///   2. **Pull** — copy/paste `ollama pull gemma3` and wait for it to
///      finish.
///   3. **Done** — runs the engine detector to confirm Ollama is up,
///      then returns the detected endpoint to the caller.
///
/// On finish, this screen pops with the detected endpoint URL (or `null`
/// if the user skipped). The Settings screen uses that to pre-fill the
/// endpoint field.
class LocalAiOnboardingScreen extends StatefulWidget {
  const LocalAiOnboardingScreen({super.key});

  @override
  State<LocalAiOnboardingScreen> createState() =>
      _LocalAiOnboardingScreenState();
}

class _LocalAiOnboardingScreenState extends State<LocalAiOnboardingScreen> {
  static const Color _zeroTrustGreen = Color(0xFF00FF88);
  int _step = 0;
  bool _isDetecting = false;
  DetectedEngine? _detected;
  String? _detectError;

  String get _osLabel {
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'your OS';
  }

  String get _installSnippet {
    if (Platform.isMacOS || Platform.isLinux) {
      return 'curl -fsSL https://ollama.com/install.sh | sh';
    }
    if (Platform.isWindows) {
      return 'winget install Ollama.Ollama';
    }
    // Mobile: Ollama doesn't ship for Android/iOS — direct user to a
    // remote instance instead.
    return '# Ollama is desktop-only. Run it on a server you trust\n'
        '# and point Hamma at that endpoint.';
  }

  Future<void> _detect() async {
    setState(() {
      _isDetecting = true;
      _detectError = null;
    });
    try {
      final engines = await LocalEngineDetector().detect();
      if (!mounted) return;
      final ollama = engines
          .where((e) => e.kind == LocalEngineKind.ollama)
          .toList();
      setState(() {
        _detected = engines.isEmpty ? null : (ollama.isNotEmpty ? ollama.first : engines.first);
        _isDetecting = false;
        _detectError =
            engines.isEmpty ? 'No local engines responded on the usual ports.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDetecting = false;
        _detectError = e.toString();
      });
    }
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
                child: switch (_step) {
                  0 => _buildInstallStep(),
                  1 => _buildPullStep(),
                  _ => _buildDoneStep(),
                },
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildStepperHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: List<Widget>.generate(3, (i) {
          final isActive = i == _step;
          final isDone = i < _step;
          final color =
              isActive ? _zeroTrustGreen : (isDone ? AppColors.textPrimary : AppColors.textMuted);
          final labels = ['INSTALL', 'PULL', 'DONE'];
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
                if (i < 2)
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

  Widget _buildDoneStep() {
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
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(
                left: BorderSide(color: AppColors.danger, width: 3),
              ),
            ),
            child: Text(
              _detectError!,
              style: const TextStyle(
                fontFamily: AppColors.monoFamily,
                color: AppColors.danger,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBottomBar() {
    final isLast = _step == 2;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (_step > 0)
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
              ),
              onPressed: () => setState(() => _step -= 1),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
            onPressed: () {
              if (isLast) {
                Navigator.of(context).pop<String?>(_detected?.endpoint);
              } else {
                setState(() => _step += 1);
              }
            },
            child: Text(
              isLast
                  ? (_detected != null ? 'USE THIS ENGINE' : 'FINISH')
                  : 'NEXT',
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
